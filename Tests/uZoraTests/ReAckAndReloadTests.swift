import Testing
import Foundation
@testable import uZora

/// Regression coverage for two contract bugs:
///
///  - P1 #5: `acknowledge()` returned `true` on a no-op re-ack of an
///    already-acknowledged (still-firing) alert, masquerading as a fresh ack.
///    The corrected contract distinguishes a fresh ack (`true` /
///    `.acknowledged`) from a no-op (`false` / `.alreadyAcknowledged`).
///  - P1 #6: `ConfigLoader.write()` both broadcast to observers AND tripped
///    the file-watcher → reload → a SECOND broadcast for byte-identical
///    content, so every in-app reconfigure fired the hot-reload chain twice.
///    The fix suppresses the self-write watcher echo: one write → exactly one
///    broadcast.
@Suite("Re-ack contract + single-fire reconfigure")
struct ReAckAndReloadTests {

    private func alert(_ probe: String, _ key: String, severity: Severity = .warn) -> Alert {
        Alert(probe: probe, key: key, severity: severity, message: "m", details: nil,
              firstSeen: Date(), lastUpdated: Date())
    }

    private func tempConfigURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-reack-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.toml")
    }

    // ========================================================================
    // MARK: - P1 #5: re-ack is a no-op, not a fresh ack
    // ========================================================================

    /// THE repro: ack once (fresh → true), ack the SAME still-firing alert
    /// again (no-op → false). Previously both returned true.
    @Test func reAck_returnsFalse_notTrue() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))

        let first = await store.acknowledge("disk:/")
        #expect(first == true) // fresh ack

        let second = await store.acknowledge("disk:/")
        #expect(second == false) // no-op re-ack — was the bug (returned true)

        // Still only counted once.
        #expect(await store.acknowledgedCount() == 1)
    }

    /// The typed result distinguishes all three cases.
    @Test func acknowledgeResult_distinguishesCases() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))

        #expect(await store.acknowledgeResult("disk:/") == .acknowledged)
        #expect(await store.acknowledgeResult("disk:/") == .alreadyAcknowledged)
        #expect(await store.acknowledgeResult("nope:nothing") == .notFound)
    }

    /// REST: a fresh ack is 200 acknowledged=true; a re-ack is 200
    /// acknowledged=false + already=true (the alert IS acked, so not 404).
    @Test func rest_reAck_200_acknowledgedFalse_alreadyTrue() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/")))
        let rest = RESTHandlers(state: store)

        let r1 = await rest.acknowledgeAlert(id: "disk:/")
        #expect(r1.status == 200)
        let j1 = try? JSONSerialization.jsonObject(with: r1.body) as? [String: Any]
        #expect(j1?["acknowledged"] as? Bool == true)
        #expect(j1?["already"] == nil) // omitted on fresh ack

        let r2 = await rest.acknowledgeAlert(id: "disk:/")
        #expect(r2.status == 200) // still 200 — it IS acked
        let j2 = try? JSONSerialization.jsonObject(with: r2.body) as? [String: Any]
        #expect(j2?["acknowledged"] as? Bool == false) // no-op
        #expect(j2?["already"] as? Bool == true)
    }

    /// MCP write path reflects the corrected contract (re-ack → not error, but
    /// acknowledged=false / already=true in structuredContent).
    @Test func mcp_reAck_notError_acknowledgedFalse() async throws {
        let store = StateStore()
        await store.ingest(.appeared(alert("synthetic", "e2e")))
        let rest = RESTHandlers(state: store)
        let mcp = MCPTools(rest: rest, httpBaseURL: "http://127.0.0.1:0")
        let args = JSONValue.object(["id": .string("synthetic:e2e")])

        _ = try await mcp.invoke(name: "uzora_ack_alert", arguments: args) // fresh
        let result = try await mcp.invoke(name: "uzora_ack_alert", arguments: args) // re-ack

        guard case .object(let obj) = result else { Issue.record("expected object"); return }
        #expect(obj["isError"] == .bool(false))
        guard case .object(let structured)? = obj["structuredContent"] else {
            Issue.record("expected structuredContent object"); return
        }
        #expect(structured["acknowledged"] == .bool(false))
        #expect(structured["already"] == .bool(true))
    }

    /// Re-ack after escalation behaves as a FRESH ack again (escalation
    /// cleared the prior ack). Guards the interaction with the ack-on-escalate
    /// reset.
    @Test func reAck_afterEscalation_isFreshAgain() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("disk", "/", severity: .warn)))
        #expect(await store.acknowledge("disk:/") == true)
        #expect(await store.acknowledge("disk:/") == false) // re-ack no-op

        // Escalation re-surfaces + clears the ack.
        await store.ingest(.escalated(alert("disk", "/", severity: .critical), previousSeverity: .warn))
        // Now acking is fresh again.
        #expect(await store.acknowledge("disk:/") == true)
    }

    // ========================================================================
    // MARK: - P1 #6: a single write() → exactly ONE reconfigure broadcast
    // ========================================================================

    /// THE repro: with the watcher armed, a single `write()` used to fire the
    /// observer broadcast TWICE — once directly, once when the file-watcher
    /// reloaded byte-identical content. After the self-write-suppression fix
    /// it fires exactly once. Counted via the `broadcastCount` test hook.
    @Test func singleWrite_firesExactlyOneBroadcast() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        await loader.startWatching()
        defer { Task { await loader.stopWatching() } }

        // Baseline broadcast count after arming the watcher (startWatching may
        // touch the file but shouldn't broadcast — only reloads/writes do).
        let before = await loader.broadcastCount

        var cfg = await loader.current
        cfg.probes.cpuTemp.enabled = false
        try await loader.write(cfg)

        // Wait well past the ~150 ms watcher debounce so any (suppressed)
        // self-write echo would have had time to fire a second broadcast.
        try await Task.sleep(for: .milliseconds(600))

        let after = await loader.broadcastCount
        #expect(after - before == 1, "a single write() must broadcast exactly once (got \(after - before)); the file-watcher self-write echo must be suppressed")
        // And `current` reflects the write.
        #expect(await loader.current.probes.cpuTemp.enabled == false)

        await loader.stopWatching()
    }

    /// A genuine EXTERNAL edit (different bytes, written behind the loader)
    /// still reloads + broadcasts — the suppression is scoped to self-writes.
    @Test func externalEdit_stillBroadcasts() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        await loader.startWatching()
        defer { Task { await loader.stopWatching() } }

        let before = await loader.broadcastCount

        // Write a DIFFERENT config directly to disk, bypassing loader.write().
        var external = await loader.current
        external.general.language = "ru"
        external.http.port = 50505
        try ConfigLoader.writeAtomic(external.toTOML(), to: url)

        // Wait for the watcher to pick up the external change.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await loader.current.general.language == "ru" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await loader.current.general.language == "ru")
        let after = await loader.broadcastCount
        #expect(after > before, "an external edit must still broadcast")

        await loader.stopWatching()
    }
}
