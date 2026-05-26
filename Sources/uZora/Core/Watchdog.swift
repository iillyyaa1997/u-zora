import Foundation

/// Events derived from diffing consecutive alert sets.
public enum WatchdogEvent: Sendable, Equatable {
    /// Alert appeared (was not present previously).
    case appeared(Alert)
    /// Alert remained firing but severity rose.
    case escalated(Alert, previousSeverity: Severity)
    /// Alert is no longer firing.
    case cleared(Alert.ID)
}

/// Diffs consecutive `Alert` sets and emits `WatchdogEvent`s.
///
/// State is held inside the actor: each call to `step(currentAlerts:)` is
/// compared against the previously-stored snapshot keyed by `Alert.id`,
/// then the snapshot is replaced. This makes the actor the single source
/// of truth for "what was firing the previous turn" — callers only need
/// to feed the current sample.
///
/// Idempotence: an alert that fires at the same severity across consecutive
/// turns produces **no** event. Only level transitions (appear / escalate
/// / clear) are surfaced. De-escalation back to a lower severity is treated
/// as the *same* alert continuing (no event) — explicit "downgrade" events
/// are intentionally not modelled in Phase 3; revisit if Phase 4 channels
/// need them.
public actor Watchdog {

    private var previousAlertsByID: [Alert.ID: Alert] = [:]

    public init() {}

    /// Compare the current alert snapshot against the prior one held in
    /// the actor, return the resulting events, and atomically replace the
    /// stored snapshot.
    ///
    /// Event order: appearances + escalations are returned in the order
    /// `currentAlerts` is presented; clearances are appended at the end
    /// in stable sorted-by-id order. This keeps EventBus subscriber output
    /// deterministic for testing.
    public func step(currentAlerts: [Alert]) -> [WatchdogEvent] {
        var events: [WatchdogEvent] = []
        var currentByID: [Alert.ID: Alert] = [:]

        for alert in currentAlerts {
            currentByID[alert.id] = alert
            if let prev = previousAlertsByID[alert.id] {
                if prev.severity < alert.severity {
                    events.append(.escalated(alert, previousSeverity: prev.severity))
                }
                // Same or lower severity: silent (idempotent).
            } else {
                events.append(.appeared(alert))
            }
        }

        // Cleared = was present, no longer is. Sort by id for stable order.
        let clearedIDs = previousAlertsByID.keys
            .filter { currentByID[$0] == nil }
            .sorted()
        for id in clearedIDs {
            events.append(.cleared(id))
        }

        previousAlertsByID = currentByID
        return events
    }

    /// Legacy signature kept for Phase 1+2 call-sites; computes a diff
    /// against a caller-provided previous map without touching internal
    /// state. Useful for pure unit tests of the diff algorithm itself.
    public func diff(previous: [Alert.ID: Alert], current: [Alert]) -> [WatchdogEvent] {
        var events: [WatchdogEvent] = []
        var currentByID: [Alert.ID: Alert] = [:]
        for alert in current {
            currentByID[alert.id] = alert
            if let prev = previous[alert.id] {
                if prev.severity < alert.severity {
                    events.append(.escalated(alert, previousSeverity: prev.severity))
                }
            } else {
                events.append(.appeared(alert))
            }
        }
        let clearedIDs = previous.keys.filter { currentByID[$0] == nil }.sorted()
        for id in clearedIDs {
            events.append(.cleared(id))
        }
        return events
    }

    /// Reset to "no prior alerts". Used by tests; the production app
    /// holds Watchdog for the lifetime of the process.
    public func reset() {
        previousAlertsByID = [:]
    }

    /// Snapshot of the currently-stored prior alert state. Read-only.
    public func snapshot() -> [Alert.ID: Alert] {
        previousAlertsByID
    }
}
