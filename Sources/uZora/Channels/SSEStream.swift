import Foundation
import os

/// Server-Sent Events emitter for `GET /stream`.
///
/// Subscribes the connection to `EventBus` for the lifetime of the TCP
/// socket. On every event, writes one SSE frame:
///
/// ```
/// event: appeared
/// data: {"alert": {...}, "ts": "..."}
///
/// ```
///
/// Sends a `:ping` comment every `heartbeat` seconds so intermediaries
/// (and the connection's own TCP keepalive) keep the socket warm.
public struct SSEStream: Sendable {

    public let eventBus: EventBus
    /// Parallel diagnosis-layer fan-out (plan D-L4). When wired, `/stream`
    /// ALSO relays `FindingEvent`s + verdict-level transitions as the new
    /// `diagnosed` / `rediagnosed` / `resolved` / `verdict_changed` SSE events —
    /// WITHOUT touching the load-bearing `WatchdogEvent` path (D2). Optional +
    /// defaulted to `nil` so existing callers/tests compile unchanged; a `nil`
    /// bus simply means the diagnosis events are never emitted here.
    public let diagnosisBus: DiagnosisEventBus?
    public let heartbeat: Duration
    /// B5 (plan D-L7): read-only live-client counter. `enter()` at the top of
    /// `handle`, `leave()` in the disconnect `defer` — a diagnostics-only badge
    /// ("N clients connected"), never on the delivery hot path. Optional +
    /// defaulted `nil` so existing callers/tests compile unchanged.
    public let clientCounter: StreamClientCounter?

    private let encoder: JSONEncoder
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "sse")

    public init(
        eventBus: EventBus,
        diagnosisBus: DiagnosisEventBus? = nil,
        heartbeat: Duration = .seconds(30),
        clientCounter: StreamClientCounter? = nil
    ) {
        self.eventBus = eventBus
        self.diagnosisBus = diagnosisBus
        self.heartbeat = heartbeat
        self.clientCounter = clientCounter
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        // Match REST/JSONL channel key style.
        enc.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = enc
    }

    /// Handler entry point. Stays alive until the client disconnects
    /// (the streaming sink's connection goes to `.failed` / `.cancelled`).
    public func handle(request: HTTPRequest, sink: StreamingResponseSink) async {
        // B5: count this live client for the "N clients connected" badge. Enter
        // once here, leave once when the connection tears down (the `defer`
        // below), mirroring the subscribe/unsubscribe bracket. Diagnostics-only.
        await clientCounter?.enter()
        defer { if let clientCounter { Task { await clientCounter.leave() } } }

        // Both bus subscribers push onto ONE AsyncStream carrying a small
        // discriminated union, so the `handle` task multiplexes the two
        // parallel fan-outs (WatchdogEvent + DiagnosisStreamEvent) together
        // with heartbeats and disconnect detection.
        let stream = AsyncStream<StreamItem>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let token = await eventBus.subscribe { event in
            stream.continuation.yield(.watchdog(EventWithTimestamp(timestamp: Date(), event: event)))
        }
        defer { Task { await eventBus.unsubscribe(token) } }

        // Subscribe the SAME connection to the diagnosis fan-out (if wired),
        // exactly the way the WatchdogEvent bus above is subscribed — a second
        // independent broadcast path, so neither side knows about the other.
        var diagnosisToken: UUID?
        if let diagnosisBus {
            diagnosisToken = await diagnosisBus.subscribe { event in
                stream.continuation.yield(.diagnosis(DiagnosisEventWithTimestamp(timestamp: Date(), event: event)))
            }
        }
        defer {
            if let diagnosisToken, let diagnosisBus {
                Task { await diagnosisBus.unsubscribe(diagnosisToken) }
            }
        }

        // Send an initial `:connected` comment so curl users see something
        // immediately and the TCP socket is confirmed flowing.
        await sink.send(event: nil, data: "connected at \(ISO8601DateFormatter().string(from: Date()))")

        // Spawn a heartbeat task that races with the event stream.
        let heartbeatTask = Task { [heartbeat] in
            while !Task.isCancelled {
                try? await Task.sleep(for: heartbeat)
                if Task.isCancelled { return }
                await sink.sendHeartbeat()
            }
        }
        defer { heartbeatTask.cancel() }

        for await item in stream.stream {
            if !sink.isOpen { break }
            let frame: Frame
            switch item {
            case .watchdog(let delivery):  frame = encodeFrame(delivery)
            case .diagnosis(let delivery): frame = encodeFrame(delivery)
            }
            await sink.send(event: frame.event, data: frame.body)
        }
    }

    /// Internal multiplex tag so the two parallel fan-outs share one stream.
    private enum StreamItem: Sendable {
        case watchdog(EventWithTimestamp)
        case diagnosis(DiagnosisEventWithTimestamp)
    }

    // MARK: - Frame encoding

    public struct EventWithTimestamp: Sendable {
        public let timestamp: Date
        public let event: WatchdogEvent
        public init(timestamp: Date, event: WatchdogEvent) {
            self.timestamp = timestamp
            self.event = event
        }
    }

    /// Diagnosis-layer delivery (plan D-L4) — the sibling of
    /// `EventWithTimestamp` for the `DiagnosisStreamEvent` fan-out.
    public struct DiagnosisEventWithTimestamp: Sendable {
        public let timestamp: Date
        public let event: DiagnosisStreamEvent
        public init(timestamp: Date, event: DiagnosisStreamEvent) {
            self.timestamp = timestamp
            self.event = event
        }
    }

    public struct Frame: Equatable, Sendable {
        public let event: String
        public let body: String
    }

    public func encodeFrame(_ delivery: EventWithTimestamp) -> Frame {
        let line = JSONLEventSink.Line(timestamp: delivery.timestamp, event: delivery.event)
        let data: Data
        do {
            data = try encoder.encode(line)
        } catch {
            data = Data("{\"error\":\"encode failed: \(error)\"}".utf8)
        }
        let body = String(data: data, encoding: .utf8) ?? "{}"
        let name: String
        switch delivery.event {
        case .appeared:  name = "appeared"
        case .escalated: name = "escalated"
        case .cleared:   name = "cleared"
        }
        return Frame(event: name, body: body)
    }

    /// Encode one diagnosis-layer delivery into an SSE `Frame` (plan D-L4).
    /// New event names: `diagnosed` / `rediagnosed` / `resolved` (one per
    /// `FindingEvent` kind) + `verdict_changed`. The body mirrors the
    /// `JSONLEventSink.Line` shape via `DiagnosisEventLine` (snake_case keys).
    public func encodeFrame(_ delivery: DiagnosisEventWithTimestamp) -> Frame {
        let line = DiagnosisEventLine(timestamp: delivery.timestamp, event: delivery.event)
        let data: Data
        do {
            data = try encoder.encode(line)
        } catch {
            data = Data("{\"error\":\"encode failed: \(error)\"}".utf8)
        }
        let body = String(data: data, encoding: .utf8) ?? "{}"
        let name: String
        switch delivery.event {
        case .finding(.diagnosed):   name = "diagnosed"
        case .finding(.rediagnosed): name = "rediagnosed"
        case .finding(.resolved):    name = "resolved"
        case .verdictChanged:        name = "verdict_changed"
        }
        return Frame(event: name, body: body)
    }
}
