import Foundation
import os

/// Composition root for the four bridge channels.
///
/// Wires together:
/// - `StateStore` (in-memory snapshot)
/// - `JSONLEventSink` (append-only writer)
/// - `HTTPServer` carrying REST + SSE + MCP routes
///
/// `start(eventBus:)` subscribes the channels to the bus, installs all
/// HTTP routes, and starts listening. `stop()` reverses the wiring.
public actor ChannelHost {

    public let port: UInt16
    public let state: StateStore
    public let jsonl: JSONLEventSink
    public let metrics: MetricsStore?
    public let httpServer: HTTPServer
    public let rest: RESTHandlers
    public let sse: SSEStream
    public let mcp: MCPServer

    private weak var eventBus: EventBus?
    private var jsonlSubscriberToken: UUID?
    private var stateSubscriberToken: UUID?

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "channels")

    public init(
        port: UInt16,
        state: StateStore,
        jsonl: JSONLEventSink,
        eventBus: EventBus,
        metrics: MetricsStore? = nil,
        configLoader: ConfigLoader? = nil,
        allowWrites: Bool = true
    ) {
        self.port = port
        self.state = state
        self.jsonl = jsonl
        self.metrics = metrics
        self.eventBus = eventBus
        let httpServer = HTTPServer(port: port)
        self.httpServer = httpServer
        let rest = RESTHandlers(
            state: state,
            metricsStore: metrics,
            configLoader: configLoader,
            allowWrites: allowWrites
        )
        self.rest = rest
        self.sse = SSEStream(eventBus: eventBus)
        self.mcp = MCPServer(tools: MCPTools(
            rest: rest,
            httpBaseURL: "http://127.0.0.1:\(port)"
        ))
    }

    /// Subscribe the JSONL sink + StateStore to the EventBus and start
    /// the HTTP listener.
    public func start() async throws {
        guard let bus = eventBus else { return }

        let jsonlRef = jsonl
        let jsonlToken = await bus.subscribe { [jsonlRef] event in
            Task { await jsonlRef.emit(event) }
        }
        self.jsonlSubscriberToken = jsonlToken
        await jsonl.startRotationLoop()

        let stateRef = state
        let stateToken = await bus.subscribe { [stateRef] event in
            Task { await stateRef.ingest(event) }
        }
        self.stateSubscriberToken = stateToken

        try await installRoutes()
        try await httpServer.start()
        let bound = await httpServer.boundPort
        log.info("ChannelHost ready on http://127.0.0.1:\(bound, privacy: .public) (REST, SSE, MCP)")
    }

    /// Tear everything down: cancel subscriptions, stop the listener,
    /// flush the JSONL sink.
    public func stop() async {
        if let token = jsonlSubscriberToken, let bus = eventBus {
            await bus.unsubscribe(token)
        }
        jsonlSubscriberToken = nil
        if let token = stateSubscriberToken, let bus = eventBus {
            await bus.unsubscribe(token)
        }
        stateSubscriberToken = nil
        await httpServer.stop()
        await jsonl.close()
    }

    public func boundPort() async -> UInt16 {
        await httpServer.boundPort
    }

    private func installRoutes() async throws {
        let rest = self.rest
        let mcp = self.mcp
        let sse = self.sse

        await httpServer.register(method: "GET", path: "/status") { req in
            await rest.status()
        }
        await httpServer.register(method: "GET", path: "/alerts") { req in
            let floor = req.query["severity"].flatMap { Severity(rawValue: $0) }
            return await rest.alerts(minSeverity: floor)
        }
        await httpServer.register(method: "GET", path: "/probes") { req in
            await rest.probes()
        }
        await httpServer.register(method: "GET", path: "/metrics") { req in
            let probe = req.query["probe"]
            let name = req.query["name"]
            let from = req.query["from"].flatMap { RESTHandlers.parseISO8601($0) }
            let to = req.query["to"].flatMap { RESTHandlers.parseISO8601($0) }
            return await rest.metrics(probe: probe, name: name, from: from, to: to)
        }
        await httpServer.register(method: "POST", path: "/mcp") { req in
            await mcp.handle(req)
        }
        // Write endpoints (Phase 7). Both take their identifier in the JSON
        // body, not the URL path, because alert ids (`disk:/`) and the exact-
        // match router don't mix. Both go through `rest.dispatch` so REST and
        // MCP share one code path + one `allow_writes` gate.
        await httpServer.register(method: "POST", path: "/alerts/ack") { req in
            await rest.dispatch(req)
        }
        await httpServer.register(method: "POST", path: "/config/probe") { req in
            await rest.dispatch(req)
        }
        await httpServer.registerStreaming(method: "GET", path: "/stream") { req, sink in
            await sse.handle(request: req, sink: sink)
        }
    }
}
