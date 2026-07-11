import Testing
import Foundation
@testable import uZora

/// B1a (plan D-L4) — the PARALLEL FindingEvent / verdict fan-out onto
/// `GET /stream`. Asserts:
/// - `DiagnosisEventBus` broadcasts to subscribers (sibling of `EventBus`).
/// - `SSEStream.encodeFrame(DiagnosisEventWithTimestamp)` produces the new
///   `diagnosed` / `rediagnosed` / `resolved` / `verdict_changed` frames with
///   the useful snake_case body fields — WITHOUT touching the `WatchdogEvent`
///   path (that keeps working, covered by `SSEStreamTests`).
/// - A real loopback: an event emitted onto the diagnosis bus lands on the
///   live `/stream` socket as the correct SSE `event:` name.
@Suite("Diagnosis fan-out onto /stream (Gap A)")
struct DiagnosisStreamTests {

    private func finding(
        detector: String = "runaway_daemon",
        subject: String = "ecosystemd",
        severity: Severity = .warn,
        confidence: Confidence = .high,
        title: String = "System daemon pinning CPU",
        suggestedAction: String? = "reboot recommended"
    ) -> Finding {
        Finding(
            detector: detector,
            subject: subject,
            severity: severity,
            confidence: confidence,
            title: title,
            explanation: "e",
            evidence: nil,
            suggestedAction: suggestedAction,
            firstSeen: Date(timeIntervalSince1970: 1_715_000_000),
            lastUpdated: Date(timeIntervalSince1970: 1_715_000_100)
        )
    }

    private func sse() -> SSEStream {
        SSEStream(eventBus: EventBus(), diagnosisBus: DiagnosisEventBus(), heartbeat: .seconds(60))
    }

    private func delivery(_ event: DiagnosisStreamEvent) -> SSEStream.DiagnosisEventWithTimestamp {
        SSEStream.DiagnosisEventWithTimestamp(
            timestamp: Date(timeIntervalSince1970: 1_715_000_000),
            event: event
        )
    }

    // MARK: - encodeFrame (deterministic, no sockets)

    @Test func frame_diagnosed_carriesFindingFields() {
        let frame = sse().encodeFrame(delivery(.finding(.diagnosed(finding()))))
        #expect(frame.event == "diagnosed")
        #expect(frame.body.contains("\"kind\":\"diagnosed\""))
        #expect(frame.body.contains("\"detector\":\"runaway_daemon\""))
        #expect(frame.body.contains("\"subject\":\"ecosystemd\""))
        #expect(frame.body.contains("\"severity\":\"warn\""))
        #expect(frame.body.contains("\"title\":\"System daemon pinning CPU\""))
        #expect(frame.body.contains("\"suggested_action\":\"reboot recommended\""))
        // resolved/verdict-only fields are omitted (encodeIfPresent).
        #expect(!frame.body.contains("finding_id"))
        #expect(!frame.body.contains("previous_level"))
    }

    @Test func frame_rediagnosed_carriesPreviousAxes() {
        let event = DiagnosisStreamEvent.finding(.rediagnosed(
            finding(severity: .critical, confidence: .high),
            previousSeverity: .warn,
            previousConfidence: .low
        ))
        let frame = sse().encodeFrame(delivery(event))
        #expect(frame.event == "rediagnosed")
        #expect(frame.body.contains("\"kind\":\"rediagnosed\""))
        #expect(frame.body.contains("\"previous_severity\":\"warn\""))
        #expect(frame.body.contains("\"previous_confidence\":\"low\""))
        #expect(frame.body.contains("\"severity\":\"critical\""))
    }

    @Test func frame_resolved_carriesFindingID() {
        let frame = sse().encodeFrame(delivery(.finding(.resolved("runaway_daemon:ecosystemd"))))
        #expect(frame.event == "resolved")
        #expect(frame.body.contains("\"kind\":\"resolved\""))
        #expect(frame.body.contains("\"finding_id\":\"runaway_daemon:ecosystemd\""))
        // No finding payload fields on a resolve.
        #expect(!frame.body.contains("\"detector\""))
    }

