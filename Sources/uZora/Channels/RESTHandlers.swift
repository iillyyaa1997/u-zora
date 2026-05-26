import Foundation
import os

/// Request handlers for the four REST endpoints described in DESIGN §3
/// (channels layer). Each handler reads from `StateStore` and returns
/// a JSON `HTTPResponse`.
///
/// Schema design rule: response keys are snake_case so the same JSON is
/// idiomatic for Python / shell consumers without renaming. Swift Codable
/// uses `convertToSnakeCase` strategy.
public struct RESTHandlers: Sendable {

    public let state: StateStore
    /// Phase 6: optional metrics store. When wired, `GET /metrics`
    /// returns persisted samples; when nil the endpoint still answers
    /// but returns an empty series with a "no store wired" note.
    public let metricsStore: MetricsStore?
    private let encoder: JSONEncoder
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "rest")

    public init(state: StateStore, metricsStore: MetricsStore? = nil) {
        self.state = state
        self.metricsStore = metricsStore
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        enc.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = enc
    }

    // MARK: - GET /status

    public struct StatusResponse: Codable, Sendable {
        public let status: String
        public let uptimeSec: Double
        public let activeAlertsCount: Int
        public let probesRegistered: Int
        public let powerState: String

        public init(status: String, uptimeSec: Double, activeAlertsCount: Int, probesRegistered: Int, powerState: String) {
            self.status = status
            self.uptimeSec = uptimeSec
            self.activeAlertsCount = activeAlertsCount
            self.probesRegistered = probesRegistered
            self.powerState = powerState
        }
    }

    public func status() async -> HTTPResponse {
        let snap = await state.snapshot()
        let response = StatusResponse(
            status: "ok",
            uptimeSec: snap.uptimeSeconds,
            activeAlertsCount: snap.activeAlerts.count,
            probesRegistered: snap.probes.count,
            powerState: snap.powerState
        )
        return encode(response)
    }

    // MARK: - GET /alerts

    public struct AlertsResponse: Codable, Sendable {
        public let alerts: [Alert]
        public init(alerts: [Alert]) { self.alerts = alerts }
    }

    public func alerts(minSeverity floor: Severity? = nil) async -> HTTPResponse {
        let alerts: [Alert]
        if let floor {
            alerts = await state.activeAlerts(minSeverity: floor)
        } else {
            alerts = await state.activeAlerts()
        }
        return encode(AlertsResponse(alerts: alerts))
    }

    // MARK: - GET /probes

    public struct ProbesResponse: Codable, Sendable {
        public let probes: [StateStore.ProbeInfo]
        public init(probes: [StateStore.ProbeInfo]) { self.probes = probes }
    }

    public func probes() async -> HTTPResponse {
        let probes = await state.probeInventory()
        return encode(ProbesResponse(probes: probes))
    }

    // MARK: - GET /metrics

    /// Phase 6 response: a flat list of samples for the requested
    /// (probe, optional metric name, time range). Keys are snake_case so
    /// the same JSON is idiomatic for Python / shell consumers.
    public struct MetricsResponse: Codable, Sendable {
        public let probe: String?
        public let name: String?
        public let from: Date?
        public let to: Date?
        public let samples: [MetricsStore.Sample]
        public let count: Int
        public let note: String?

        public init(
            probe: String?,
            name: String?,
            from: Date?,
            to: Date?,
            samples: [MetricsStore.Sample],
            note: String? = nil
        ) {
            self.probe = probe
            self.name = name
            self.from = from
            self.to = to
            self.samples = samples
            self.count = samples.count
            self.note = note
        }
    }

    public func metrics(probe: String?, name: String? = nil, from: Date?, to: Date?) async -> HTTPResponse {
        // Default time window: last 1 hour. Per DESIGN §3.2 the endpoint
        // exists primarily for popover-driven graphs which span minutes.
        let now = Date()
        let effectiveTo = to ?? now
        let effectiveFrom = from ?? effectiveTo.addingTimeInterval(-3600)

        guard let probe = probe, !probe.isEmpty else {
            return encode(MetricsResponse(
                probe: nil, name: name,
                from: effectiveFrom, to: effectiveTo,
                samples: [],
                note: "probe= query parameter is required"
            ), status: 400)
        }

        guard let store = metricsStore else {
            return encode(MetricsResponse(
                probe: probe, name: name,
                from: effectiveFrom, to: effectiveTo,
                samples: [],
                note: "metrics store not wired (running headless?)"
            ), status: 200)
        }

        do {
            let samples = try await store.query(
                probe: probe,
                from: effectiveFrom,
                to: effectiveTo,
                name: name
            )
            return encode(MetricsResponse(
                probe: probe, name: name,
                from: effectiveFrom, to: effectiveTo,
                samples: samples
            ), status: 200)
        } catch {
            log.error("metrics query failed: \(String(describing: error), privacy: .public)")
            return HTTPResponse.serverError("metrics query failed: \(error)")
        }
    }

    // MARK: - Dispatch helpers

    /// Resolve a REST request to a JSON response. Used by both the HTTP
    /// server route table and the MCP `tools/call` dispatcher.
    public func dispatch(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/status"):
            return await status()
        case ("GET", "/alerts"):
            let floor = request.query["severity"].flatMap { Severity(rawValue: $0) }
            return await alerts(minSeverity: floor)
        case ("GET", "/probes"):
            return await probes()
        case ("GET", "/metrics"):
            let probe = request.query["probe"]
            let name = request.query["name"]
            let from = request.query["from"].flatMap { Self.parseISO8601($0) }
            let to = request.query["to"].flatMap { Self.parseISO8601($0) }
            return await metrics(probe: probe, name: name, from: from, to: to)
        default:
            return HTTPResponse.notFound("no REST route for \(request.method) \(request.path)")
        }
    }

    // MARK: - Internals

    private func encode<T: Codable>(_ value: T, status: Int = 200) -> HTTPResponse {
        do {
            let data = try encoder.encode(value)
            return HTTPResponse.jsonData(data, status: status)
        } catch {
            return HTTPResponse.serverError("json encode failed: \(error)")
        }
    }

    static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
