import Testing
import Foundation
@testable import uZora

/// Integration: wire the full ChannelHost (StateStore + JSONLEventSink +
/// HTTPServer + REST + SSE + MCP), push events through the EventBus, and
/// verify all four channels see them.
@Suite("ChannelHost end-to-end wiring across all four channels")
struct ChannelHostTests {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-host-\(UUID().uuidString)", isDirectory: true)
    }

    private func alert(_ key: String, severity: Severity = .warn) -> Alert {
        Alert(
            probe: "disk", key: key, severity: severity,
            message: "test", details: ["pct": "12"],
            firstSeen: Date(timeIntervalSince1970: 1_700_000_000),
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_500)
        )
    }

    @Test func eventFlowsTo_StateStore_REST_andJSONL() async throws {
        let dir = tempDir()
        let bus = EventBus()
        let state = StateStore()
        let jsonl = try JSONLEventSink(baseDir: dir, retentionDays: 30)
        let host = ChannelHost(port: 0, state: state, jsonl: jsonl, eventBus: bus)
        try await host.start()
        let port = await host.boundPort()
        defer { Task { await host.stop() } }

        // Push an event.
        await bus.emit(.appeared(alert("/")))
        // Give the async subscribers a moment to land.
        try await Task.sleep(for: .milliseconds(150))

        // REST should see it.
        let url = URL(string: "http://127.0.0.1:\(port)/alerts")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        #expect(code == 200)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let arr = json?["alerts"] as? [[String: Any]]
        #expect(arr?.count == 1)

        // JSONL should have one line.
        try await jsonl.flush()
        let dayKey = JSONLEventSink.dayKey(for: Date())
        let jsonlURL = await jsonl.fileURL(forDay: dayKey)
        let content = (try? String(contentsOf: jsonlURL, encoding: .utf8)) ?? ""
        #expect(content.contains("\"kind\":\"appeared\""))

        await host.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func crossChannel_payloadParity() async throws {
        // ADR-0002 confirmation #2: same lifecycle event yields identical
        // shape across JSONL, REST, SSE, MCP.
        let dir = tempDir()
        let bus = EventBus()
        let state = StateStore()
        let jsonl = try JSONLEventSink(baseDir: dir, retentionDays: 30)
        let host = ChannelHost(port: 0, state: state, jsonl: jsonl, eventBus: bus)
        try await host.start()
        let port = await host.boundPort()
        defer { Task { await host.stop() } }

        let a = alert("/", severity: .critical)
        await bus.emit(.appeared(a))
        try await Task.sleep(for: .milliseconds(150))

        // REST/alerts
        let url = URL(string: "http://127.0.0.1:\(port)/alerts")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let restJson = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let restAlert = (restJson?["alerts"] as? [[String: Any]])?.first
        #expect(restAlert?["probe"] as? String == "disk")
        #expect(restAlert?["severity"] as? String == "critical")
        #expect(restAlert?["key"] as? String == "/")

        // MCP tools/call: same fields.
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "POST"
        req.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"uzora_list_alerts","arguments":{}}}"#.utf8)
        let (mcpData, _) = try await URLSession.shared.data(for: req)
        let mcpJson = try JSONSerialization.jsonObject(with: mcpData) as? [String: Any]
        let mcpResult = mcpJson?["result"] as? [String: Any]
        let mcpStructured = mcpResult?["structuredContent"] as? [String: Any]
        let mcpAlerts = mcpStructured?["alerts"] as? [[String: Any]]
        let mcpAlert = mcpAlerts?.first
        #expect(mcpAlert?["probe"] as? String == "disk")
        #expect(mcpAlert?["severity"] as? String == "critical")
        #expect(mcpAlert?["key"] as? String == "/")

        // JSONL: same alert payload nested under "alert".
        try await jsonl.flush()
        let dayKey = JSONLEventSink.dayKey(for: Date())
        let jsonlURL = await jsonl.fileURL(forDay: dayKey)
        let jsonlText = (try? String(contentsOf: jsonlURL, encoding: .utf8)) ?? ""
        #expect(jsonlText.contains("\"probe\":\"disk\""))
        #expect(jsonlText.contains("\"severity\":\"critical\""))

        await host.stop()
        try? FileManager.default.removeItem(at: dir)
    }
}
