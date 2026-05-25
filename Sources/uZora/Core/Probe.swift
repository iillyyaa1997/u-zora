import Foundation

/// A probe samples some aspect of the system and emits `Alert`s when
/// something is out of normal range.
///
/// `run()` returns the *current* set of firing alerts (empty if all clear).
/// The registry diffs consecutive results to derive appear/escalate/clear
/// events via `Watchdog`.
public protocol Probe: Sendable {
    /// Unique name (e.g. `"disk"`, `"thermal"`, `"battery"`).
    var name: String { get }

    /// Recommended poll cadence; the registry may stretch under load.
    var pollInterval: Duration { get }

    /// Sample once and return all currently firing alerts.
    func run() async throws -> [Alert]
}
