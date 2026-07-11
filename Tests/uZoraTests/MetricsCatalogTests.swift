import Testing
import Foundation
@testable import uZora

/// B1a (plan D-L5) — the metric-series catalog + MCP `get_metric` `name`
/// parity. Covers:
/// - `MetricsStore.distinctSeries()` returns the real (probe, name) pairs with
///   count + last value/timestamp.
/// - REST `GET /metrics/catalog` shape (snake_case) + nil-store degradation.
/// - MCP `uzora_list_metrics` wraps the catalog; appears in schemas.
/// - MCP `uzora_get_metric` honours the `name` arg (previously REST-only).
@Suite("Metrics catalog + get_metric name parity")
struct MetricsCatalogTests {

    private func seededStore() async throws -> MetricsStore {
        let store = try MetricsStore(inMemory: true)
        let now = Date()
        // battery has two series; disk has one.
        try await store.recordSample(probe: "battery", key: "internal", name: "charge_pct", value: 60, at: now.addingTimeInterval(-10))
        try await store.recordSample(probe: "battery", key: "internal", name: "charge_pct", value: 75, at: now)
        try await store.recordSample(probe: "battery", key: "internal", name: "cycles", value: 300, at: now)
        try await store.recordSample(probe: "disk", key: "/", name: "free_pct", value: 42, at: now)
        return store
    }

    private func json(_ resp: HTTPResponse) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
    }

    // MARK: - Store

    @Test func distinctSeries_returnsPairsWithLastValueAndCount() async throws {
        let store = try await seededStore()
        defer { Task { await store.close() } }
        let series = try await store.distinctSeries()
        // Sorted by (probe, name): battery/charge_pct, battery/cycles, disk/free_pct.
        #expect(series.count == 3)
        #expect(series.map { "\($0.probe):\($0.name)" } == [
            "battery:charge_pct", "battery:cycles", "disk:free_pct",
        ])
        let charge = series.first { $0.name == "charge_pct" }
        #expect(charge?.count == 2)
        #expect(charge?.lastValue == 75)   // most-recent, not the -10s row
    }

    @Test func distinctSeries_emptyStore() async throws {
        let store = try MetricsStore(inMemory: true)
        defer { Task { await store.close() } }
        #expect(try await store.distinctSeries().isEmpty)
    }

    // MARK: - REST /metrics/catalog

    @Test func restCatalog_snakeCaseShape() async throws {
        let store = try await seededStore()
        defer { Task { await store.close() } }
        let rest = RESTHandlers(state: StateStore(), metricsStore: store)
        let resp = await rest.metricsCatalog()
        #expect(resp.status == 200)
        let body = json(resp)
        #expect(body?["count"] as? Int == 3)
        let arr = body?["series"] as? [[String: Any]]
        #expect(arr?.count == 3)
        let charge = arr?.first { $0["name"] as? String == "charge_pct" }
        #expect(charge?["probe"] as? String == "battery")
        #expect((charge?["last_value"] as? Double) == 75)
        #expect(charge?["last_at"] != nil)     // snake_case timestamp present
        #expect(body?["note"] == nil)
    }

    @Test func restCatalog_nilStore_note() async {
        let rest = RESTHandlers(state: StateStore())   // no metricsStore
        let resp = await rest.metricsCatalog()
        #expect(resp.status == 200)
        let body = json(resp)
        #expect((body?["series"] as? [Any])?.isEmpty == true)
        #expect((body?["note"] as? String)?.contains("not wired") == true)
    }

    @Test func restCatalog_dispatchRoute() async throws {
        let store = try await seededStore()
        defer { Task { await store.close() } }
        let rest = RESTHandlers(state: StateStore(), metricsStore: store)
        let req = HTTPRequest(method: "GET", path: "/metrics/catalog", query: [:], headers: [:], body: Data())
        let resp = await rest.dispatch(req)
        #expect(resp.status == 200)
        #expect(json(resp)?["count"] as? Int == 3)
    }

    // MARK: - MCP list_metrics

    @Test func mcpListMetrics_wrapsCatalog() async throws {
        let store = try await seededStore()
        defer { Task { await store.close() } }
        let rest = RESTHandlers(state: StateStore(), metricsStore: store)
        let tools = MCPTools(rest: rest, httpBaseURL: "http://127.0.0.1:0")
        let result = try await tools.invoke(name: "uzora_list_metrics", arguments: .object([:]))
        guard case .object(let obj) = result,
              case .object(let sc)? = obj["structuredContent"],
              case .array(let arr)? = sc["series"] else {
            Issue.record("series array missing"); return
        }
        #expect(arr.count == 3)
        #expect(obj["isError"] == .bool(false))
    }

    @Test func mcpListMetrics_inSchemas() {
        let names = Set(MCPTools.readSchemas.compactMap { s -> String? in
            if case .string(let n)? = s["name"] { return n }
            return nil
        })
        #expect(names.contains("uzora_list_metrics"))
    }

    // MARK: - MCP get_metric name parity

    @Test func mcpGetMetric_honoursNameArg() async throws {
        let store = try await seededStore()
        defer { Task { await store.close() } }
        let rest = RESTHandlers(state: StateStore(), metricsStore: store)
        let tools = MCPTools(rest: rest, httpBaseURL: "http://127.0.0.1:0")

        // Wide window so time-range never excludes the seeded rows.
        let from = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let args: JSONValue = .object([
            "probe": .string("battery"),
            "name": .string("charge_pct"),
            "from": .string(from),
        ])
        let result = try await tools.invoke(name: "uzora_get_metric", arguments: args)
        guard case .object(let obj) = result,
              case .object(let sc)? = obj["structuredContent"] else {
            Issue.record("structuredContent missing"); return
        }
        // `name` echoed back + only the charge_pct series returned (2 rows),
        // NOT the battery `cycles` series — proving the name filter applied.
        if case .string(let name)? = sc["name"] { #expect(name == "charge_pct") }
        else { Issue.record("name not echoed") }
        guard case .array(let samples)? = sc["samples"] else {
            Issue.record("samples missing"); return
        }
        #expect(samples.count == 2)
        for s in samples {
            if case .object(let row) = s, case .string(let n)? = row["name"] {
                #expect(n == "charge_pct")
            }
        }
    }

    @Test func mcpGetMetric_nameSchemaAdvertised() {
        let getMetric = MCPTools.readSchemas.first {
            if case .string(let n)? = $0["name"] { return n == "uzora_get_metric" }
            return false
        }
        guard case .object(let input)? = getMetric?["inputSchema"],
              case .object(let props)? = input["properties"] else {
            Issue.record("get_metric inputSchema missing"); return
        }
        #expect(props["name"] != nil)
    }
}
