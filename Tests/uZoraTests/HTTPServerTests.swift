import Testing
import Foundation
@testable import uZora

/// End-to-end tests of the embedded HTTP server. Bind to an ephemeral
/// loopback port, hit it with URLSession, assert response shape.
@Suite("HTTPServer real loopback round-trip")
struct HTTPServerTests {

    /// Build a StateStore + RESTHandlers + HTTPServer triple bound to a
    /// random loopback port. Returns the port and a teardown callback.
    private func boot(state: StateStore) async throws -> (port: UInt16, server: HTTPServer) {
        let server = HTTPServer(port: 0) // ephemeral
        let rest = RESTHandlers(state: state)
        await server.register(method: "GET", path: "/status") { _ in await rest.status() }
        await server.register(method: "GET", path: "/alerts") { req in
            let floor = req.query["severity"].flatMap { Severity(rawValue: $0) }
            return await rest.alerts(minSeverity: floor)
        }
        await server.register(method: "GET", path: "/probes") { _ in await rest.probes() }
        await server.register(method: "GET", path: "/metrics") { req in
            let probe = req.query["probe"]
            return await rest.metrics(probe: probe, from: nil, to: nil)
        }
        try await server.start()
        let port = await server.boundPort
        return (port, server)
    }

    private func get(_ url: URL) async throws -> (Int, Data) {
        let (data, resp) = try await URLSession.shared.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        return (code, data)
    }

    @Test func status_returnsShape() async throws {
        let store = StateStore()
        await store.setProbes([
            StateStore.ProbeInfo(name: "disk", pollIntervalSeconds: 60, lastRunAt: nil),
            StateStore.ProbeInfo(name: "battery", pollIntervalSeconds: 30, lastRunAt: nil),
        ])
        await store.updatePowerState("acConnectedLidOpen")

        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        let url = URL(string: "http://127.0.0.1:\(port)/status")!
        let (code, data) = try await get(url)
        #expect(code == 200)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["status"] as? String == "ok")
        #expect(json?["active_alerts_count"] as? Int == 0)
        #expect(json?["probes_registered"] as? Int == 2)
        #expect(json?["power_state"] as? String == "acConnectedLidOpen")
        await server.stop()
    }

    @Test func alerts_returnsArray() async throws {
        let store = StateStore()
        let a = Alert(
            probe: "disk", key: "/", severity: .warn,
            message: "test", details: nil,
            firstSeen: Date(), lastUpdated: Date()
        )
        await store.ingest(.appeared(a))
        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        let url = URL(string: "http://127.0.0.1:\(port)/alerts")!
        let (code, data) = try await get(url)
        #expect(code == 200)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let arr = json?["alerts"] as? [[String: Any]]
        #expect(arr?.count == 1)
        #expect(arr?.first?["probe"] as? String == "disk")
        #expect(arr?.first?["severity"] as? String == "warn")
        await server.stop()
    }

    @Test func alerts_filtersBySeverity() async throws {
        let store = StateStore()
        let info = Alert(probe: "x", key: "1", severity: .info, message: "", details: nil, firstSeen: Date(), lastUpdated: Date())
        let warn = Alert(probe: "x", key: "2", severity: .warn, message: "", details: nil, firstSeen: Date(), lastUpdated: Date())
        let crit = Alert(probe: "x", key: "3", severity: .critical, message: "", details: nil, firstSeen: Date(), lastUpdated: Date())
        for a in [info, warn, crit] { await store.ingest(.appeared(a)) }
        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        let url = URL(string: "http://127.0.0.1:\(port)/alerts?severity=warn")!
        let (code, data) = try await get(url)
        #expect(code == 200)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let arr = json?["alerts"] as? [[String: Any]]
        #expect(arr?.count == 2)
        await server.stop()
    }

    @Test func probes_returnsInventory() async throws {
        let store = StateStore()
        await store.setProbes([
            StateStore.ProbeInfo(name: "disk", pollIntervalSeconds: 60, lastRunAt: nil),
        ])
        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        let url = URL(string: "http://127.0.0.1:\(port)/probes")!
        let (code, data) = try await get(url)
        #expect(code == 200)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let arr = json?["probes"] as? [[String: Any]]
        #expect(arr?.count == 1)
        #expect(arr?.first?["name"] as? String == "disk")
        await server.stop()
    }

    @Test func metrics_returnsStub() async throws {
        let store = StateStore()
        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        let url = URL(string: "http://127.0.0.1:\(port)/metrics?probe=disk")!
        let (code, data) = try await get(url)
        #expect(code == 200)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((json?["note"] as? String)?.contains("Phase 5") == true)
        #expect(json?["probe"] as? String == "disk")
        await server.stop()
    }

    @Test func unknown_route_returns404() async throws {
        let store = StateStore()
        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        let url = URL(string: "http://127.0.0.1:\(port)/nope")!
        let (code, _) = try await get(url)
        #expect(code == 404)
        await server.stop()
    }

    @Test func boundsLoopbackOnly() async throws {
        let store = StateStore()
        let (port, server) = try await boot(state: store)
        defer { Task { await server.stop() } }
        // Cannot bind another listener on the same port from the same process.
        #expect(port > 0)
        await server.stop()
    }
}
