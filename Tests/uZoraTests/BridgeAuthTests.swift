import Testing
import Foundation
@testable import uZora

/// Phase B1b — write-tier security hardening: bearer token + Origin/Host
/// validation on ALL mutations (REST + MCP). Reads stay OPEN on loopback.
///
/// Split into four groups:
///  1. `originHostAllowed` pure cases (the DNS-rebinding cut).
///  2. `BridgeAuth` token infra (secure-random 64-hex, 0600 sidecar, persist +
///     reload + regenerate, validate, bearer parsing).
///  3. REST write gate — 401 (missing/wrong bearer) vs 403 (cross-origin /
///     non-loopback host) vs 200 (valid) — and reads never gated.
///  4. MCP write gate — same, through `MCPTools.invoke` + the full
///     `MCPServer.handle` HTTP path.
@Suite("B1b — bridge write auth (bearer + Origin/Host)")
struct BridgeAuthTests {

    // MARK: - Fixtures

    private func alert(_ probe: String, _ key: String, severity: Severity = .warn) -> Alert {
        Alert(probe: probe, key: key, severity: severity, message: "m", details: nil,
              firstSeen: Date(), lastUpdated: Date())
    }

    private func tempConfigURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-authcfg-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.toml")
    }

    private func tempTokenURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-token-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("bridge-token", isDirectory: false)
    }

    /// A RESTHandlers with a known bearer wired + a firing `disk:/` alert.
    private func authedRest(token: String, allowWrites: Bool = true) async -> RESTHandlers {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))
        return RESTHandlers(state: store, allowWrites: allowWrites, bridgeAuth: BridgeAuth(token: token))
    }

    // ========================================================================
    // MARK: - 1. originHostAllowed (pure)
    // ========================================================================

    @Test func origin_absentOriginAndHost_allowed() {
        #expect(RESTHandlers.originHostAllowed(host: nil, origin: nil))
        #expect(RESTHandlers.originHostAllowed(host: "", origin: ""))
    }

    @Test func origin_loopbackHostVariants_allowed() {
        #expect(RESTHandlers.originHostAllowed(host: "127.0.0.1", origin: nil))
        #expect(RESTHandlers.originHostAllowed(host: "127.0.0.1:39842", origin: nil))
        #expect(RESTHandlers.originHostAllowed(host: "localhost", origin: nil))
        #expect(RESTHandlers.originHostAllowed(host: "localhost:8080", origin: nil))
        #expect(RESTHandlers.originHostAllowed(host: "[::1]", origin: nil))
        #expect(RESTHandlers.originHostAllowed(host: "[::1]:39842", origin: nil))
    }

    @Test func origin_nonLoopbackHost_rejected() {
        #expect(!RESTHandlers.originHostAllowed(host: "evil.com", origin: nil))
        #expect(!RESTHandlers.originHostAllowed(host: "evil.com:39842", origin: nil))
        #expect(!RESTHandlers.originHostAllowed(host: "192.168.1.5:39842", origin: nil))
        #expect(!RESTHandlers.originHostAllowed(host: "10.0.0.1", origin: nil))
    }

    @Test func origin_loopbackOrigin_allowed_evil_rejected() {
        // Absent origin ⇒ allowed even with a loopback host.
        #expect(RESTHandlers.originHostAllowed(host: "127.0.0.1:39842", origin: nil))
        // Present loopback origin ⇒ allowed.
        #expect(RESTHandlers.originHostAllowed(host: "127.0.0.1:39842", origin: "http://127.0.0.1:39842"))
        #expect(RESTHandlers.originHostAllowed(host: nil, origin: "http://localhost:3000"))
        #expect(RESTHandlers.originHostAllowed(host: nil, origin: "http://[::1]:39842"))
        // Present cross-origin ⇒ rejected (the DNS-rebinding cut).
        #expect(!RESTHandlers.originHostAllowed(host: "127.0.0.1:39842", origin: "https://evil.com"))
        #expect(!RESTHandlers.originHostAllowed(host: nil, origin: "http://attacker.example:39842"))
        // Opaque origin (`null`) ⇒ rejected.
        #expect(!RESTHandlers.originHostAllowed(host: nil, origin: "null"))
    }

    // ========================================================================
    // MARK: - 2. BridgeAuth token infra
    // ========================================================================

    @Test func token_generated_isSecureHex() {
        let t = BridgeAuth.generateToken()
        #expect(t.count == 64)
        #expect(t.allSatisfy { $0.isHexDigit })
        // Two independent draws differ (astronomically) — sanity that it isn't a constant.
        #expect(t != BridgeAuth.generateToken())
    }

    @Test func loadOrCreate_persists_0600_andIsStable() throws {
        let url = tempTokenURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let a = BridgeAuth.loadOrCreate(at: url)
        #expect(a.token.count == 64)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Sidecar file is 0600.
        let perms = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(perms.map { $0 & 0o777 } == 0o600)

        // A second load returns the SAME persisted token (not a fresh one).
        let b = BridgeAuth.loadOrCreate(at: url)
        #expect(b.token == a.token)

        // The on-disk bytes match the token.
        let onDisk = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(onDisk == a.token)
    }

    @Test func loadOrCreate_isSeparateFileFromConfig() {
        // The token path is NOT the config path — a signing/auth secret must
        // not live in the world-readable config.toml.
        let tokenURL = tempTokenURL()
        defer { try? FileManager.default.removeItem(at: tokenURL.deletingLastPathComponent()) }
        let auth = BridgeAuth.loadOrCreate(at: tokenURL)
        #expect(tokenURL.lastPathComponent == "bridge-token")
        #expect(!tokenURL.path.hasSuffix("config.toml"))
        #expect(!auth.token.isEmpty)
    }

    @Test func regenerate_mintsDifferentToken_persisted() throws {
        let url = tempTokenURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let a = BridgeAuth.loadOrCreate(at: url)
        let b = BridgeAuth.regenerate(at: url)
        #expect(b.token != a.token)
        // The NEW token is now the persisted one.
        let reloaded = BridgeAuth.loadOrCreate(at: url)
        #expect(reloaded.token == b.token)
    }

    @Test func validate_onlyExactToken() {
        let auth = BridgeAuth(token: "abc123")
        #expect(auth.current() == "abc123")
        #expect(auth.validate("abc123"))
        #expect(!auth.validate("abc124"))
        #expect(!auth.validate("abc1234"))   // different length
        #expect(!auth.validate(""))
        #expect(!auth.validate(nil))
    }

    @Test func bearerToken_parsing() {
        #expect(BridgeAuth.bearerToken(from: "Bearer abc123") == "abc123")
        #expect(BridgeAuth.bearerToken(from: "bearer abc123") == "abc123")   // case-insensitive scheme
        #expect(BridgeAuth.bearerToken(from: "  Bearer   abc123  ") == "abc123")
        #expect(BridgeAuth.bearerToken(from: "Basic abc123") == nil)
        #expect(BridgeAuth.bearerToken(from: "Bearer ") == nil)
        #expect(BridgeAuth.bearerToken(from: "abc123") == nil)
        #expect(BridgeAuth.bearerToken(from: nil) == nil)
    }

    // ========================================================================
    // MARK: - 3. REST write gate (401 vs 403 vs 200; reads never gated)
    // ========================================================================

    @Test func rest_ack_noBearer_401() async {
        let rest = await authedRest(token: "T0KEN")
        // No Authorization header ⇒ 401 (auth wired, writes enabled).
        let resp = await rest.acknowledgeAlert(id: "disk:/")
        #expect(resp.status == 401)
        // The alert was NOT acked — the gate short-circuits before touching state.
        #expect(await rest.state.activeAlerts().count == 1)
    }

    @Test func rest_ack_wrongBearer_401() async {
        let rest = await authedRest(token: "T0KEN")
        let resp = await rest.acknowledgeAlert(id: "disk:/", auth: WriteAuthContext(authorization: "Bearer nope"))
        #expect(resp.status == 401)
        #expect(await rest.state.activeAlerts().count == 1)
    }

    @Test func rest_ack_validBearer_200() async {
        let rest = await authedRest(token: "T0KEN")
        let resp = await rest.acknowledgeAlert(id: "disk:/", auth: WriteAuthContext(authorization: "Bearer T0KEN"))
        #expect(resp.status == 200)
        #expect(await rest.state.activeAlerts().isEmpty)
    }

    @Test func rest_ack_validBearer_crossOrigin_403() async {
        let rest = await authedRest(token: "T0KEN")
        // Valid bearer but a cross-origin request ⇒ 403 (origin/host checked first).
        let resp = await rest.acknowledgeAlert(
            id: "disk:/",
            auth: WriteAuthContext(authorization: "Bearer T0KEN", origin: "https://evil.com", host: "127.0.0.1:39842")
        )
        #expect(resp.status == 403)
        #expect(await rest.state.activeAlerts().count == 1)
    }

    @Test func rest_ack_validBearer_nonLoopbackHost_403() async {
        let rest = await authedRest(token: "T0KEN")
        let resp = await rest.acknowledgeAlert(
            id: "disk:/",
            auth: WriteAuthContext(authorization: "Bearer T0KEN", host: "evil.com")
        )
        #expect(resp.status == 403)
        #expect(await rest.state.activeAlerts().count == 1)
    }

    @Test func rest_reconfigure_noBearer_401_thenValid_200() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader, bridgeAuth: BridgeAuth(token: "T0KEN"))

        // Missing bearer ⇒ 401, config untouched.
        let denied = await rest.reconfigureProbe(name: "disk", patch: .init(enabled: false))
        #expect(denied.status == 401)
        #expect(await loader.current.probes.disk.enabled == true)

        // Valid bearer ⇒ 200, persisted.
        let ok = await rest.reconfigureProbe(
            name: "disk", patch: .init(enabled: false),
            auth: WriteAuthContext(authorization: "Bearer T0KEN")
        )
        #expect(ok.status == 200)
        #expect(await loader.current.probes.disk.enabled == false)
    }

    @Test func rest_allowWritesFalse_validBearer_stays403() async {
        // The master switch is independent of the token: allow_writes=false ⇒
        // 403 even with a valid bearer.
        let rest = await authedRest(token: "T0KEN", allowWrites: false)
        let resp = await rest.acknowledgeAlert(id: "disk:/", auth: WriteAuthContext(authorization: "Bearer T0KEN"))
        #expect(resp.status == 403)
        let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        #expect((json?["error"] as? String)?.contains("allow_writes") == true)
    }

    @Test func rest_reads_neverGated_even_withAuthWired() async {
        // Reads answer 200 with NO bearer and NO headers, auth wired or not.
        let rest = await authedRest(token: "T0KEN")
        let statusResp = await rest.dispatch(HTTPRequest(method: "GET", path: "/status", query: [:], headers: [:], body: Data()))
        #expect(statusResp.status == 200)
        let alertsResp = await rest.dispatch(HTTPRequest(method: "GET", path: "/alerts", query: [:], headers: [:], body: Data()))
        #expect(alertsResp.status == 200)
        // A read even from a cross-origin browser tab is fine (reads are open).
        let evilRead = await rest.dispatch(HTTPRequest(
            method: "GET", path: "/status", query: [:],
            headers: ["origin": "https://evil.com", "host": "evil.com"], body: Data()
        ))
        #expect(evilRead.status == 200)
    }

    @Test func rest_dispatch_threadsHeaders_forWrites() async {
        // The full REST dispatch path lifts Authorization/Origin/Host off the
        // request headers. No header ⇒ 401; correct bearer ⇒ 200.
        let rest = await authedRest(token: "T0KEN")
        let noAuth = await rest.dispatch(HTTPRequest(
            method: "POST", path: "/alerts/ack", query: [:], headers: [:], body: Data(#"{"id":"disk:/"}"#.utf8)
        ))
        #expect(noAuth.status == 401)

        let withAuth = await rest.dispatch(HTTPRequest(
            method: "POST", path: "/alerts/ack", query: [:],
            headers: ["authorization": "Bearer T0KEN", "host": "127.0.0.1:39842"],
            body: Data(#"{"id":"disk:/"}"#.utf8)
        ))
        #expect(withAuth.status == 200)
    }

    // ========================================================================
    // MARK: - 4. MCP write gate (invoke + full handle path)
    // ========================================================================

    @Test func mcp_invoke_ack_noBearer_isError_withBearer_ok() async throws {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))
        let rest = RESTHandlers(state: store, bridgeAuth: BridgeAuth(token: "T0KEN"))
        let tools = MCPTools(rest: rest, httpBaseURL: "http://127.0.0.1:0")
        let args = JSONValue.object(["id": .string("disk:/")])

        // No auth context ⇒ 401 wrapped as isError, alert untouched.
        let denied = try await tools.invoke(name: "uzora_ack_alert", arguments: args)
        #expect(Self.isError(denied) == true)
        #expect(await store.activeAlerts().count == 1)

        // Correct bearer ⇒ succeeds.
        let ok = try await tools.invoke(
            name: "uzora_ack_alert", arguments: args,
            auth: WriteAuthContext(authorization: "Bearer T0KEN")
        )
        #expect(Self.isError(ok) == false)
        #expect(await store.activeAlerts().isEmpty)
    }

    @Test func mcp_handle_httpPath_401_then200_then403() async throws {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))
        let rest = RESTHandlers(state: store, bridgeAuth: BridgeAuth(token: "T0KEN"))
        let mcp = MCPServer(tools: MCPTools(rest: rest, httpBaseURL: "http://127.0.0.1:0"))
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"uzora_ack_alert","arguments":{"id":"disk:/"}}}"#.utf8)

        // No Authorization header ⇒ isError (401 wrapped).
        let noAuth = await mcp.handle(HTTPRequest(method: "POST", path: "/mcp", query: [:], headers: ["host": "127.0.0.1:39842"], body: body))
        #expect(Self.mcpResultIsError(noAuth) == true)
        #expect(await store.activeAlerts().count == 1)

        // Cross-origin (valid bearer, evil origin) ⇒ isError (403 wrapped).
        let evil = await mcp.handle(HTTPRequest(
            method: "POST", path: "/mcp", query: [:],
            headers: ["authorization": "Bearer T0KEN", "origin": "https://evil.com", "host": "127.0.0.1:39842"],
            body: body
        ))
        #expect(Self.mcpResultIsError(evil) == true)
        #expect(await store.activeAlerts().count == 1)

        // Correct bearer, loopback ⇒ success.
        let ok = await mcp.handle(HTTPRequest(
            method: "POST", path: "/mcp", query: [:],
            headers: ["authorization": "Bearer T0KEN", "host": "127.0.0.1:39842"],
            body: body
        ))
        #expect(Self.mcpResultIsError(ok) == false)
        #expect(await store.activeAlerts().isEmpty)
    }

    @Test func mcp_reads_notGated() async throws {
        // A read tool works with no auth even when a BridgeAuth is wired.
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))
        let rest = RESTHandlers(state: store, bridgeAuth: BridgeAuth(token: "T0KEN"))
        let tools = MCPTools(rest: rest, httpBaseURL: "http://127.0.0.1:0")
        let result = try await tools.invoke(name: "uzora_list_alerts", arguments: .object([:]))
        #expect(Self.isError(result) == false)
    }

    // MARK: - helpers

    /// `isError` from an MCPTools tool-result JSONValue.
    private static func isError(_ v: JSONValue) -> Bool? {
        guard case .object(let o) = v, case .bool(let b)? = o["isError"] else { return nil }
        return b
    }

    /// `.result.isError` from a raw MCP JSON-RPC HTTP response body.
    private static func mcpResultIsError(_ resp: HTTPResponse) -> Bool? {
        guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let isError = result["isError"] as? Bool else { return nil }
        return isError
    }
}
