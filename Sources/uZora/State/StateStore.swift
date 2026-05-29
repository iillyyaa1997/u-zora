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
    /// IDs of alerts the user (or an LLM via the bridge) has acknowledged.
    /// An acked id is hidden from `activeAlerts()` / `activeAlerts(minSeverity:)`
    /// — and therefore from /alerts, /status counts, the popover, and MCP —
    /// but the alert itself stays in `activeAlertsByID` so an escalation can
    /// re-surface it (the ack is cleared on `.escalated`) and a clear can
    /// retire it cleanly (the ack is dropped on `.cleared`).
    private var acknowledgedIDs: Set<Alert.ID> = []
    private var recentEvents: [RecordedEvent] = []
    private var probes: [String: ProbeInfo] = [:]
    private var powerState: String = "—"
    private let ringBufferLimit: Int

    public init(ringBufferLimit: Int = 1000) {
        self.startedAt = Date()
        self.ringBufferLimit = ringBufferLimit
    }

    /// Seed the active-alert set from a known-good snapshot — used at
    /// boot to hydrate from the persisted Watchdog state, so idempotent
    /// re-runs (no fresh `appeared` events emitted) still surface the
    /// firing alerts via REST/MCP/popover.
    ///
    /// No `RecordedEvent` is appended: this is not a transition, it's a
    /// state restore. Callers should run this **before** wiring up event
    /// subscriptions to avoid double-counting.
    public func seedActiveAlerts(_ alerts: [Alert]) {
        for a in alerts {
            activeAlertsByID[a.id] = a
        }
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
            // A fresh `appeared` means any prior ack is stale (the alert had
            // cleared and come back, or is brand-new). Clear it so the new
            // instance surfaces.
            acknowledgedIDs.remove(alert.id)
        case .escalated(let alert, _):
            activeAlertsByID[alert.id] = alert
            // Escalation re-surfaces an acked alert: the situation got worse,
            // so the prior acknowledgement no longer applies.
            acknowledgedIDs.remove(alert.id)
        case .cleared(let id):
            activeAlertsByID.removeValue(forKey: id)
            // The alert is gone; drop the ack so a future re-appearance is a
            // fresh, unacknowledged alert.
            acknowledgedIDs.remove(id)
        }
    }

    /// Acknowledge a currently-firing alert by id. UI-state only — this does
    /// NOT touch the OS, only hides the alert from the active set until it
    /// escalates or clears. Returns `false` if no active alert has that id
    /// (already cleared, never existed, or already acknowledged-then-cleared).
    @discardableResult
    public func acknowledge(_ id: Alert.ID) -> Bool {
        guard activeAlertsByID[id] != nil else { return false }
        acknowledgedIDs.insert(id)
        return true
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
    /// Acknowledged alerts are excluded — they remain tracked internally so
    /// an escalation can re-surface them, but every read surface (/alerts,
    /// /status count, popover, MCP) sees only the un-acked set.
    public func activeAlerts() -> [Alert] {
        activeAlertsByID.values
            .filter { !acknowledgedIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
    }

    /// Filtered view: alerts at or above the supplied severity. Inherits the
    /// acknowledged-alert exclusion from `activeAlerts()`.
    public func activeAlerts(minSeverity floor: Severity) -> [Alert] {
        activeAlerts().filter { $0.severity >= floor }
    }

    /// Number of currently-acknowledged alerts that are still firing
    /// (acked-and-hidden but not yet cleared/escalated). Cheap O(n) count
    /// over the active set so a stale ack (whose alert already cleared) is
    /// never counted.
    public func acknowledgedCount() -> Int {
        activeAlertsByID.keys.reduce(into: 0) { acc, id in
            if acknowledgedIDs.contains(id) { acc += 1 }
        }
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
