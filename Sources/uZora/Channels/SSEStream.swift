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
    public let heartbeat: Duration

    private let encoder: JSONEncoder
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "sse")

    public init(eventBus: EventBus, heartbeat: Duration = .seconds(30)) {
        self.eventBus = eventBus
        self.heartbeat = heartbeat
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
        // The bus subscriber pushes events onto an AsyncStream so the
        // `handle` task can multiplex them with heartbeats and disconnect
        // detection.
        let stream = AsyncStream<EventWithTimestamp>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let token = await eventBus.subscribe { event in
            stream.continuation.yield(EventWithTimestamp(timestamp: Date(), event: event))
        }
        defer { Task { await eventBus.unsubscribe(token) } }

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

        for await delivery in stream.stream {
            if !sink.isOpen { break }
            let frame = encodeFrame(delivery)
            await sink.send(event: frame.event, data: frame.body)
        }
    }

    // MARK: - Frame encoding

    public struct EventWithTimestamp: Sendable {
        public let timestamp: Date
        public let event: WatchdogEvent
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
}
