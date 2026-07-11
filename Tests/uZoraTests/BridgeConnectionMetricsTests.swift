import Testing
import Foundation
import SwiftUI
@testable import uZora

/// Phase B5 (plan D-L7) — in-app connection surface: the read-only live
/// connection metrics (stream client counter + last-MCP-request clock), the
/// UIState mirrors + bearer token, the footer "LLM" pill selection, the
/// DemoDataSource animation, and the channel-shim `.mcp.json` snippet builder.
@Suite("B5 — in-app connection surface")
struct BridgeConnectionMetricsTests {

    // MARK: - StreamClientCounter

    @Test func streamClientCounter_enterLeaveValue() async {
        let c = StreamClientCounter()
        #expect(await c.value() == 0)
        await c.enter()
        await c.enter()
        #expect(await c.value() == 2)
        await c.leave()
        #expect(await c.value() == 1)
        await c.leave()
        #expect(await c.value() == 0)
        // Never underflows past zero.
        await c.leave()
        #expect(await c.value() == 0)
    }

    // MARK: - LastRequestClock

    @Test func lastRequestClock_stampValue() async {
        let clock = LastRequestClock()
        #expect(await clock.value() == nil)
        let t = Date(timeIntervalSince1970: 1_715_000_000)
        await clock.stamp(t)
        #expect(await clock.value() == t)
        let t2 = Date(timeIntervalSince1970: 1_715_000_500)
        await clock.stamp(t2)
        #expect(await clock.value() == t2)
    }

    // MARK: - SSE handle brackets the counter (real loopback)