    @Test func frame_verdictChanged_carriesOldNewLevelAndHeadline() {
        let event = DiagnosisStreamEvent.verdictChanged(
            from: .good, to: .degraded, headline: "System daemon pinning CPU"
        )
        let frame = sse().encodeFrame(delivery(event))
        #expect(frame.event == "verdict_changed")
        #expect(frame.body.contains("\"kind\":\"verdict_changed\""))
        #expect(frame.body.contains("\"previous_level\":\"good\""))
        #expect(frame.body.contains("\"level\":\"degraded\""))
        #expect(frame.body.contains("\"headline\":\"System daemon pinning CPU\""))
    }

    /// The Gap-A path does NOT disturb the existing WatchdogEvent frames.
    @Test func watchdogFramesUnchanged() {
        let alert = Alert(
            probe: "disk", key: "/", severity: .warn, message: "m",
            details: nil, firstSeen: Date(), lastUpdated: Date()
        )
        let frame = sse().encodeFrame(SSEStream.EventWithTimestamp(
            timestamp: Date(timeIntervalSince1970: 1_715_000_000),
            event: .appeared(alert)
        ))
        #expect(frame.event == "appeared")
        #expect(frame.body.contains("\"kind\":\"appeared\""))
    }

    // MARK: - DiagnosisEventBus fan-out

    @Test func bus_broadcastsToSubscriber() async {
        let bus = DiagnosisEventBus()
        let box = DiagnosisCollectorBox()
        _ = await bus.subscribe { ev in Task { await box.add(ev) } }
        await bus.emit(.finding(.diagnosed(finding())))
        await bus.emit(.verdictChanged(from: .good, to: .watch, headline: "h"))
        // Let the detached add-tasks land.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await box.count == 2)
        #expect(await bus.emittedCount == 2)
    }

    // MARK: - Live loopback

    /// Real loopback round-trip: open `/stream`, fire diagnosis events into the
    /// diagnosis bus, assert the response stream contains the new SSE frames.
    @Test func loopback_streamDeliversDiagnosisEvents() async throws {
        let bus = DiagnosisEventBus()
        let server = HTTPServer(port: 0)
        let sse = SSEStream(eventBus: EventBus(), diagnosisBus: bus, heartbeat: .seconds(60))
        await server.registerStreaming(method: "GET", path: "/stream") { req, sink in
            await sse.handle(request: req, sink: sink)
        }
        try await server.start()
        let port = await server.boundPort
        defer { Task { await server.stop() } }

        let url = URL(string: "http://127.0.0.1:\(port)/stream")!
        let request = URLRequest(url: url, timeoutInterval: 5)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let collected = CollectorBox()
        let consumeTask = Task {
            for try await line in bytes.lines {
                await collected.add(line)
                if await collected.contains("event: verdict_changed") { return }
                if Task.isCancelled { return }
            }
        }

        try await Task.sleep(for: .milliseconds(200))
        await bus.emit(.finding(.diagnosed(finding())))
        await bus.emit(.verdictChanged(from: .good, to: .degraded, headline: "h"))

        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if await collected.contains("event: verdict_changed") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        consumeTask.cancel()
        let snapshot = await collected.snapshot()
        #expect(snapshot.contains { $0.contains("event: diagnosed") },
                "expected 'event: diagnosed'; got \(snapshot.prefix(12))")
        #expect(snapshot.contains { $0.contains("event: verdict_changed") },
                "expected 'event: verdict_changed'; got \(snapshot.prefix(12))")
        await server.stop()
    }
}

actor DiagnosisCollectorBox {
    private var events: [DiagnosisStreamEvent] = []
    func add(_ e: DiagnosisStreamEvent) { events.append(e) }
    var count: Int { events.count }
}
