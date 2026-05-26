import Foundation

/// In-memory snapshot store for HTTP/MCP/SSE channels.
///
/// Subscribes to `EventBus` to maintain a live mirror of the currently
/// firing alert set, a small ring-buffer of recent lifecycle events, the
/// registered probe inventory, and a process uptime baseline.
///
/// `StateStore` is **read-only** from the channel side — the only writers
/// are `ingest(_:)` (from the EventBus subscription) and the registry
/// snapshot helpers used at boot. Channels query through `snapshot()` and
/// the typed accessors, never mutate state.
///
/// All channel handlers go through this store rather than the raw
/// EventBus / ProbeRegistry; that keeps the channel layer testable in
/// isolation (instantiate a `StateStore`, push synthetic events, assert
/// handler output) and decouples channel response shape from the Core
/// scheduler timing.
public actor StateStore {

    public struct RecordedEvent: Sendable, Codable, Equatable {
        public let timestamp: Date
        public let event: WatchdogEvent
        public init(timestamp: Date, event: WatchdogEvent) {
            self.timestamp = timestamp
            self.event = event
        }
    }

    public struct ProbeInfo: Sendable, Codable, Equatable {
        public let name: String
        public let pollIntervalSeconds: Double
        public let lastRunAt: Date?
        public init(name: String, pollIntervalSeconds: Double, lastRunAt: Date?) {
            self.name = name
            self.pollIntervalSeconds = pollIntervalSeconds
            self.lastRunAt = lastRunAt
        }
    }

    public struct Snapshot: Sendable, Codable, Equatable {
        public let uptimeSeconds: Double
        public let activeAlerts: [Alert]
        public let probes: [ProbeInfo]
        public let powerState: String
        public init(uptimeSeconds: Double, activeAlerts: [Alert], probes: [ProbeInfo], powerState: String) {
            self.uptimeSeconds = uptimeSeconds
            self.activeAlerts = activeAlerts
            self.probes = probes
            self.powerState = powerState
        }
    }

    private let startedAt: Date
    private var activeAlertsByID: [Alert.ID: Alert] = [:]
    private var recentEvents: [RecordedEvent] = []
    private var probes: [String: ProbeInfo] = [:]
    private var powerState: String = "—"
    private let ringBufferLimit: Int

    public init(ringBufferLimit: Int = 1000) {
        self.startedAt = Date()
        self.ringBufferLimit = ringBufferLimit
    }

    /// Apply a single watchdog event to the in-memory state.
    public func ingest(_ event: WatchdogEvent, at timestamp: Date = Date()) {
        recentEvents.append(RecordedEvent(timestamp: timestamp, event: event))
        if recentEvents.count > ringBufferLimit {
            recentEvents.removeFirst(recentEvents.count - ringBufferLimit)
        }
        switch event {
        case .appeared(let alert):
            activeAlertsByID[alert.id] = alert
        case .escalated(let alert, _):
            activeAlertsByID[alert.id] = alert
        case .cleared(let id):
            activeAlertsByID.removeValue(forKey: id)
        }
    }

    /// Replace the registered probe roster (called at boot from
    /// `ProbeRegistry.registeredNames()`).
    public func setProbes(_ infos: [ProbeInfo]) {
        probes = Dictionary(uniqueKeysWithValues: infos.map { ($0.name, $0) })
    }

    /// Stamp last-run timestamp for a probe.
    public func markProbeRun(_ name: String, at timestamp: Date = Date()) {
        guard var info = probes[name] else { return }
        info = ProbeInfo(name: info.name, pollIntervalSeconds: info.pollIntervalSeconds, lastRunAt: timestamp)
        probes[name] = info
    }

    /// Update the cached power-state label.
    public func updatePowerState(_ label: String) {
        powerState = label
    }

    /// Snapshot the active alert set sorted by id for stable output.
    public func activeAlerts() -> [Alert] {
        activeAlertsByID.values.sorted { $0.id < $1.id }
    }

    /// Filtered view: alerts at or above the supplied severity.
    public func activeAlerts(minSeverity floor: Severity) -> [Alert] {
        activeAlerts().filter { $0.severity >= floor }
    }

    /// Snapshot the registered probes (stable sorted-by-name order).
    public func probeInventory() -> [ProbeInfo] {
        probes.values.sorted { $0.name < $1.name }
    }

    /// Snapshot the most recent N events.
    public func recent(_ limit: Int = 100) -> [RecordedEvent] {
        let n = max(0, min(limit, recentEvents.count))
        if n == 0 { return [] }
        return Array(recentEvents.suffix(n))
    }

    /// Wall-clock seconds since this store was created.
    public func uptime() -> Double {
        Date().timeIntervalSince(startedAt)
    }

    /// Convenience: full snapshot used by REST `/status`.
    public func snapshot() -> Snapshot {
        Snapshot(
            uptimeSeconds: uptime(),
            activeAlerts: activeAlerts(),
            probes: probeInventory(),
            powerState: powerState
        )
    }

    /// Total in-buffer event count (test affordance).
    public var recordedCount: Int { recentEvents.count }
}
