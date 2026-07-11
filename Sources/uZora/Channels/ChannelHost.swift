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
    public let actionRunner: ActionRunner?
    /// Phase 5: read-only diagnosis snapshot backing `GET /findings` +
    /// `GET /verdict` (+ the MCP read tools). Optional + defaulted to `nil`
    /// so existing `ChannelHost(...)` call sites + tests compile unchanged.
    public let diagnosisStore: DiagnosisStore?
    /// B1a: parallel diagnosis-layer fan-out (plan D-L4). When wired, `SSEStream`
    /// ALSO relays finding + verdict events onto `/stream`. Optional + defaulted
    /// to `nil` so existing call sites/tests compile unchanged.
    public let diagnosisBus: DiagnosisEventBus?
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
        allowWrites: Bool = true,
        actionRunner: ActionRunner? = nil,
        diagnosisStore: DiagnosisStore? = nil,
        diagnosisBus: DiagnosisEventBus? = nil,
        bridgeAuth: BridgeAuth? = nil,
        executeEnabled: Bool = false,
        capabilityToken: String = "",
        approvalRequester: (@Sendable (_ actionID: String, _ actionName: String) async -> Void)? = nil
    ) {
        self.port = port
        self.state = state
        self.jsonl = jsonl
        self.metrics = metrics
        self.actionRunner = actionRunner
        self.diagnosisStore = diagnosisStore
        self.diagnosisBus = diagnosisBus
        self.eventBus = eventBus
        let httpServer = HTTPServer(port: port)
        self.httpServer = httpServer
        let rest = RESTHandlers(
            state: state,
            metricsStore: metrics,
            configLoader: configLoader,
            allowWrites: allowWrites,
            actionRunner: actionRunner,
            diagnosisStore: diagnosisStore,
            // B1b: gate the write tier with the bridge bearer token. The write
            // REST routes call `rest.dispatch(req)` and the MCP routes call
            // `mcp.handle(req)`, both of which already carry the request headers
            // → the bearer + Origin/Host checks run on every write.
            bridgeAuth: bridgeAuth,
            // B2 Execute tier: the master switch + optional unattended capability
            // token (both from [mcp] config), plus the human-tap approval poster
            // (wired to the notification center by uZoraApp).
            executeEnabled: executeEnabled,
            capabilityToken: capabilityToken,
            approvalRequester: approvalRequester
        )
        self.rest = rest
        self.sse = SSEStream(eventBus: eventBus, diagnosisBus: diagnosisBus)
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
        await httpServer.register(method: "GET", path: "/actions") { req in
            await rest.actions()
        }
        await httpServer.register(method: "GET", path: "/metrics") { req in
            let probe = req.query["probe"]
            let name = req.query["name"]
            let from = req.query["from"].flatMap { RESTHandlers.parseISO8601($0) }
            let to = req.query["to"].flatMap { RESTHandlers.parseISO8601($0) }
            return await rest.metrics(probe: probe, name: name, from: from, to: to)
        }
        // B1a (plan D-L5): catalog of the distinct metric series in the store.
        await httpServer.register(method: "GET", path: "/metrics/catalog") { _ in
            await rest.metricsCatalog()
        }
        // B1a (plan D-C4): read-only effective popover layout.
        await httpServer.register(method: "GET", path: "/layout") { _ in
            await rest.layout()
        }
        await httpServer.register(method: "GET", path: "/findings") { req in
            let floor = req.query["severity"].flatMap { Severity(rawValue: $0) }
            return await rest.findings(minSeverity: floor)
        }
        await httpServer.register(method: "GET", path: "/verdict") { _ in
            await rest.verdict()
        }
        await httpServer.register(method: "POST", path: "/mcp") { req in
            await mcp.handle(req)
        }
        // B1a (plan D-L6): streamable-HTTP tolerance — a non-POST GET to /mcp
        // returns 405 (Allow: POST) instead of a bare 404. `mcp.handle` itself
        // returns the 405 for any non-POST verb, so this is single-sourced.
        await httpServer.register(method: "GET", path: "/mcp") { req in
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
        // B2 Execute tier: request an action run ({id, dry_run?, capability_token?}).
        // Goes through `rest.dispatch` so REST + MCP share the one run funnel +
        // the same allow_writes / bearer / execute-tier gates.
        await httpServer.register(method: "POST", path: "/actions/run") { req in
            await rest.dispatch(req)
        }
        await httpServer.registerStreaming(method: "GET", path: "/stream") { req, sink in
            await sse.handle(request: req, sink: sink)
        }
    }
}
