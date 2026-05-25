import Foundation
import os

/// Reads `ProcessInfo.processInfo.thermalState` (public Foundation API) and
/// maps it to a uZora `Severity`.
///
/// In Phase 3 the probe will also subscribe to
/// `ProcessInfo.thermalStateDidChangeNotification` for instant edges; for
/// now we keep it polling-only since the registry's per-probe schedulers
/// arrive in Phase 3.
public final class ThermalPressureProbe: Probe, @unchecked Sendable {

    public let name = "thermal"
    public let pollInterval: Duration = .seconds(5)

    private let processInfo: ProcessInfo
    private let clock: @Sendable () -> Date
    private var firstSeenAt: Date?

    private let log = Logger(
        subsystem: "place.unicorns.uzora",
        category: "thermal"
    )

    public convenience init() {
        self.init(processInfo: .processInfo, clock: { Date() })
    }

    /// Designated init — `ProcessInfo` is final, but the state property is
    /// readable on any instance, so a `.processInfo` reference is fine here.
    public init(processInfo: ProcessInfo, clock: @escaping @Sendable () -> Date) {
        self.processInfo = processInfo
        self.clock = clock
    }

    public func run() async throws -> [Alert] {
        let state = processInfo.thermalState
        guard let severity = Self.severity(for: state) else {
            firstSeenAt = nil
            return []
        }

        let now = clock()
        if firstSeenAt == nil { firstSeenAt = now }

        let alert = Alert(
            probe: name,
            key: "system",
            severity: severity,
            message: Self.describe(state),
            details: [
                "state": Self.label(state),
            ],
            firstSeen: firstSeenAt ?? now,
            lastUpdated: now
        )
        return [alert]
    }

    // MARK: - Pure severity mapping (table-tested)

    /// Map a `ProcessInfo.ThermalState` to a uZora severity.
    /// `.nominal` → no alert; `.fair` → info; `.serious` → warn; `.critical` → critical.
    public static func severity(for state: ProcessInfo.ThermalState) -> Severity? {
        switch state {
        case .nominal:  return nil
        case .fair:     return .info
        case .serious:  return .warn
        case .critical: return .critical
        @unknown default:
            return .info
        }
    }

    public static func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "System thermals nominal"
        case .fair:     return "System thermals fair — slight warming"
        case .serious:  return "Thermal pressure SERIOUS — clocks may throttle"
        case .critical: return "Thermal pressure CRITICAL — aggressive throttling active"
        @unknown default: return "Thermal pressure unknown state"
        }
    }
}
