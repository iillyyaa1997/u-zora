import Foundation
import os

/// Orchestrates the Q10 pipeline: registry → policy gate chain → execute →
/// audit. One entry point (`run(actionID:trigger:context:)`) serves BOTH
/// paths:
///
///  - **auto** (the event pipeline, on a mapped + opted-in alert) — runs the
///    full gate chain; a deny short-circuits with an audit `deny:<reason>`.
///  - **confirmed** (the notification "Run" button) — the user explicitly
///    clicked, so PolicyEngine bypasses the behavioural gates but still
///    enforces reversibility; always audited.
///
/// `actor` so the policy timing state (cool-down / rate-limit) and audit
/// writes serialize. The runner owns NO probe/alert subscription itself — the
/// app wires the EventBus → `handleAlertEvent(...)`; the notification handler
/// calls `run(...)` directly with `trigger: .confirmed`.
public actor ActionRunner {

    private let registry: ActionRegistry
    private let policy: PolicyEngine
    private let audit: AuditLog
    /// Reads the current `[actions]` config + power/focus context at call
    /// time. Injected so the app supplies live state and tests supply fakes.
    private let contextProvider: @Sendable () async -> PolicyEngine.Context

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "action-runner")

    public init(
        registry: ActionRegistry,
        policy: PolicyEngine,
        audit: AuditLog,
        contextProvider: @escaping @Sendable () async -> PolicyEngine.Context
    ) {
        self.registry = registry
        self.policy = policy
        self.audit = audit
        self.contextProvider = contextProvider
    }

    /// Outcome of a `run(...)` — the decision plus (when allowed) the result.
    public struct RunOutcome: Sendable, Equatable {
        public let actionID: String
        public let decision: PolicyEngine.Decision
        public let result: ActionResult?
        public init(actionID: String, decision: PolicyEngine.Decision, result: ActionResult?) {
            self.actionID = actionID
            self.decision = decision
            self.result = result
        }
    }

    /// Run a single action by id under `trigger`. Evaluates policy, executes
    /// if allowed, audits the outcome (allow OR deny — audit is always-on).
    /// `context` defaults to the live provider but can be supplied by a
    /// caller that already has it (the auto path, which fetches once per
    /// alert and reuses across multiple mapped actions).
    @discardableResult
    public func run(
        actionID: String,
        trigger: ActionTrigger,
        context: PolicyEngine.Context? = nil
    ) async -> RunOutcome {
        guard let action = await registry.action(id: actionID) else {
            await audit.recordDenied(actionID: actionID, trigger: trigger, reason: PolicyEngine.DenyReason.unknownAction.rawValue)
            return RunOutcome(actionID: actionID, decision: .deny(.unknownAction), result: nil)
        }
        let ctx: PolicyEngine.Context
        if let context {
            ctx = context
        } else {
            ctx = await contextProvider()
        }
        let decision = await policy.evaluate(descriptor: action.descriptor, trigger: trigger, context: ctx)

        switch decision {
        case .deny(let reason):
            await audit.recordDenied(actionID: actionID, trigger: trigger, reason: reason.rawValue)
            log.info("action \(actionID, privacy: .public) denied (\(reason.rawValue, privacy: .public)) trigger=\(trigger.rawValue, privacy: .public)")
            return RunOutcome(actionID: actionID, decision: decision, result: nil)

        case .dryRun:
            let preview = await action.dryRun()
            // A dry-run audits as a non-mutating entry so the LLM/popover can
            // see "we previewed X". Map the preview into a result shell.
            let free = ActionShell.bootVolumeFreeBytes()
            let result = ActionResult(
                actionID: actionID,
                succeeded: !preview.skipped,
                skipped: preview.skipped,
                freedBytes: 0,
                beforeFreeBytes: free,
                afterFreeBytes: free,
                error: nil
            )
            await audit.record(result: result, trigger: trigger, policyDecision: decision.auditString)
            return RunOutcome(actionID: actionID, decision: decision, result: result)

        case .allow:
            let result = await action.execute()
            // Stamp the policy timing AFTER a real run so cool-down +
            // rate-limit see it (auto runs consume the rate budget; a
            // confirmed click stamps cool-down but not the auto budget).
            await policy.recordRun(actionID: actionID, trigger: trigger)
            await audit.record(result: result, trigger: trigger, policyDecision: decision.auditString)
            log.info("action \(actionID, privacy: .public) ran trigger=\(trigger.rawValue, privacy: .public) freed=\(result.freedBytes, privacy: .public) skipped=\(result.skipped, privacy: .public)")
            return RunOutcome(actionID: actionID, decision: decision, result: result)
        }
    }

    /// AUTO path: handle a watchdog event. For an `appeared`/`escalated`
    /// alert, find the actions mapped to its probe+severity and run each
    /// through the auto gate chain. `cleared` events are ignored (nothing to
    /// clean for a resolved alert).
    ///
    /// The context is fetched ONCE per event and shared across all mapped
    /// actions so power/focus/config are consistent within one decision pass.
    public func handleAlertEvent(_ event: WatchdogEvent) async {
        let alert: Alert
        switch event {
        case .appeared(let a):   alert = a
        case .escalated(let a, _): alert = a
        case .cleared:           return
        }
        let ctx = await contextProvider()
        let mapped = await registry.actionsFor(probe: alert.probe, severity: alert.severity, config: ctx.config)
        guard !mapped.isEmpty else { return }
        for action in mapped {
            // Only auto-eligible (opted-in) actions actually execute; the
            // PolicyEngine enabled-gate denies the rest (audited as a deny).
            // We still evaluate them so a denied auto attempt is recorded —
            // but to avoid audit spam for the (default) all-off case, skip
            // evaluation entirely when the action is not auto-enabled.
            if ctx.config[id: action.descriptor.id]?.autoEnabled == true {
                _ = await self.run(actionID: action.descriptor.id, trigger: .auto, context: ctx)
            }
        }
    }

    /// Recent audit entries (for the popover / REST / MCP). Pass-through to
    /// the audit log's in-memory tail.
    public func recentAudit(_ limit: Int = 50) async -> [AuditLog.Entry] {
        await audit.recent(limit)
    }

    /// Descriptors (for REST/MCP/Settings listings).
    public func descriptors() async -> [ActionDescriptor] {
        await registry.allDescriptors()
    }

    /// Descriptor for a single action id, or nil if unknown (pass-through to the
    /// registry). Used by the B2 run funnel (`RESTHandlers.runAction`) to resolve
    /// a requested id → 404 when unknown, and to read the display name for the
    /// human-tap approval notification. Reuses the ONE registry — no new lookup.
    public func descriptor(id: String) async -> ActionDescriptor? {
        await registry.descriptor(id: id)
    }
}
