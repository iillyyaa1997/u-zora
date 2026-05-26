import Foundation

/// Registered MCP tools and their `tools/call` dispatch.
///
/// Each tool wraps a REST handler invocation so the bridge is single-
/// sourced — change `RESTHandlers.alerts()` once and every channel
/// (MCP, REST, SSE) sees the same shape.
public struct MCPTools: Sendable {

    public let rest: RESTHandlers
    public let httpBaseURL: String

    public init(rest: RESTHandlers, httpBaseURL: String) {
        self.rest = rest
        self.httpBaseURL = httpBaseURL
    }

    public struct InvokeError: Swift.Error, Sendable {
        public let code: ErrorCode
        public let message: String
        public init(code: ErrorCode, message: String) {
            self.code = code
            self.message = message
        }
    }

    // MARK: - Tool dispatch

    public func invoke(name: String, arguments: JSONValue) async throws -> JSONValue {
        switch name {
        case "uzora_status":
            let resp = await rest.status()
            return MCPTools.wrap(resp)

        case "uzora_list_alerts":
            var floor: Severity? = nil
            if case .object(let args) = arguments,
               case .string(let s)? = args["severity"] {
                floor = Severity(rawValue: s)
            }
            let resp = await rest.alerts(minSeverity: floor)
            return MCPTools.wrap(resp)

        case "uzora_list_probes":
            let resp = await rest.probes()
            return MCPTools.wrap(resp)

        case "uzora_get_metric":
            var probe: String? = nil
            var fromDate: Date? = nil
            var toDate: Date? = nil
            if case .object(let args) = arguments {
                if case .string(let s)? = args["probe"] { probe = s }
                if case .string(let s)? = args["from"] { fromDate = RESTHandlers.parseISO8601(s) }
                if case .string(let s)? = args["to"]   { toDate   = RESTHandlers.parseISO8601(s) }
            }
            let resp = await rest.metrics(probe: probe, from: fromDate, to: toDate)
            return MCPTools.wrap(resp)

        case "uzora_subscribe":
            // Phase 4 simplification: MCP notifications-over-SSE-transport
            // is deferred to Phase 6+. Until then, the tool returns the
            // SSE URL so the LLM client knows where to subscribe.
            let url = "\(httpBaseURL)/stream"
            return .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Connect to \(url) (Server-Sent Events) for real-time uZora watchdog events. Phase 4 MVP delegates the long-poll to SSE; future versions will push notifications natively via MCP.")
                    ])
                ]),
                "structuredContent": .object([
                    "sse_url": .string(url),
                    "transport": .string("server-sent-events"),
                    "phase4_note": .string("MCP notifications-over-transport deferred to Phase 6+; subscribe to the SSE URL instead.")
                ])
            ])

        default:
            throw InvokeError(
                code: .toolNotFound,
                message: "no such tool: \(name)"
            )
        }
    }

    /// Wrap an HTTP response body as an MCP tool result. The tool result
    /// shape is `{content: [{type: "text", text: "<json>"}], structuredContent: <parsed>}`
    /// so LLM clients see both human-readable JSON and machine-readable
    /// structured data.
    public static func wrap(_ response: HTTPResponse) -> JSONValue {
        let bodyText = String(data: response.body, encoding: .utf8) ?? "{}"
        let structured: JSONValue
        do {
            structured = try JSONValue.decode(response.body)
        } catch {
            structured = .object([
                "error": .string("body was not valid JSON: \(error)")
            ])
        }
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(bodyText)
                ])
            ]),
            "structuredContent": structured,
            "isError": .bool(response.status >= 400)
        ])
    }

    // MARK: - Tool schemas (returned by tools/list)

    public static let schemas: [[String: JSONValue]] = [
        [
            "name": .string("uzora_status"),
            "description": .string("Return the agent's current high-level state: uptime, registered probe count, active alert count, and power profile."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
        ],
        [
            "name": .string("uzora_list_alerts"),
            "description": .string("List currently firing health/resource alerts. Optionally filter by minimum severity."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "severity": .object([
                        "type": .string("string"),
                        "enum": .array([.string("info"), .string("warn"), .string("critical")]),
                        "description": .string("Filter to alerts at or above this severity."),
                    ]),
                ]),
            ]),
        ],
        [
            "name": .string("uzora_list_probes"),
            "description": .string("Return the inventory of registered probes with their poll interval and last-run timestamps."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
        ],
        [
            "name": .string("uzora_get_metric"),
            "description": .string("Get the historical metric series for a probe between two timestamps. Phase 4 returns the shape only; backing SQLite store lands in Phase 5."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "probe": .object([
                        "type": .string("string"),
                        "description": .string("Probe name, e.g. 'disk', 'cpu_temp', 'thermal'."),
                    ]),
                    "from": .object([
                        "type": .string("string"),
                        "description": .string("ISO 8601 timestamp (inclusive)."),
                    ]),
                    "to": .object([
                        "type": .string("string"),
                        "description": .string("ISO 8601 timestamp (inclusive)."),
                    ]),
                ]),
                "required": .array([.string("probe")]),
            ]),
        ],
        [
            "name": .string("uzora_subscribe"),
            "description": .string("Return the Server-Sent Events URL the client should connect to for real-time watchdog events. Phase 4 delegates notifications to SSE; future MCP versions will push tool results natively."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
        ],
    ]
}
