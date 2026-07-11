import Foundation
import os

/// The ONE shared proactive-push producer (plan D-L1 / report 09).
///
/// Turns uZora events into proactive notifications to a LOCAL agent with **zero
/// network egress**. It subscribes to BOTH event sources — the `WatchdogEvent`
/// `EventBus` (alert transitions) and the `DiagnosisEventBus`
/// (`DiagnosisStreamEvent`: findings + verdict-level changes) — maps each event
/// to a unified `PushEvent`, and runs it through a fixed pipeline:
///
///   filter (floor / kind / cleared) → coalesce → rate-limit → dispatch
///
/// then AUDITS every outcome. **OFF by default**: with `[push] enabled = false`
/// nothing subscribes and nothing dispatches. The **outbound webhook is
/// EXCLUDED** (D-L1: the dangerous egress surface) — the only backends are
/// `local-exec` (a fixed-argv `claude -p …` via `ActionShell`, no shell) and the
/// watched-file `outbox` (append-only JSONL). Settings/config-ONLY; no bridge
/// write path can enable it.
///
/// Non-blocking by construction: each bus subscriber callback merely SPAWNS a
/// `Task` that hops onto this actor — `EventBus.emit` / `DiagnosisEventBus.emit`
/// never await a backend, so the watchdog / diagnosis loops can't wedge on a
/// slow `claude` run.
public actor ProactivePush {

    /// The fixed timeout for a local-exec run. An LLM CLI invocation is heavy;
    /// this bounds a hung child. (The blocking spawn/wait is offloaded off-actor
    /// by `ActionShellPushRunner`, so awaiting it only suspends this actor.)
    public static let execTimeoutSeconds: Double = 60

    // ── Dependencies ──
    private let eventBus: EventBus
    private let diagnosisBus: DiagnosisEventBus
    private let audit: PushAuditLog
    private let outbox: PushOutbox?
    private let execRunner: any PushExecRunning
    private let onCircuitTrip: (@Sendable (Int) async -> Void)?
    private let clock: @Sendable () -> Date

    // ── Config (hot-reloadable) ──
    private var config: PushConfig

    // ── Runtime state ──
    private var started = false
    private var eventBusToken: UUID?
    private var diagBusToken: UUID?
    /// Per-subject last dispatch time — drives coalescing.
    private var lastPushBySubject: [String: Date] = [:]
    /// Rolling list of dispatch times in the last hour — drives rate-limit.
    private var recentPushes: [Date] = []
    /// Consecutive backend-dispatch failures — drives the circuit breaker.
    private var consecutiveFailures = 0
    /// The circuit breaker is OPEN — push auto-disabled until the operator
    /// re-enables (toggle `[push] enabled`).
    private var circuitOpen = false

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "proactive-push")

    public init(
        eventBus: EventBus,
        diagnosisBus: DiagnosisEventBus,
        config: PushConfig,
        audit: PushAuditLog,
        outbox: PushOutbox? = nil,
        execRunner: any PushExecRunning = ActionShellPushRunner(),
        onCircuitTrip: (@Sendable (Int) async -> Void)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.eventBus = eventBus
        self.diagnosisBus = diagnosisBus
        self.config = config
        self.audit = audit
        self.outbox = outbox
        self.execRunner = execRunner
        self.onCircuitTrip = onCircuitTrip
        self.clock = clock
    }

    // MARK: - Lifecycle

    /// Subscribe to both buses IF `enabled`. Idempotent. A fresh start resets
    /// the circuit breaker (a re-enable is the operator's "try again").
    public func start() async {
        guard config.enabled, !started else { return }
        started = true
        circuitOpen = false
        consecutiveFailures = 0
        eventBusToken = await eventBus.subscribe { [weak self] event in
            guard let self else { return }
            // NON-BLOCKING: the emit call returns immediately; the pipeline runs
            // on a detached actor hop.
            Task { await self.handleWatchdog(event) }
        }
        diagBusToken = await diagnosisBus.subscribe { [weak self] event in
            guard let self else { return }
            Task { await self.handleDiagnosis(event) }
        }
        log.info("proactive-push started (floor=\(self.config.severityFloor.rawValue, privacy: .public), kinds=\(self.config.kinds.joined(separator: ","), privacy: .public))")
    }

    /// Unsubscribe from both buses. Idempotent.
    public func stop() async {
        guard started else { return }
        started = false
        if let t = eventBusToken { await eventBus.unsubscribe(t) }
        if let t = diagBusToken { await diagnosisBus.unsubscribe(t) }
        eventBusToken = nil
        diagBusToken = nil
        log.info("proactive-push stopped")
    }

    /// Apply a hot-reloaded `[push]` config. Flipping `enabled` off ⇒ stop;
    /// flipping it on ⇒ start (and reset the circuit breaker). While enabled and
    /// already running, the new floor / kinds / backend flags apply to
    /// subsequent events (backends built at construction time — an `outbox_path`
    /// change needs a restart).
    public func reconfigure(_ new: PushConfig) async {
        let wasEnabled = config.enabled
        config = new
        if new.enabled && !wasEnabled {
            await start()
        } else if !new.enabled && wasEnabled {
            await stop()
        } else if new.enabled && !started {
            // Enabled at construction but never started — ensure subscription.
            await start()
        }
    }

    // MARK: - Ingest (bus → unified PushEvent → pipeline)

    /// Map + process a `WatchdogEvent`. Exposed (internal) for deterministic
    /// tests that drive the pipeline without the async bus timing.
    func handleWatchdog(_ event: WatchdogEvent) async {
        await process(PushEvent.from(watchdog: event, at: clock()))
    }

    /// Map + process a `DiagnosisStreamEvent`.
    func handleDiagnosis(_ event: DiagnosisStreamEvent) async {
        await process(PushEvent.from(diagnosis: event, at: clock()))
    }

    // MARK: - Pipeline

    /// The full pipeline for one unified event (report 09 §1b/§1c). Every path
    /// audits exactly one terminal outcome (dispatch audits per-backend).
    func process(_ event: PushEvent) async {
        guard config.enabled else { return }

        // Circuit breaker OPEN ⇒ push auto-disabled; refuse + audit.
        if circuitOpen {
            await audit.record(event: event, outcome: .denied(reason: "circuit_open"))
            return
        }

        // ── FILTER (before the rate-limiter, so below-floor floods are free) ──
        // 1. kind not selected.
        guard config.kinds.contains(event.kind.rawValue) else {
            await audit.record(event: event, outcome: .dropped(reason: "kind_off"))
            return
        }
        // 2. cleared/resolved and push_cleared off.
        if event.cleared && !config.pushCleared {
            await audit.record(event: event, outcome: .dropped(reason: "cleared_off"))
            return
        }
        // 3. below the severity floor. Cleared events SKIP this — they carry no
        //    meaningful severity (gated by push_cleared above instead).
        if !event.cleared && event.severity < config.severityFloor {
            await audit.record(event: event, outcome: .dropped(reason: "below_floor"))
            return
        }
        // 4. no backend to dispatch to (misconfigured enabled-push) — drop
        //    BEFORE consuming coalesce / rate budget.
        guard hasEnabledBackend else {
            await audit.record(event: event, outcome: .dropped(reason: "no_backend"))
            return
        }

        let now = clock()

        // ── COALESCE — suppress a repeat of the same subject+kind in-window. ──
        if config.coolDownSeconds > 0,
           let last = lastPushBySubject[event.coalesceKey],
           now.timeIntervalSince(last) < Double(config.coolDownSeconds) {
            await audit.record(event: event, outcome: .coalesced)
            return
        }

        // ── RATE-LIMIT — cap per rolling hour; over-cap ⇒ drop (never queue). ──
        pruneRateWindow(now: now)
        if recentPushes.count >= config.rateLimitPerHour {
            await audit.record(event: event, outcome: .dropped(reason: "rate_limit"))
            return
        }

        // Passed every gate. Record for coalesce + rate BEFORE dispatch so a
        // dispatched push counts regardless of backend success (a backend
        // failure must not let a flood bypass the cap).
        lastPushBySubject[event.coalesceKey] = now
        recentPushes.append(now)

        // ── DISPATCH + circuit-breaker accounting. ──
        let succeeded = await dispatch(event)
        if succeeded {
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
            if consecutiveFailures >= config.circuitBreakerThreshold {
                circuitOpen = true
                await audit.record(event: event, outcome: .denied(reason: "circuit_tripped"))
                let count = consecutiveFailures
                log.error("proactive-push: circuit breaker tripped after \(count, privacy: .public) consecutive backend failures; push auto-disabled until re-enabled")
                if let onCircuitTrip { await onCircuitTrip(count) }
            }
        }
    }

    /// Dispatch to each ENABLED backend, auditing every per-backend outcome.
    /// Returns whether the attempt succeeded (≥1 enabled backend accepted it) —
    /// the circuit breaker's failure signal.
    private func dispatch(_ event: PushEvent) async -> Bool {
        var anyAttempted = false
        var anySucceeded = false

        // outbox backend (near-free, zero egress).
        if config.outboxEnabled, let outbox {
            anyAttempted = true
            let ok = await outbox.append(event)
            await audit.record(event: event, outcome: ok ? .sent(backend: "outbox") : .failed(backend: "outbox"))
            anySucceeded = anySucceeded || ok
        }

        // local-exec backend — the summary is ONE argv token appended to the
        // fixed command; ActionShell runs it with NO shell, so no interpolation.
        if config.execEnabled, !config.execArgv.isEmpty {
            anyAttempted = true
            let argv = config.execArgv + [event.summary]
            let outcome = await execRunner.run(argv: argv, timeoutSeconds: Self.execTimeoutSeconds)
            let ok = outcome.launched && outcome.exitCode == 0
            await audit.record(event: event, outcome: ok ? .sent(backend: "exec") : .failed(backend: "exec"))
            anySucceeded = anySucceeded || ok
        }

        return anyAttempted ? anySucceeded : false
    }

    /// Whether at least one backend is enabled AND usable right now.
    private var hasEnabledBackend: Bool {
        let outboxUsable = config.outboxEnabled && outbox != nil
        let execUsable = config.execEnabled && !config.execArgv.isEmpty
        return outboxUsable || execUsable
    }

    private func pruneRateWindow(now: Date) {
        let cutoff = now.addingTimeInterval(-3600)
        recentPushes.removeAll { $0 < cutoff }
    }

    // MARK: - Test affordances

    /// Whether the producer is subscribed to the buses.
    public var isStarted: Bool { started }
    /// Whether the circuit breaker has tripped (push auto-disabled).
    public var isCircuitOpen: Bool { circuitOpen }
    /// The current consecutive-failure count.
    public var consecutiveFailureCount: Int { consecutiveFailures }
    /// The live config snapshot.
    public var currentConfig: PushConfig { config }
    /// Dispatched-push count in the current rolling hour.
    public func rateWindowCount() -> Int {
        pruneRateWindow(now: clock())
        return recentPushes.count
    }
}
