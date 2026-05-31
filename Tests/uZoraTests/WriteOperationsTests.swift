import Testing
import Foundation
@testable import uZora

/// Phase 7 write operations: alert acknowledgement + probe reconfiguration,
/// across StateStore, the REST handlers, the `allow_writes` gate, and MCP
/// dispatch. Mirrors the read-side test style (in-process StateStore +
/// real ConfigLoader against an isolated temp file; HTTP bound on port 0 for
/// the MCP-dispatch checks).
@Suite("Write operations — ack + reconfigure")
struct WriteOperationsTests {

    // MARK: - Fixtures

    private func alert(_ probe: String, _ key: String, severity: Severity = .warn) -> Alert {
        Alert(
            probe: probe, key: key, severity: severity,
            message: "m", details: nil,
            firstSeen: Date(), lastUpdated: Date()
        )
    }

    /// Fresh isolated config path per test.
    private func tempConfigURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-write-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.toml")
    }

    // ========================================================================
    // MARK: - StateStore ack semantics
    // ========================================================================

    @Test func ack_hidesAlertFromActiveSet() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))
        #expect(await store.activeAlerts().count == 1)

        let ok = await store.acknowledge("disk:/")
        #expect(ok)
        // Hidden from both the unfiltered + severity-filtered views.
        #expect(await store.activeAlerts().isEmpty)
        #expect(await store.activeAlerts(minSeverity: .info).isEmpty)
        // But counted as acknowledged.
        #expect(await store.acknowledgedCount() == 1)
    }

    @Test func ack_unknownID_returnsFalse() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))
        let ok = await store.acknowledge("cpu_temp:package") // not firing
        #expect(!ok)
        #expect(await store.acknowledgedCount() == 0)
        // The real alert is untouched.
        #expect(await store.activeAlerts().count == 1)
    }

    @Test func ack_thenEscalation_reSurfaces() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/", severity: .warn)))
        #expect(await store.acknowledge("disk:/"))
        #expect(await store.activeAlerts().isEmpty)

        // Escalation must re-surface the acked alert (ack cleared on escalate).
        await store.ingest(.escalated(alert("disk", "/", severity: .critical), previousSeverity: .warn))
        let active = await store.activeAlerts()
        #expect(active.count == 1)
        #expect(active.first?.severity == .critical)
        #expect(await store.acknowledgedCount() == 0)
    }

    @Test func ack_thenClear_dropsAck() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))
        #expect(await store.acknowledge("disk:/"))
        #expect(await store.acknowledgedCount() == 1)

        // Clear retires the alert AND drops the ack.
        await store.ingest(.cleared("disk:/"))
        #expect(await store.activeAlerts().isEmpty)
        #expect(await store.acknowledgedCount() == 0)

        // Re-appearance is a fresh, un-acked alert (ack did not linger).
        await store.ingest(.appeared(alert("disk", "/")))
        #expect(await store.activeAlerts().count == 1)
    }

    @Test func ack_thenSameSeverityReappear_isFreshUnacked() async {
        // A clear→appear cycle (not an escalate) must also yield an un-acked
        // alert. The clear path already dropped the ack; the new appeared
        // arrives clean.
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/", severity: .warn)))
        #expect(await store.acknowledge("disk:/"))
        await store.ingest(.cleared("disk:/"))
        await store.ingest(.appeared(alert("disk", "/", severity: .warn)))
        #expect(await store.activeAlerts().count == 1)
        #expect(await store.acknowledgedCount() == 0)
    }

    @Test func ack_onlyHidesTheAckedID() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))
        await store.ingest(.appeared(alert("cpu_temp", "package", severity: .critical)))
        #expect(await store.acknowledge("disk:/"))
        let active = await store.activeAlerts()
        #expect(active.count == 1)
        #expect(active.first?.id == "cpu_temp:package")
    }

    // ========================================================================
    // MARK: - REST ack handler + status surfacing
    // ========================================================================

    @Test func rest_ack_success() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))
        let rest = RESTHandlers(state: store)
        let resp = await rest.acknowledgeAlert(id: "disk:/")
        #expect(resp.status == 200)
        let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        #expect(json?["acknowledged"] as? Bool == true)
        #expect(json?["id"] as? String == "disk:/")
        #expect(await store.activeAlerts().isEmpty)
    }

    @Test func rest_ack_unknownID_404() async {
        let store = StateStore()
        let rest = RESTHandlers(state: store)
        let resp = await rest.acknowledgeAlert(id: "disk:/")
        #expect(resp.status == 404)
        let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        #expect((json?["error"] as? String)?.isEmpty == false)
    }

    @Test func rest_ack_missingID_400() async {
        let store = StateStore()
        let rest = RESTHandlers(state: store)
        let resp = await rest.acknowledgeAlert(id: nil)
        #expect(resp.status == 400)
    }

    @Test func rest_status_surfacesAckCountAndWritesFlag() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))
        _ = await store.acknowledge("disk:/")
        let rest = RESTHandlers(state: store, allowWrites: true)
        let resp = await rest.status()
        let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        #expect(json?["acknowledged_alerts_count"] as? Int == 1)
        #expect(json?["active_alerts_count"] as? Int == 0)
        #expect(json?["writes_enabled"] as? Bool == true)
    }

    // ========================================================================
    // MARK: - REST reconfigure handler (real ConfigLoader)
    // ========================================================================

    @Test func rest_reconfigure_disableDisk_persists() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let store = StateStore()
        let rest = RESTHandlers(state: store, configLoader: loader)

        let resp = await rest.reconfigureProbe(name: "disk", patch: .init(enabled: false))
        #expect(resp.status == 200)
        let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        #expect(json?["updated"] as? Bool == true)
        #expect(json?["probe"] as? String == "disk")

        // In-memory current is updated…
        #expect(await loader.current.probes.disk.enabled == false)
        // …and persisted to disk (reload from file confirms).
        let reloaded = try await loader.reload()
        #expect(reloaded.probes.disk.enabled == false)

        // The on-disk TOML literally carries disk.enabled = false.
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("[probes.disk]"))
        let parsed = try UZoraConfig.fromTOML(text)
        #expect(parsed.probes.disk.enabled == false)
    }

    @Test func rest_reconfigure_unknownProbe_400() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader)
        let resp = await rest.reconfigureProbe(name: "bogus", patch: .init(enabled: false))
        #expect(resp.status == 400)
    }

    @Test func rest_reconfigure_missingProbe_400() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader)
        let resp = await rest.reconfigureProbe(name: nil, patch: .init(enabled: false))
        #expect(resp.status == 400)
    }

    @Test func rest_reconfigure_noLoader_500() async {
        // No ConfigLoader wired → reconfigure can't persist.
        let rest = RESTHandlers(state: StateStore(), configLoader: nil)
        let resp = await rest.reconfigureProbe(name: "disk", patch: .init(enabled: false))
        #expect(resp.status == 500)
    }

    @Test func rest_reconfigure_diskThreshold_percentStoredVerbatim() async throws {
        // The handler stores the threshold in config units (percent for disk);
        // the percent→fraction conversion happens later in ProbeRegistry. So
        // the written config carries warn_threshold = 20 (percent), and a
        // ProbeRegistry built from it yields warnFreeFraction 0.20.
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader)

        let resp = await rest.reconfigureProbe(
            name: "disk",
            patch: .init(warnThreshold: 20, criticalThreshold: 8)
        )
        #expect(resp.status == 200)

        let reloaded = try await loader.reload()
        #expect(reloaded.probes.disk.warnThreshold == 20)
        #expect(reloaded.probes.disk.criticalThreshold == 8)

        // End-to-end mapping: percent in config → fraction in the probe.
        let registry = await ProbeRegistry.defaultPopulated(config: reloaded)
        let probe = await registry.registeredProbe(named: "disk") as? DiskFreeProbe
        let t = try #require(probe?.configuredThresholds)
        #expect(abs(t.warnFreeFraction - 0.20) < 1e-9)
        #expect(abs(t.criticalFreeFraction - 0.08) < 1e-9)
    }

    @Test func rest_reconfigure_fanThreshold_rejectedWithWarning() async throws {
        // fan IGNORES thresholds: enabled/poll applied, threshold NOT persisted,
        // a warning is returned.
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader)

        let resp = await rest.reconfigureProbe(
            name: "fan",
            patch: .init(enabled: true, warnThreshold: 999, pollIntervalSec: 42)
        )
        #expect(resp.status == 200)
        let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        let warnings = json?["warnings"] as? [String]
        #expect((warnings?.count ?? 0) >= 1)

        let reloaded = try await loader.reload()
        // Threshold dropped…
        #expect(reloaded.probes.fan.warnThreshold == nil)
        // …poll + enabled applied.
        #expect(reloaded.probes.fan.pollIntervalSec == 42)
        #expect(reloaded.probes.fan.enabled == true)
    }

    @Test func rest_reconfigure_batterySmartThermal_thresholdsRejected() async throws {
        // The other three threshold-ignoring probes behave the same.
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader)

        for probe in ["battery", "smart", "thermal"] {
            let resp = await rest.reconfigureProbe(
                name: probe,
                patch: .init(criticalThreshold: 5, pollIntervalSec: 7)
            )
            #expect(resp.status == 200)
            let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
            #expect(((json?["warnings"] as? [String])?.count ?? 0) >= 1)
        }
        let reloaded = try await loader.reload()
        #expect(reloaded.probes.battery.criticalThreshold == nil)
        #expect(reloaded.probes.smart.criticalThreshold == nil)
        #expect(reloaded.probes.thermal.criticalThreshold == nil)
        #expect(reloaded.probes.battery.pollIntervalSec == 7)
    }

    @Test func rest_reconfigure_onlyProvidedFieldsChange() async throws {
        // Sending only poll_interval_sec must not flip enabled or thresholds.
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader)

        // Pre-set a warn threshold on cpu_temp.
        _ = await rest.reconfigureProbe(name: "cpu_temp", patch: .init(warnThreshold: 70))
        // Now change only the poll interval.
        let resp = await rest.reconfigureProbe(name: "cpu_temp", patch: .init(pollIntervalSec: 12))
        #expect(resp.status == 200)

        let reloaded = try await loader.reload()
        #expect(reloaded.probes.cpuTemp.warnThreshold == 70) // preserved
        #expect(reloaded.probes.cpuTemp.pollIntervalSec == 12) // applied
        #expect(reloaded.probes.cpuTemp.enabled == true)       // default preserved
    }

    // ========================================================================
    // MARK: - allow_writes gate
    // ========================================================================

    @Test func allowWritesFalse_ack_403() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))
        let rest = RESTHandlers(state: store, allowWrites: false)
        let resp = await rest.acknowledgeAlert(id: "disk:/")
        #expect(resp.status == 403)
        // The alert was NOT acked (gate short-circuits before touching state).
        #expect(await store.activeAlerts().count == 1)
        let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        #expect((json?["error"] as? String)?.contains("allow_writes") == true)
    }

    @Test func allowWritesFalse_reconfigure_403() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader, allowWrites: false)
        let resp = await rest.reconfigureProbe(name: "disk", patch: .init(enabled: false))
        #expect(resp.status == 403)
        // Config untouched on disk.
        let reloaded = try await loader.reload()
        #expect(reloaded.probes.disk.enabled == true)
    }

    // ========================================================================
    // MARK: - MCP dispatch (write tools reach the handlers)
    // ========================================================================

    private func bootMCP(
        state: StateStore,
        configLoader: ConfigLoader? = nil,
        allowWrites: Bool = true
    ) async throws -> (port: UInt16, server: HTTPServer) {
        let server = HTTPServer(port: 0)
        let rest = RESTHandlers(
            state: state, metricsStore: nil,
            configLoader: configLoader, allowWrites: allowWrites
        )
        let mcp = MCPServer(tools: MCPTools(rest: rest, httpBaseURL: "http://127.0.0.1:0"))
        await server.register(method: "POST", path: "/mcp") { req in await mcp.handle(req) }
        try await server.start()
        return (await server.boundPort, server)
    }

    private func postMCP(_ port: UInt16, _ body: String) async throws -> [String: Any]? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @Test func mcp_ackAlert_reachesHandler() async throws {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))
        let (port, server) = try await bootMCP(state: store)
        defer { Task { await server.stop() } }
        let json = try await postMCP(port, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"uzora_ack_alert","arguments":{"id":"disk:/"}}}"#)
        let result = json?["result"] as? [String: Any]
        #expect(result?["isError"] as? Bool == false)
        let structured = result?["structuredContent"] as? [String: Any]
        #expect(structured?["acknowledged"] as? Bool == true)
        #expect(await store.activeAlerts().isEmpty)
        await server.stop()
    }

    @Test func mcp_ackAlert_unknownID_isErrorTrue() async throws {
        let store = StateStore()
        let (port, server) = try await bootMCP(state: store)
        defer { Task { await server.stop() } }
        let json = try await postMCP(port, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"uzora_ack_alert","arguments":{"id":"x:y"}}}"#)
        let result = json?["result"] as? [String: Any]
        #expect(result?["isError"] as? Bool == true) // 404 → isError
        await server.stop()
    }

    @Test func mcp_setProbeConfig_reachesHandler() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let (port, server) = try await bootMCP(state: StateStore(), configLoader: loader)
        defer { Task { await server.stop() } }
        let json = try await postMCP(port, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"uzora_set_probe_config","arguments":{"probe":"disk","enabled":false,"warn_threshold":25}}}"#)
        let result = json?["result"] as? [String: Any]
        #expect(result?["isError"] as? Bool == false)
        let structured = result?["structuredContent"] as? [String: Any]
        #expect(structured?["updated"] as? Bool == true)
        let reloaded = try await loader.reload()
        #expect(reloaded.probes.disk.enabled == false)
        #expect(reloaded.probes.disk.warnThreshold == 25)
        await server.stop()
    }

    @Test func mcp_setProbeConfig_unknownProbe_isErrorTrue() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let (port, server) = try await bootMCP(state: StateStore(), configLoader: loader)
        defer { Task { await server.stop() } }
        let json = try await postMCP(port, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"uzora_set_probe_config","arguments":{"probe":"nope","enabled":false}}}"#)
        let result = json?["result"] as? [String: Any]
        #expect(result?["isError"] as? Bool == true) // 400 → isError
        await server.stop()
    }

    @Test func mcp_writeTools_403WhenWritesDisabled() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))
        let (port, server) = try await bootMCP(state: store, configLoader: loader, allowWrites: false)
        defer { Task { await server.stop() } }

        let ack = try await postMCP(port, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"uzora_ack_alert","arguments":{"id":"disk:/"}}}"#)
        #expect((ack?["result"] as? [String: Any])?["isError"] as? Bool == true)

        let cfg = try await postMCP(port, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"uzora_set_probe_config","arguments":{"probe":"disk","enabled":false}}}"#)
        #expect((cfg?["result"] as? [String: Any])?["isError"] as? Bool == true)
        await server.stop()
    }

    @Test func mcp_toolsList_listsWriteToolsEvenWhenDisabled() async throws {
        let store = StateStore()
        let (port, server) = try await bootMCP(state: store, allowWrites: false)
        defer { Task { await server.stop() } }
        let json = try await postMCP(port, #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#)
        let tools = (json?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        let names = Set(tools?.compactMap { $0["name"] as? String } ?? [])
        // Write tools still advertised when disabled (clearer 403 than unknown).
        #expect(names.contains("uzora_ack_alert"))
        #expect(names.contains("uzora_set_probe_config"))
        // 6 read tools (incl. Q10 uzora_list_actions) + 2 write tools = 8.
        #expect(tools?.count == 8)
        // Their description carries the "disabled" hint.
        let ackDesc = tools?.first { $0["name"] as? String == "uzora_ack_alert" }?["description"] as? String
        #expect(ackDesc?.contains("DISABLED") == true)
        await server.stop()
    }

    // ========================================================================
    // MARK: - ChannelHost integration (full HTTP path through dispatch)
    // ========================================================================

    @Test func channelHost_restWriteEndpoints_wired() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-host-write-\(UUID().uuidString)", isDirectory: true)
        let cfgURL = tempConfigURL()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: cfgURL.deletingLastPathComponent())
        }
        let bus = EventBus()
        let state = StateStore()
        let jsonl = try JSONLEventSink(baseDir: dir, retentionDays: 30)
        let loader = try ConfigLoader(configURL: cfgURL)
        let host = ChannelHost(
            port: 0, state: state, jsonl: jsonl, eventBus: bus,
            configLoader: loader, allowWrites: true
        )
        try await host.start()
        let port = await host.boundPort()
        defer { Task { await host.stop() } }

        // Seed a firing alert through the bus.
        await bus.emit(.appeared(alert("disk", "/")))
        try await Task.sleep(for: .milliseconds(150))

        // POST /alerts/ack over real HTTP.
        var ackReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/alerts/ack")!)
        ackReq.httpMethod = "POST"
        ackReq.httpBody = Data(#"{"id":"disk:/"}"#.utf8)
        let (ackData, ackResp) = try await URLSession.shared.data(for: ackReq)
        #expect((ackResp as? HTTPURLResponse)?.statusCode == 200)
        let ackJSON = try? JSONSerialization.jsonObject(with: ackData) as? [String: Any]
        #expect(ackJSON?["acknowledged"] as? Bool == true)

        // POST /config/probe over real HTTP.
        var cfgReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/config/probe")!)
        cfgReq.httpMethod = "POST"
        cfgReq.httpBody = Data(#"{"probe":"disk","enabled":false}"#.utf8)
        let (cfgData, cfgResp) = try await URLSession.shared.data(for: cfgReq)
        #expect((cfgResp as? HTTPURLResponse)?.statusCode == 200)
        let cfgJSON = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any]
        #expect(cfgJSON?["updated"] as? Bool == true)
        #expect(await loader.current.probes.disk.enabled == false)

        await host.stop()
    }
}
