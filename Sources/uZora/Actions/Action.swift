import Foundation

/// Q10 auto-actions — core protocol + value types.
///
/// An `Action` is a *reversible* cleanup operation uZora can run either on
/// explicit user confirmation (a notification "Run" button) or fully
/// automatically when the user has opted that action in AND every
/// `PolicyEngine` gate passes. The full design + locked scope lives in
/// `_planing/u-zora-auto-actions-design-2026-06-01.md`.
///
/// MVP class (locked Q1): only reversible disk/cache cleanup. No
/// kill-process, no system-tweaks, no sudo. The `reversible` /
/// `requiresSudo` descriptor flags are carried so a future iteration can
/// add non-reversible / privileged actions behind stricter gates, but
/// none ship now (`reversible == true`, `requiresSudo == false` for all).

/// Static metadata describing one action. `Sendable` value type so it can
/// cross the actor boundary into the `ActionRegistry` / channel layer.
///
/// Modelled on `ProbesConfig.ProbeDescriptor` — the descriptor is the
/// single source of truth for an action's identity, its localized
/// display strings, and its default alert binding (hybrid mapping, Q6).
public struct ActionDescriptor: Sendable, Equatable {
    /// Stable id, e.g. `"prune_apfs_snapshots"`. Used as the config key,
    /// the audit-log `action_id`, and the notification action identifier.
    public let id: String
    /// Localized display name for Settings / notifications / MCP.
    public let name: String
    /// Localized one-line description of what the action does (includes the
    /// caution note for `clear_user_caches`).
    public let detail: String
    /// All actions in this iteration are reversible (Q1). The gate chain
    /// refuses to auto-run a non-reversible action.
    public let reversible: Bool
    /// All actions in this iteration avoid sudo (Q1). Carried so a future
    /// privileged-helper action can be gated separately.
    public let requiresSudo: Bool
    /// `clear_user_caches` is flagged caution — Settings surfaces a stronger
    /// warning and it is never a safe default.
    public let caution: Bool
    /// The probe this action is bound to by default (Q6 hybrid mapping).
    /// All four MVP actions → `"disk"`.
    public let relatedProbe: String
    /// Minimum alert severity that makes this action eligible. `.warn` means
    /// the action is offered/eligible on a warn-or-critical alert.
    public let relatedSeverityFloor: Severity

    public init(
        id: String,
        name: String,
        detail: String,
        reversible: Bool,
        requiresSudo: Bool,
        caution: Bool = false,
        relatedProbe: String,
        relatedSeverityFloor: Severity
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.reversible = reversible
        self.requiresSudo = requiresSudo
        self.caution = caution
        self.relatedProbe = relatedProbe
        self.relatedSeverityFloor = relatedSeverityFloor
    }
}

/// What a `dryRun()` predicts WITHOUT mutating anything.
public struct ActionPreview: Sendable, Equatable {
    /// Action this preview is for.
    public let actionID: String
    /// Estimated bytes that *would* be freed if the action ran now. Best
    /// effort — a `0` with `skipped == true` means "nothing to do".
    public let estimatedFreedBytes: UInt64
    /// Human-readable summary of what would happen.
    public let summary: String
    /// True when the action would be a no-op (brew not installed, no
    /// snapshots present, empty cache dir). A skipped action still audits.
    public let skipped: Bool
    /// Non-fatal note (e.g. "brew not found on PATH").
    public let note: String?

    public init(
        actionID: String,
        estimatedFreedBytes: UInt64,
        summary: String,
        skipped: Bool = false,
        note: String? = nil
    ) {
        self.actionID = actionID
        self.estimatedFreedBytes = estimatedFreedBytes
        self.summary = summary
        self.skipped = skipped
        self.note = note
    }
}

/// Outcome of an `execute()`.
public struct ActionResult: Sendable, Equatable {
    public let actionID: String
    /// `true` if the action ran without an error (a graceful skip — brew
    /// absent — is still `succeeded == true`, `skipped == true`).
    public let succeeded: Bool
    /// `true` when the action found nothing to do (no mutation performed).
    public let skipped: Bool
    /// Bytes actually freed, measured as `beforeFreeBytes` → `afterFreeBytes`
    /// delta on the boot volume (clamped at 0; other processes can allocate
    /// concurrently, so this is approximate).
    public let freedBytes: UInt64
    /// Boot-volume free bytes sampled immediately before the action.
    public let beforeFreeBytes: UInt64
    /// Boot-volume free bytes sampled immediately after the action.
    public let afterFreeBytes: UInt64
    /// Error description on failure, else nil.
    public let error: String?

    public init(
        actionID: String,
        succeeded: Bool,
        skipped: Bool,
        freedBytes: UInt64,
        beforeFreeBytes: UInt64,
        afterFreeBytes: UInt64,
        error: String? = nil
    ) {
        self.actionID = actionID
        self.succeeded = succeeded
        self.skipped = skipped
        self.freedBytes = freedBytes
        self.beforeFreeBytes = beforeFreeBytes
        self.afterFreeBytes = afterFreeBytes
        self.error = error
    }

    /// Convenience: a clean skip (no mutation, no error) at a known free level.
    public static func skipped(
        _ actionID: String,
        freeBytes: UInt64,
        error: String? = nil
    ) -> ActionResult {
        ActionResult(
            actionID: actionID,
            succeeded: error == nil,
            skipped: true,
            freedBytes: 0,
            beforeFreeBytes: freeBytes,
            afterFreeBytes: freeBytes,
            error: error
        )
    }
}

/// How an action run was triggered. Mirrored into the audit log + the
/// `PolicyEngine` so the enabled-gate can be bypassed for an explicit user
/// click while still honouring reversibility + audit.
public enum ActionTrigger: String, Sendable, Codable, Equatable {
    /// Fully automatic (rule fired + all gates passed).
    case auto
    /// User clicked the notification "Run" button.
    case confirmed
    /// A dry-run preview (no mutation).
    case dryRun = "dry_run"
}

/// A reversible cleanup action. Implementations live in `Actions/Impl/`.
///
/// `Sendable` so instances can be held by the `ActionRegistry` actor and
/// invoked from the event pipeline / notification handler.
public protocol Action: Sendable {
    var descriptor: ActionDescriptor { get }

    /// Predict the effect WITHOUT mutating the system. Safe to call any
    /// time (used for the dry-run preview + LLM-visible estimates).
    func dryRun() async -> ActionPreview

    /// Perform the action. Returns freed bytes + before/after + any error.
    /// MUST only ever touch the action's documented target path(s) — see
    /// `ActionPathGuard`.
    func execute() async -> ActionResult
}
