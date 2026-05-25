import Foundation

/// Events derived from diffing consecutive alert sets.
public enum WatchdogEvent: Sendable {
    /// Alert appeared (was not present previously).
    case appeared(Alert)
    /// Alert remained firing but severity rose.
    case escalated(Alert, previousSeverity: Severity)
    /// Alert is no longer firing.
    case cleared(Alert.ID)
}

/// Diffs consecutive `Alert` sets and emits `WatchdogEvent`s.
///
/// Phase 1: signatures only. Real diff logic arrives in a later phase.
public actor Watchdog {
    public init() {}

    /// Compute events from a prior keyed alert state and the current snapshot.
    ///
    /// - Parameters:
    ///   - previous: previous alert set, keyed by `Alert.id`.
    ///   - current: current alert snapshot.
    /// - Returns: ordered list of state-transition events.
    public func diff(previous: [Alert.ID: Alert], current: [Alert]) -> [WatchdogEvent] {
        // TODO Phase 1+: implement appear / escalate / clear diff.
        _ = previous
        _ = current
        return []
    }
}
