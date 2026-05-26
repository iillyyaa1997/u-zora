import Testing
import Foundation
@testable import uZora

@Suite("SSEStream subscribe + emit + receive")
struct SSEStreamTests {

    private func sampleAlert(_ key: String, severity: Severity = .warn) -> Alert {
        Alert(
            probe: "disk",
            key: key,
            severity: severity,
            message: "m",
            details: nil,
            firstSeen: Date(),
            lastUpdated: Date()
        )
    }

    @Test func frame_encoding_appeared() async {
        let bus = EventBus()
        let sse = SSEStream(eventBus: bus, heartbeat: .seconds(60))
        let delivery = SSEStream.EventWithTimestamp(
            timestamp: Date(timeIntervalSince1970: 1_715_000_000),
            event: .appeared(sampleAlert("/"))
        )
        let frame = sse.encodeFrame(delivery)
        #expect(frame.event == "appeared")
        #expect(frame.body.contains("\"kind\":\"appeared\""))
        #expect(frame.body.contains("\"alert\""))
    }

    @Test func frame_encoding_escalated() async {
        let bus = EventBus()
        let sse = SSEStream(eventBus: bus, heartbeat: .seconds(60))
        let delivery = SSEStream.EventWithTimestamp(
            timestamp: Date(timeIntervalSince1970: 1_715_000_000),
            event: .escalated(sampleAlert("/", severity: .critical), previousSeverity: .warn)
        )
        let frame = sse.encodeFrame(delivery)
        #expect(frame.event == "escalated")
        #expect(frame.body.contains("\"previous_severity\":\"warn\""))
    }

    @Test func frame_encoding_cleared() async {
        let bus = EventBus()
        let sse = SSEStream(eventBus: bus, heartbeat: .seconds(60))
        let delivery = SSEStream.EventWithTimestamp(
            timestamp: Date(timeIntervalSince1970: 1_715_000_000),
            event: .cleared("disk:/")
        )
        let frame = sse.encodeFrame(delivery)
        #expect(frame.event == "cleared")
        #expect(frame.body.contains("\"alert_id\":\"disk:/\""))
    }

    /// Real loopback round-trip: open `/stream`, fire an event into the
    /// bus, assert the response stream contains the SSE frame within 2s.
    @Test func loopback_streamDeliversEvent() async throws {
        let bus = EventBus()
        let server = HTTPServer(port: 0)
        let sse = SSEStream(eventBus: bus, heartbeat: .seconds(60))
        await server.registerStreaming(method: "GET", path: "/stream") { req, sink in
            await sse.handle(request: req, sink: sink)
        }
        try await server.start()
        let port = await server.boundPort
        defer { Task { await server.stop() } }

        // Open the stream via URLSession streaming task.
        let url = URL(string: "http://127.0.0.1:\(port)/stream")!
        let request = URLRequest(url: url, timeoutInterval: 5)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        #expect(code == 200)
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(contentType.contains("text/event-stream"))

        // Spawn a task that consumes lines.
        let collected = CollectorBox()
        let consumeTask = Task {
            for try await line in bytes.lines {
                await collected.add(line)
                if await collected.contains("event: appeared") {
                    return
                }
                if Task.isCancelled { return }
            }
        }

        // Wait briefly so the subscription registers on the bus, then emit.
        try await Task.sleep(for: .milliseconds(200))
        await bus.emit(.appeared(sampleAlert("/")))

        // Race the consumer against a 2-second timeout.
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if await collected.contains("event: appeared") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        consumeTask.cancel()
        let snapshot = await collected.snapshot()
        let saw = snapshot.contains { $0.contains("event: appeared") }
        #expect(saw, "Expected SSE stream to deliver 'event: appeared' within 2s; got \(snapshot.prefix(10))")
        await server.stop()
    }
}

actor CollectorBox {
    private var lines: [String] = []
    func add(_ s: String) { lines.append(s) }
    func contains(_ needle: String) -> Bool {
        lines.contains { $0.contains(needle) }
    }
    func snapshot() -> [String] { lines }
}
