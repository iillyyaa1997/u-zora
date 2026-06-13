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

        case "uzora_list_actions":
            // Read-only (Q8): available actions + their auto-enabled status +
            // recent audit-log entries. The LLM can ADVISE ("disk full —
            // there's a prune_apfs_snapshots action") but cannot execute;
            // there is intentionally no uzora_run_action tool this iteration.
            let resp = await rest.actions()
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

        case "uzora_list_findings":
            // Read-only (Phase 5, plan D6): the proactive-diagnosis findings —
            // each a *diagnosed likely cause* (detector, subject, severity,
            // confidence, plain-language explanation, suggested action),
            // distinct from the raw probe alerts on uzora_list_alerts. Parses
            // the optional `severity` floor exactly like uzora_list_alerts.
            var floor: Severity? = nil
            if case .object(let args) = arguments,
               case .string(let s)? = args["severity"] {
                floor = Severity(rawValue: s)
            }
            let resp = await rest.findings(minSeverity: floor)
            return MCPTools.wrap(resp)

        case "uzora_get_verdict":
            // Read-only (Phase 5, plan D5/D6): uZora's one-line aggregate
            // health verdict (good / watch / degraded / problem) + the driving
            // findings — the proactive "is my Mac OK and why" answer.
            let resp = await rest.verdict()
            return MCPTools.wrap(resp)

        case "uzora_ack_alert":
            // Write: acknowledge a firing alert. Single-sourced through the
            // same REST handler `POST /alerts/ack` uses; the handler itself
            // enforces the `allow_writes` gate (403 → isError) and 404 for an
            // unknown id.
            var id: String? = nil
            if case .object(let args) = arguments,
               case .string(let s)? = args["id"] {
                id = s
            }
            let resp = await rest.acknowledgeAlert(id: id)
            return MCPTools.wrap(resp)

        case "uzora_set_probe_config":
            // Write: reconfigure one probe and persist to config.toml (the
            // existing hot-reload observer then applies it). Same handler as
            // `POST /config/probe`; the handler enforces `allow_writes` (403),
            // unknown-probe (400), and the fan/battery/smart/thermal
            // threshold-drop `warnings`.
            var probe: String? = nil
            var patch = RESTHandlers.ProbeConfigPatch()
            if case .object(let args) = arguments {
                if case .string(let s)? = args["probe"] { probe = s }
                if case .bool(let b)? = args["enabled"] { patch.enabled = b }
                patch.warnThreshold = MCPTools.number(args["warn_threshold"])
                patch.criticalThreshold = MCPTools.number(args["critical_threshold"])
                // Carry the raw poll double UNCONVERTED — `Int(poll.rounded())`
                // traps for absurd values (1e22). `reconfigureProbe` validates
                // it via ConfigSanitizer and returns an isError result for
                // out-of-range input rather than crashing the daemon.
                patch.pollIntervalSecRaw = MCPTools.number(args["poll_interval_sec"])
            }
            let resp = await rest.reconfigureProbe(name: probe, patch: patch)
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

    /// Coerce an MCP argument `JSONValue` (`.int` or `.double`) to `Double`.
    /// nil for null / absent / non-numeric.
    static func number(_ v: JSONValue?) -> Double? {
        switch v {
        case .int(let i):    return Double(i)
        case .double(let d): return d
        default:             return nil
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

    /// Per-instance tool list. Read tools are always present; the two write
    /// tools are **always listed** (so a client gets a clear 403 isError
    /// rather than an "unknown tool" error) but their description notes when
    /// writes are currently disabled. The gate itself lives in the REST
    /// handlers — listing here is purely advisory.
    public func listSchemas() -> [[String: JSONValue]] {
        MCPTools.readSchemas + MCPTools.writeSchemas(allowWrites: rest.allowWrites)
    }

    /// The read-only tools (always available).
    public static let readSchemas: [[String: JSONValue]] = [
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
            "name": .string("uzora_list_actions"),
            "description": .string("Read-only: list uZora's reversible cleanup actions (e.g. prune_apfs_snapshots, clear_derived_data, brew_cleanup, clear_user_caches), each with its auto-enabled status, related probe/severity, reversibility/sudo/caution flags, the global safety policy (cool-down, rate-limit, power/Focus gates), and recent audit-log entries. uZora does NOT execute actions via MCP — use this to ADVISE the user (e.g. 'disk is full; there is a prune_apfs_snapshots action you can enable')."),
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
            "name": .string("uzora_list_findings"),
            "description": .string("List the proactive-diagnosis findings: each is a likely-cause diagnosis (detector, subject, severity, confidence, plain-language explanation, suggested action), distinct from raw probe alerts. Optionally filter by minimum severity."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "severity": .object([
                        "type": .string("string"),
                        "enum": .array([.string("info"), .string("warn"), .string("critical")]),
                        "description": .string("Filter to findings at or above this severity."),
                    ]),
                ]),
            ]),
        ],
        [
            "name": .string("uzora_get_verdict"),
            "description": .string("Return uZora's one-line aggregate health verdict (good / watch / degraded / problem) plus the driving findings — the proactive 'is my Mac OK and why' answer."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
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

    /// The two write tools. Listed regardless of `allowWrites` so clients see
    /// a stable tool set and get a clear 403 isError when writes are off; the
    /// description carries the disabled hint.
    public static func writeSchemas(allowWrites: Bool) -> [[String: JSONValue]] {
        let gate = allowWrites
            ? ""
            : " NOTE: writes are currently DISABLED (set [mcp] allow_writes = true in config.toml); calling this returns an error."
        return [
            [
                "name": .string("uzora_ack_alert"),
                "description": .string("Acknowledge (dismiss) a currently-firing alert by id. UI-state only — does NOT touch the OS, only hides the alert from the active set until it escalates or clears. Get ids from uzora_list_alerts (the `id` field, e.g. 'disk:/')." + gate),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("Alert id to acknowledge, e.g. 'disk:/' or 'cpu_temp:package'."),
                        ]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
            ],
            [
                "name": .string("uzora_set_probe_config"),
                "description": .string("Change one probe's configuration (enabled / thresholds / poll interval), persisted to config.toml and hot-reloaded. Threshold units: disk=percent-free, cpu_temp/kernel_task/top_cpu=direct (°C or CPU%), top_mem=GiB, top_net=MiB/s. fan/battery/smart/thermal IGNORE thresholds (enabled + poll only) — a threshold sent to those is not persisted and a warning is returned." + gate),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "probe": .object([
                            "type": .string("string"),
                            "enum": .array(RESTHandlers.knownProbeNames.map { .string($0) }),
                            "description": .string("Probe to reconfigure (one of the 10 known probe names)."),
                        ]),
                        "enabled": .object([
                            "type": .string("boolean"),
                            "description": .string("Enable or disable the probe."),
                        ]),
                        "warn_threshold": .object([
                            "type": .string("number"),
                            "description": .string("Warn threshold in the probe's units (ignored by fan/battery/smart/thermal)."),
                        ]),
                        "critical_threshold": .object([
                            "type": .string("number"),
                            "description": .string("Critical threshold in the probe's units (ignored by fan/battery/smart/thermal)."),
                        ]),
                        "poll_interval_sec": .object([
                            "type": .string("integer"),
                            "description": .string("Base poll cadence in seconds (the active power profile still multiplies this)."),
                        ]),
                    ]),
                    "required": .array([.string("probe")]),
                ]),
            ],
        ]
    }
}
