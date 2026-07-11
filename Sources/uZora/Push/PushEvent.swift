import Foundation

/// The UNIFIED event the proactive-push pipeline operates on (report 09 §1b).
///
/// Both event sources — the `WatchdogEvent` `EventBus` (alert transitions) and
/// the `DiagnosisStreamEvent` `DiagnosisEventBus` (findings + verdict-level
/// changes) — are mapped down to this single flat shape so the filter /
/// coalesce / rate-limit / dispatch pipeline is written ONCE, independent of the
/// origin bus. Deliberately a SIBLING of the channel-layer `DiagnosisEventLine`
/// (which serves `/stream`): this one is the push producer's internal currency.
public struct PushEvent: Sendable, Equatable, Codable {

    /// The event CLASS, matching the `[push] kinds` config vocabulary.
    public enum Kind: String, Sendable, Codable, Equatable {
        /// A watchdog `Alert` transition (appeared / escalated / cleared).
        case alert
        /// An aggregate verdict-LEVEL change (good↔watch↔degraded↔problem).
        case verdict
        /// A per-diagnosis `Finding` diff (diagnosed / rediagnosed / resolved).
        case finding
    }

    public let kind: Kind
    /// The push severity. For `alert` / `finding` it is the alert/finding's own
    /// severity; for `verdict` it is the level mapped via `pushSeverity`. A
    /// `cleared` event carries `.info` (a placeholder — cleared events SKIP the
    /// severity-floor gate, see `ProactivePush`).
    public let severity: Severity
    /// The coalescing subject — `alert`/`finding` use their `probe:key`
    /// (`detector:subject`) id; `verdict` uses the constant `"verdict"`.
    public let subject: String
    /// The plain-language one-line summary. This is the SINGLE argv token
    /// appended to `exec_argv` for the local-exec backend (never a shell
    /// string) and the human-readable field in the outbox line.
    public let summary: String
    /// Whether this event is a resolution (`*.cleared` / `resolved` / verdict→
    /// good). Gated by `[push] push_cleared`.
    public let cleared: Bool
    public let ts: Date

    public init(
        kind: Kind,
        severity: Severity,
        subject: String,
        summary: String,
        cleared: Bool,
        ts: Date
    ) {
        self.kind = kind
        self.severity = severity
        self.subject = subject
        self.summary = summary
        self.cleared = cleared
        self.ts = ts
    }

    /// The coalescing key — a repeat push for the same `kind`+`subject` inside
    /// the cool-down window is suppressed.
    public var coalesceKey: String { "\(kind.rawValue):\(subject)" }

    public enum CodingKeys: String, CodingKey {
        case kind
        case severity
        case subject
        case summary
        case cleared
        case ts
    }

    // MARK: - Mapping from the two source buses

    /// Map a `WatchdogEvent` (from `EventBus`) to a unified `PushEvent`.
    public static func from(watchdog event: WatchdogEvent, at ts: Date) -> PushEvent {
        switch event {
        case .appeared(let alert):
            return PushEvent(
                kind: .alert,
                severity: alert.severity,
                subject: alert.id,
                summary: "[\(alert.severity.rawValue)] \(alert.id) — \(alert.message)",
                cleared: false,
                ts: ts
            )
        case .escalated(let alert, let previousSeverity):
            return PushEvent(
                kind: .alert,
                severity: alert.severity,
                subject: alert.id,
                summary: "[\(previousSeverity.rawValue)→\(alert.severity.rawValue)] \(alert.id) — \(alert.message)",
                cleared: false,
                ts: ts
            )
        case .cleared(let id):
            // A cleared event carries no severity (the `WatchdogEvent.cleared`
            // case is only the id) — `.info` is a placeholder; cleared events
            // are gated by `push_cleared`, NOT the severity floor.
            return PushEvent(
                kind: .alert,
                severity: .info,
                subject: id,
                summary: "[cleared] \(id) resolved",
                cleared: true,
                ts: ts
            )
        }
    }

    /// Map a `DiagnosisStreamEvent` (from `DiagnosisEventBus`) to a unified
    /// `PushEvent`.
    public static func from(diagnosis event: DiagnosisStreamEvent, at ts: Date) -> PushEvent {
        switch event {
        case .finding(.diagnosed(let f)):
            return PushEvent(
                kind: .finding,
                severity: f.severity,
                subject: f.id,
                summary: "[\(f.severity.rawValue)] \(f.id) — \(f.title)",
                cleared: false,
                ts: ts
            )
        case .finding(.rediagnosed(let f, _, _)):
            return PushEvent(
                kind: .finding,
                severity: f.severity,
                subject: f.id,
                summary: "[\(f.severity.rawValue)] \(f.id) — \(f.title)",
                cleared: false,
                ts: ts
            )
        case .finding(.resolved(let id)):
            return PushEvent(
                kind: .finding,
                severity: .info,
                subject: id,
                summary: "[cleared] \(id) resolved",
                cleared: true,
                ts: ts
            )
        case .verdictChanged(_, let to, let headline):
            return PushEvent(
                kind: .verdict,
                severity: to.pushSeverity,
                subject: "verdict",
                summary: "[\(to.rawValue)] system health — \(headline)",
                // A verdict returning to `good` is a resolution.
                cleared: to == .good,
                ts: ts
            )
        }
    }
}

extension VerdictLevel {
    /// Map a verdict LEVEL onto the `Severity` axis for the push floor gate.
    /// good/watch → info, degraded → warn, problem → critical — so the DEFAULT
    /// `severity_floor = critical` pushes only `problem` verdicts.
    public var pushSeverity: Severity {
        switch self {
        case .good:     return .info
        case .watch:    return .info
        case .degraded: return .warn
        case .problem:  return .critical
        }
    }
}
