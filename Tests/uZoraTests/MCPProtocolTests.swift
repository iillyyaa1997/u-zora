import Testing
import Foundation
@testable import uZora

/// JSON-RPC 2.0 / MCP protocol conformance tests. Bind the HTTP server,
/// POST envelopes at `/mcp`, assert response shape.
@Suite("MCPServer JSON-RPC 2.0 handshake & tool dispatch")
struct MCPProtocolTests {

    private func boot(state: StateStore) async throws -> (port: UInt16, server: HTTPServer) {
        let server = HTTPServer(port: 0)
        let rest = RESTHandlers(state: state)
        let mcp = MCPServer(tools: MCPTools(rest: rest, httpBaseURL: "http://127.0.0.1:0"))
        await server.register(method: "POST", path: "/mcp") { req in
            await mcp.handle(req)
        }
        try await server.start()
        let port = await server.boundPort
        return (port, server)
    }

    private func postJSON(_ port: UInt16, body: String) async throws -> (Int, [String: Any]?) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if data.isEmpty {
            return (code, nil)
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (code, json)
    }

    @Test func initialize_returnsHandshake() async throws {
        let store = StateStore()
        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        let envelope = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        let (code, json) = try await postJSON(port, body: envelope)
        #expect(code == 200)
        #expect(json?["jsonrpc"] as? String == "2.0")
        #expect(json?["id"] as? Int == 1)
        let result = json?["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == "2024-11-05")
        let serverInfo = result?["serverInfo"] as? [String: Any]
        #expect(serverInfo?["name"] as? String == "uzora")
        let caps = result?["capabilities"] as? [String: Any]
        #expect(caps?["tools"] != nil)
        await server.stop()
    }

    @Test func toolsList_advertisesAllTools() async throws {
        let store = StateStore()
        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        let envelope = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let (code, json) = try await postJSON(port, body: envelope)
        #expect(code == 200)
        let result = json?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        // Six read tools + two write tools (write tools are always listed,
        // even when allow_writes is off, so clients get a clear 403). The
        // sixth read tool is the Q10 read-only `uzora_list_actions`.
        #expect(tools?.count == 8)
        let names = Set(tools?.compactMap { $0["name"] as? String } ?? [])
        #expect(names == [
            "uzora_status", "uzora_list_alerts", "uzora_list_probes",
            "uzora_list_actions", "uzora_get_metric", "uzora_subscribe",
            "uzora_ack_alert", "uzora_set_probe_config",
        ])
        await server.stop()
    }

    @Test func toolsCall_status_invokesRESTHandler() async throws {
        let store = StateStore()
        await store.setProbes([
            StateStore.ProbeInfo(name: "disk", pollIntervalSeconds: 60, lastRunAt: nil),
        ])
        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        let envelope = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"uzora_status","arguments":{}}}"#
        let (code, json) = try await postJSON(port, body: envelope)
        #expect(code == 200)
        let result = json?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        #expect(content?.first?["type"] as? String == "text")
        let structured = result?["structuredContent"] as? [String: Any]
        #expect(structured?["status"] as? String == "ok")
        #expect(structured?["probes_registered"] as? Int == 1)
        #expect(result?["isError"] as? Bool == false)
        await server.stop()
    }

    @Test func toolsCall_listAlerts_filtersBySeverity() async throws {
        let store = StateStore()
        let info = Alert(probe: "x", key: "1", severity: .info, message: "", details: nil, firstSeen: Date(), lastUpdated: Date())
        let warn = Alert(probe: "x", key: "2", severity: .warn, message: "", details: nil, firstSeen: Date(), lastUpdated: Date())
        await store.ingest(.appeared(info))
        await store.ingest(.appeared(warn))
        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        let envelope = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"uzora_list_alerts","arguments":{"severity":"warn"}}}"#
        let (code, json) = try await postJSON(port, body: envelope)
        #expect(code == 200)
        let result = json?["result"] as? [String: Any]
        let structured = result?["structuredContent"] as? [String: Any]
        let alerts = structured?["alerts"] as? [[String: Any]]
        #expect(alerts?.count == 1)
        #expect(alerts?.first?["severity"] as? String == "warn")
        await server.stop()
    }

    @Test func toolsCall_subscribe_returnsSSEUrl() async throws {
        let store = StateStore()
        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        let envelope = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"uzora_subscribe","arguments":{}}}"#
        let (code, json) = try await postJSON(port, body: envelope)
        #expect(code == 200)
        let result = json?["result"] as? [String: Any]
        let structured = result?["structuredContent"] as? [String: Any]
        #expect((structured?["sse_url"] as? String)?.contains("/stream") == true)
        #expect(structured?["transport"] as? String == "server-sent-events")
        await server.stop()
    }

    @Test func unknownMethod_returns_jsonRpcError() async throws {
        let store = StateStore()
        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        let envelope = #"{"jsonrpc":"2.0","id":6,"method":"foo/bar"}"#
        let (code, json) = try await postJSON(port, body: envelope)
        #expect(code == 200)
        let err = json?["error"] as? [String: Any]
        #expect(err?["code"] as? Int == -32601) // methodNotFound
        await server.stop()
    }

    @Test func notification_initialized_returns202() async throws {
        let store = StateStore()
        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        // Notification = no `id` field; spec mandates HTTP 202 with empty body.
        let envelope = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let (code, _) = try await postJSON(port, body: envelope)
        #expect(code == 202)
        await server.stop()
    }

    @Test func parseError_returns_jsonRpcParseError() async throws {
        let store = StateStore()
        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        let bad = "this is not json {"
        let (code, json) = try await postJSON(port, body: bad)
        #expect(code == 200)
        let err = json?["error"] as? [String: Any]
        #expect(err?["code"] as? Int == -32700)
        await server.stop()
    }

    @Test func unknownTool_returns_toolNotFoundError() async throws {
        let store = StateStore()
        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        let envelope = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"does_not_exist","arguments":{}}}"#
        let (code, json) = try await postJSON(port, body: envelope)
        #expect(code == 200)
        let err = json?["error"] as? [String: Any]
        #expect(err?["code"] as? Int == -32000)
        await server.stop()
    }
}
