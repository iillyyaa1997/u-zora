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
    private let encoder: JSONEncoder
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "rest")

    public init(state: StateStore) {
        self.state = state
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

    public struct MetricsResponse: Codable, Sendable {
        public let probe: String?
        public let from: Date?
        public let to: Date?
        public let series: [String]
        public let note: String

        public init(probe: String?, from: Date?, to: Date?, series: [String], note: String) {
            self.probe = probe
            self.from = from
            self.to = to
            self.series = series
            self.note = note
        }
    }

    public func metrics(probe: String?, from: Date?, to: Date?) async -> HTTPResponse {
        // Phase 4 returns the shape so consumers can write against it;
        // backing store (SQLite ring buffer) lands in Phase 5 per DESIGN
        // §3.2 (`MetricStore`).
        let response = MetricsResponse(
            probe: probe,
            from: from,
            to: to,
            series: [],
            note: "metrics history not yet implemented; awaiting SQLite (Phase 5)"
        )
        return encode(response, status: 200)
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
            let from = request.query["from"].flatMap { Self.parseISO8601($0) }
            let to = request.query["to"].flatMap { Self.parseISO8601($0) }
            return await metrics(probe: probe, from: from, to: to)
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