    /// Open a `/stream` connection with a counter wired → the counter reaches 1
    /// while connected and returns to 0 once the connection tears down. Uses the
    /// same loopback harness as `SSEStreamTests` (HTTP/SSE tests may flake —
    /// re-run once if only these fail).
    ///
    /// The SSE `handle` loop only re-checks `sink.isOpen` when an item arrives,
    /// so to observe the disconnect `defer` we (a) `stop()` the server — which
    /// cancels the connection locally (a deterministic `.cancelled` state, so
    /// `sink.isOpen` flips false) — then (b) emit bus events to wake the parked
    /// `for await`, which breaks and runs the `defer` → `leave()`.
    @Test func sseHandle_incrementsThenDecrementsCounter() async throws {
        let bus = EventBus()
        let counter = StreamClientCounter()
        let server = HTTPServer(port: 0)
        let sse = SSEStream(eventBus: bus, heartbeat: .seconds(60), clientCounter: counter)
        await server.registerStreaming(method: "GET", path: "/stream") { req, sink in
            await sse.handle(request: req, sink: sink)
        }
        try await server.start()
        let port = await server.boundPort

        #expect(await counter.value() == 0)

        // Open the stream and hold it while we assert the counter rose to 1.
        let url = URL(string: "http://127.0.0.1:\(port)/stream")!
        let request = URLRequest(url: url, timeoutInterval: 5)
        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        let consume = Task {
            for try await _ in bytes.lines { if Task.isCancelled { return } }
        }

        var sawOne = false
        for _ in 0..<40 {
            if await counter.value() >= 1 { sawOne = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(sawOne, "counter should reach 1 while a /stream client is connected")

        // Tear the connection down (local .cancelled), then nudge the parked
        // handle loop awake with events → its `defer` runs → counter → 0.
        consume.cancel()
        await server.stop()
        var backToZero = false
        for _ in 0..<80 {
            await bus.emit(.appeared(sampleAlert("/")))
            if await counter.value() == 0 { backToZero = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(backToZero, "counter should return to 0 after the connection tears down")
    }

    private func sampleAlert(_ key: String, severity: Severity = .warn) -> uZora.Alert {
        uZora.Alert(probe: "disk", key: key, severity: severity, message: "m", details: nil,
                    firstSeen: Date(), lastUpdated: Date())
    }

    // MARK: - MCPServer.handle stamps the clock

    @Test func mcpHandle_stampsClock() async {
        let store = StateStore()
        let rest = RESTHandlers(state: store)
        let clock = LastRequestClock()
        let mcp = MCPServer(
            tools: MCPTools(rest: rest, httpBaseURL: "http://127.0.0.1:0"),
            lastRequestClock: clock
        )
        #expect(await clock.value() == nil)

        // A GET (405 probe) still stamps — any verb proves a client is talking.
        _ = await mcp.handle(HTTPRequest(method: "GET", path: "/mcp", query: [:], headers: [:], body: Data()))
        let afterGet = await clock.value()
        #expect(afterGet != nil)

        // A JSON-RPC POST re-stamps.
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        _ = await mcp.handle(HTTPRequest(method: "POST", path: "/mcp", query: [:], headers: [:], body: body))
        let afterPost = await clock.value()
        #expect(afterPost != nil)
        if let a = afterGet, let b = afterPost { #expect(b >= a) }
    }

    // MARK: - ChannelHost exposes the metrics

    @Test func channelHost_exposesMetricsAccessors() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-b5-\(UUID().uuidString)", isDirectory: true)
        let bus = EventBus()
        let state = StateStore()
        let jsonl = try JSONLEventSink(baseDir: dir, retentionDays: 30)
        let counter = StreamClientCounter()
        let clock = LastRequestClock()
        let host = ChannelHost(
            port: 0, state: state, jsonl: jsonl, eventBus: bus,
            streamClientCounter: counter, lastMCPRequestClock: clock
        )
        // Fresh: no clients, no request yet.
        #expect(await host.streamClientsConnected() == 0)
        #expect(await host.lastMCPRequestAt() == nil)
        // Drive the injected metrics; the accessors reflect them.
        await counter.enter()
        await clock.stamp(Date(timeIntervalSince1970: 42))
        #expect(await host.streamClientsConnected() == 1)
        #expect(await host.lastMCPRequestAt() == Date(timeIntervalSince1970: 42))
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - UIState fields + publishing

    @Test @MainActor func uiState_bridgeFields_publish() {
        let state = UIState()
        // Defaults.
        #expect(state.bridgeClientsConnected == 0)
        #expect(state.lastMCPRequestAt == nil)
        #expect(state.bridgeToken == "")
        #expect(state.bridgeTokenNeedsRestart == false)
        #expect(state.llmClientsConnected == 0)

        // objectWillChange fires on a published mutation.
        var fired = false
        let cancellable = state.objectWillChange.sink { fired = true }
        state.bridgeClientsConnected = 3
        #expect(fired)
        // llmClientsConnected mirrors bridgeClientsConnected.
        #expect(state.llmClientsConnected == 3)
        state.bridgeToken = "deadbeef"
        #expect(state.bridgeToken == "deadbeef")
        cancellable.cancel()
    }

    // MARK: - Footer "LLM" pill 3-state selection

    @Test func llmPill_threeStateSelection() {
        // off — bridge disabled, regardless of count.
        #expect(llmPillState(mcpAlive: false, clients: 0) == .off)
        #expect(llmPillState(mcpAlive: false, clients: 5) == .off)
        // configured — bridge up, zero clients.
        #expect(llmPillState(mcpAlive: true, clients: 0) == .configured)
        // connected(N) — bridge up, N>0.
        #expect(llmPillState(mcpAlive: true, clients: 1) == .connected(1))
        #expect(llmPillState(mcpAlive: true, clients: 4) == .connected(4))
    }

    // MARK: - DemoDataSource animates llmClientsConnected

    @Test @MainActor func demo_animatesLLMClients() {
        let demo = DemoDataSource(autostart: false)
        var values: Set<Int> = [demo.llmClientsConnected]
        for _ in 0..<6 {
            demo.step()
            values.insert(demo.llmClientsConnected)
        }
        // The count is not constant across the motion cycle.
        #expect(values.count > 1)
    }

    // MARK: - .mcp.json channel-shim snippet builder

    @Test func stdioSnippet_shimForm_pathPortNoToken() {
        let snippet = uzoraChannelStdioSnippet(
            scriptPath: "/Applications/uZora.app/Contents/Resources/channel/dist/uzora-channel.js",
            streamURL: "http://127.0.0.1:39842/stream",
            token: nil
        )
        // stdio form (distinct from the HTTP-MCP snippet).
        #expect(snippet.contains("\"command\": \"node\""))
        #expect(snippet.contains("\"args\": [\"/Applications/uZora.app/Contents/Resources/channel/dist/uzora-channel.js\"]"))
        #expect(snippet.contains("\"UZORA_STREAM_URL\": \"http://127.0.0.1:39842/stream\""))
        #expect(snippet.contains("\"UZORA_MIN_SEVERITY\": \"warn\""))
        // No token → no UZORA_TOKEN key.
        #expect(!snippet.contains("UZORA_TOKEN"))
        // Valid JSON.
        #expect((try? JSONSerialization.jsonObject(with: Data(snippet.utf8))) != nil)
    }

    @Test func stdioSnippet_shimForm_withToken() {
        let snippet = uzoraChannelStdioSnippet(
            scriptPath: "/abs/uzora-channel.js",
            streamURL: "http://127.0.0.1:8080/stream",
            token: "cafef00d"
        )
        #expect(snippet.contains("\"UZORA_TOKEN\": \"cafef00d\""))
        #expect(snippet.contains("\"UZORA_MIN_SEVERITY\": \"warn\""))
        #expect(snippet.contains("http://127.0.0.1:8080/stream"))
        #expect((try? JSONSerialization.jsonObject(with: Data(snippet.utf8))) != nil)
    }

    // MARK: - Live badge text

    @Test func bridgeBadge_text() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(bridgeClientsBadgeText(clients: 0, lastMCPRequest: nil, now: now) == "no clients connected")
        let one = bridgeClientsBadgeText(clients: 1, lastMCPRequest: nil, now: now)
        #expect(one.contains("1 client connected"))
        let two = bridgeClientsBadgeText(
            clients: 2,
            lastMCPRequest: now.addingTimeInterval(-12),
            now: now
        )
        #expect(two.contains("2 clients connected"))
        #expect(two.contains("last MCP request 12s ago"))
    }

    @Test func relativeAgo_buckets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(relativeAgoLabel(from: now, now: now) == "just now")
        #expect(relativeAgoLabel(from: now.addingTimeInterval(-5), now: now) == "5s ago")
        #expect(relativeAgoLabel(from: now.addingTimeInterval(-120), now: now) == "2m ago")
        #expect(relativeAgoLabel(from: now.addingTimeInterval(-7200), now: now) == "2h ago")
    }

    // MARK: - Compile-level: PopoverView builds over both sources with the new footer

    @Test @MainActor func popoverView_buildsOverBothSources() {
        let layout = PopoverLayout.balanced
        // UIState (live) source.
        let live = UIState()
        let liveView = PopoverView(state: live, layout: layout)
        _ = liveView.body
        // DemoDataSource source — the generic footer value (llmClientsConnected)
        // is present on both, so both instantiations type-check.
        let demo = DemoDataSource(autostart: false)
        let demoView = PopoverView(state: demo, layout: layout)
        _ = demoView.body
        #expect(live.llmClientsConnected == live.bridgeClientsConnected)
    }
}
