import Foundation
import os

/// The Q10 safety gate chain. Decides whether a given action may run RIGHT
/// NOW, in this order (locked Q4):
///
///   reversibility → enabled → power-gate → focus-gate → cool-down →
///   rate-limit → (execute) → (audit-log)
///
/// Execution + audit happen in `ActionRunner` / `AuditLog`; this engine only
/// produces the allow/deny verdict and tracks the timing state the last two
/// gates need (per-action last-run timestamps for cool-down + a rolling
/// hourly window for rate-limit).
///
/// **Trigger semantics**:
///  - `.auto` runs the FULL chain. `auto_enabled == false` (the Q3 default)
///    denies at the `enabled` gate.
///  - `.confirmed` (user clicked the notification "Run" button) BYPASSES the
///    `enabled`, `power`, `focus`, `cool-down`, and `rate-limit` gates — the
///    user is explicitly asking for it — but still honours `reversibility`
///    (a non-reversible action is never silently run). Audit is unconditional
///    in `AuditLog` regardless.
///  - `.dryRun` is allowed for any reversible action (no mutation, so the
///    behavioural gates don't apply); it's surfaced as decision `dry_run`.
///
/// Pure-testable: inject the clock + a `Context` (power state, focus, config).
/// `recordRun(...)` is called by the runner AFTER a real (non-dry-run)
/// execution so cool-down + rate-limit see it.
public actor PolicyEngine {

    /// Everything the gates read that isn't on the action itself. Injected so
    /// tests assert allow/deny deterministically.
    public struct Context: Sendable {
        /// Current coarse power state (from `PowerProfileMonitor`).
        public let powerState: PowerState
        /// Whether a Focus session is active right now.
        public let focusActive: Bool
        /// The live `[actions]` config (toggles + params + per-action opt-in).
        public let config: ActionsConfig

        public init(powerState: PowerState, focusActive: Bool, config: ActionsConfig) {
            self.powerState = powerState
            self.focusActive = focusActive
            self.config = config
        }

        /// True when running on battery (either lid state). The power gate
        /// skips AUTO actions here. AC + Focus power-states count as "not on
        /// battery".
        public var onBattery: Bool {
            switch powerState {
            case .batteryLidOpen, .batteryLidClosed: return true
            case .acConnectedLidOpen, .acConnectedLidClosed, .focusActive: return false
            }
        }
    }

    /// Why an action was denied. `reason` is the short token embedded in the
    /// audit decision string (`deny:<reason>`).
    public enum DenyReason: String, Sendable, Equatable {
        case notReversible = "not_reversible"
        case notEnabled = "not_enabled"
        case onBattery = "on_battery"
        case focusActive = "focus_active"
        case coolDown = "cool_down"
        case rateLimit = "rate_limit"
        case unknownAction = "unknown_action"
    }

    /// The verdict.
    public enum Decision: Sendable, Equatable {
        case allow
        case dryRun
        case deny(DenyReason)

        /// String form recorded in the audit log.
        public var auditString: String {
            switch self {
            case .allow:            return "allow"
            case .dryRun:           return "dry_run"
            case .deny(let reason): return "deny:\(reason.rawValue)"
            }
        }

        public var isAllowed: Bool {
            switch self {
            case .allow, .dryRun: return true
            case .deny:           return false
            }
        }
    }

    private let clock: @Sendable () -> Date
    /// Per-action last (real) run timestamp — drives cool-down.
    private var lastRunByAction: [String: Date] = [:]
    /// Rolling list of (real) auto-run timestamps within the last hour —
    /// drives rate-limit. Pruned lazily on each evaluation.
    private var recentAutoRuns: [Date] = []
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "policy")

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    // MARK: - Evaluation

    /// Run the gate chain for `descriptor` under `trigger` + `context`.
    public func evaluate(
        descriptor: ActionDescriptor,
        trigger: ActionTrigger,
        context: Context
    ) -> Decision {
        let now = clock()

        // 1. Reversibility — ALWAYS enforced (auto + confirmed). A
        //    non-reversible action is never run by uZora in this iteration.
        guard descriptor.reversible else {
            return .deny(.notReversible)
        }

        // A dry-run never mutates → only reversibility matters. Surface a
        // distinct `dryRun` decision so the audit log shows it.
        if trigger == .dryRun {
            return .dryRun
        }

        // A confirmed (user-clicked) run bypasses the remaining behavioural
        // gates — the user is explicitly asking. Reversibility (above) still
        // applies; audit is unconditional in AuditLog.
        if trigger == .confirmed {
            return .allow
        }

        // ── From here: trigger == .auto, run the full chain. ──
        let cfg = context.config
        guard let override = cfg[id: descriptor.id] else {
            return .deny(.unknownAction)
        }

        // 2. Enabled (per-action opt-in, Q3 default false).
        guard override.autoEnabled else {
            return .deny(.notEnabled)
        }

        // 3. Power gate — skip auto on battery (configurable).
        if cfg.powerGate, context.onBattery {
            return .deny(.onBattery)
        }

        // 4. Focus gate — skip auto during Focus (configurable).
        if cfg.focusGate, context.focusActive {
            return .deny(.focusActive)
        }

        // 5. Cool-down — don't repeat the SAME action within N minutes
        //    (configurable toggle + minutes).
        if cfg.coolDownEnabled, cfg.coolDownMinutes > 0,
           let last = lastRunByAction[descriptor.id] {
            let elapsed = now.timeIntervalSince(last)
            let window = Double(cfg.coolDownMinutes) * 60.0
            if elapsed < window {
                return .deny(.coolDown)
            }
        }

        // 6. Rate-limit — cap auto-runs per rolling hour (configurable).
        if cfg.rateLimitEnabled {
            pruneRateWindow(now: now)
            if recentAutoRuns.count >= cfg.rateLimitPerHour {
                return .deny(.rateLimit)
            }
        }

        return .allow
    }

    /// Record a REAL (non-dry-run) execution so cool-down + rate-limit see
    /// it. Called by the runner after `execute()`. `countsTowardRateLimit`
    /// is true only for AUTO runs — a confirmed user click should not consume
    /// the auto rate budget.
    public func recordRun(
        actionID: String,
        trigger: ActionTrigger,
        at when: Date? = nil
    ) {
        let now = when ?? clock()
        // Cool-down applies to any real run of the action (auto OR confirmed)
        // so two clicks 1s apart don't double-clean; but a confirmed run is
        // allowed to bypass the cool-down GATE above. We still stamp it so a
        // subsequent AUTO run respects the wait.
        guard trigger != .dryRun else { return }
        lastRunByAction[actionID] = now
        if trigger == .auto {
            recentAutoRuns.append(now)
            pruneRateWindow(now: now)
        }
    }

    /// Seconds remaining on an action's cool-down (0 if none / disabled).
    /// Test + UI affordance.
    public func cooldownRemaining(actionID: String, config: ActionsConfig) -> TimeInterval {
        guard config.coolDownEnabled, config.coolDownMinutes > 0,
              let last = lastRunByAction[actionID] else { return 0 }
        let window = Double(config.coolDownMinutes) * 60.0
        let elapsed = clock().timeIntervalSince(last)
        return max(0, window - elapsed)
    }

    /// Count of auto-runs in the current rolling hour (test affordance).
    public func autoRunsInWindow() -> Int {
        pruneRateWindow(now: clock())
        return recentAutoRuns.count
    }

    /// Reset all timing state (test affordance).
    public func reset() {
        lastRunByAction.removeAll()
        recentAutoRuns.removeAll()
    }

    // MARK: - Internals

    private func pruneRateWindow(now: Date) {
        let cutoff = now.addingTimeInterval(-3600)
        recentAutoRuns.removeAll { $0 < cutoff }
    }
}
