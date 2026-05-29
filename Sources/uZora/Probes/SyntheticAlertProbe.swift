import Foundation
import os

/// A deterministic, system-independent probe used ONLY for end-to-end
/// testing. It is registered exclusively when the environment variable
/// `UZORA_E2E_SYNTHETIC_ALERT` is set to a non-empty value, so it never
/// runs in a normal production launch.
///
/// Behaviour is driven by `UZORA_E2E_SYNTHETIC_ALERT`:
///   - `warn`      → emits a single `warn` alert  (default for any truthy value)
///   - `critical`  → emits a single `critical` alert
///   - `clear`     → emits no alert (used to test the cleared-transition path
///                   on a restart whose env flips warn→clear)
///
/// This gives the E2E harness a guaranteed alert it can assert on
/// (`/alerts`, JSONL, SSE, restart-persistence) regardless of the host's
/// actual disk/thermal/battery state.
public final class SyntheticAlertProbe: Probe, @unchecked Sendable {
    public let name = "synthetic"
    public var pollInterval: Duration { .seconds(2) }

    private let mode: String
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "synthetic")

    /// Returns a probe instance if the E2E env var is set, else `nil`.
    public static func fromEnvironment() -> SyntheticAlertProbe? {
        guard let raw = ProcessInfo.processInfo.environment["UZORA_E2E_SYNTHETIC_ALERT"],
              !raw.isEmpty else {
            return nil
        }
        return SyntheticAlertProbe(mode: raw.lowercased())
    }

    public init(mode: String = "warn") {
        self.mode = mode
    }

    public func run() async throws -> [Alert] {
        let severity: Severity
        switch mode {
        case "clear":
            return []
        case "critical":
            severity = .critical
        default:
            severity = .warn
        }
        let now = Date()
        return [Alert(
            probe: name,
            key: "e2e",
            severity: severity,
            message: "Synthetic E2E alert (\(severity.rawValue))",
            details: ["mode": mode, "synthetic": "true"],
            firstSeen: now,
            lastUpdated: now
        )]
    }

    public func currentMetrics() async -> [String: Double] {
        // A constant series so the metrics path also has E2E coverage.
        ["synthetic_value": mode == "critical" ? 2.0 : 1.0]
    }
}
