import Testing
import Foundation
@testable import uZora

/// B1a (plan D-L6) — streamable-HTTP tolerance on `POST /mcp` (spec-conformance
/// only, NO auth). Covers:
/// - a normal JSON-RPC POST answers `application/json`;
/// - a non-POST (GET) to `/mcp` returns 405 with `Allow: POST`;
/// - an `Mcp-Session-Id` request header is tolerated (accepted + echoed back).
/// Existing MCP behavior is untouched (see `MCPProtocolTests`).
@Suite("MCP streamable-HTTP tolerance on POST /mcp")
struct MCPStreamableHTTPTests {

    private func makeServer() -> MCPServer {
        MCPServer(tools: MCPTools(rest: RESTHandlers(state: StateStore()), httpBaseURL: "http://127.0.0.1:0"))
    }

    private func header(_ resp: HTTPResponse, _ name: String) -> String? {
        resp.headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    private func request(method: String, headers: [String: String] = [:], body: Data = Data()) -> HTTPRequest {
        // HTTPRequest.parse lowercases header keys; mirror that here.
        var lowered: [String: String] = [:]
        for (k, v) in headers { lowered[k.lowercased()] = v }
        return HTTPRequest(method: method, path: "/mcp", query: [:], headers: lowered, body: body)
    }

    private let initialize = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)

    // MARK: - Unit-level (deterministic, no sockets)

    @Test func post_returnsApplicationJSON() async {
        let mcp = makeServer()
        let resp = await mcp.handle(request(
            method: "POST",
            headers: ["Accept": "application/json, text/event-stream"],
            body: initialize
        ))
        #expect(resp.status == 200)
        #expect(header(resp, "Content-Type")?.contains("application/json") == true)
    }

    @Test func get_returns405WithAllowHeader() async {
        let mcp = makeServer()
        let resp = await mcp.handle(request(method: "GET"))
        #expect(resp.status == 405)
        #expect(header(resp, "Allow") == "POST")
    }

    @Test func sessionID_isEchoedBack() async {
        let mcp = makeServer()
        let resp = await mcp.handle(request(
            method: "POST",
            headers: ["Mcp-Session-Id": "sess-abc-123"],
            body: initialize
        ))
        #expect(resp.status == 200)
        #expect(header(resp, "Mcp-Session-Id") == "sess-abc-123")
    }

    @Test func noSessionID_noEchoHeader() async {
        let mcp = makeServer()
        let resp = await mcp.handle(request(method: "POST", body: initialize))
        #expect(header(resp, "Mcp-Session-Id") == nil)
    }

    // MARK: - Loopback through the HTTP server (as wired by ChannelHost)

    @Test func loopback_getMcp_is405() async throws {
        let mcp = makeServer()
        let server = HTTPServer(port: 0)
        await server.register(method: "POST", path: "/mcp") { req in await mcp.handle(req) }
        await server.register(method: "GET", path: "/mcp") { req in await mcp.handle(req) }
        try await server.start()
        let port = await server.boundPort
        defer { Task { await server.stop() } }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "GET"
        let (_, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        #expect(http?.statusCode == 405)
        #expect(http?.value(forHTTPHeaderField: "Allow") == "POST")
        await server.stop()
    }

    @Test func loopback_postMcp_echoesSessionAndReturnsJSON() async throws {
        let mcp = makeServer()
        let server = HTTPServer(port: 0)
        await server.register(method: "POST", path: "/mcp") { req in await mcp.handle(req) }
        try await server.start()
        let port = await server.boundPort
        defer { Task { await server.stop() } }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("sess-xyz", forHTTPHeaderField: "Mcp-Session-Id")
        req.httpBody = initialize
        let (_, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        #expect(http?.statusCode == 200)
        #expect(http?.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true)
        #expect(http?.value(forHTTPHeaderField: "Mcp-Session-Id") == "sess-xyz")
        await server.stop()
    }
}
