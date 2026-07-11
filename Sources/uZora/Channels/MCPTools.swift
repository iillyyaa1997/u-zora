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

    /// Invoke a tool. `auth` carries the write-tier auth material
    /// (Authorization / Origin / Host) lifted from the originating HTTP request
    /// by `MCPServer.handle`; it is threaded into the two WRITE tools so their
    /// REST handlers can enforce the B1b bearer + loopback gate. Read tools
    /// ignore it (reads are never gated). Defaulted to an empty context so the
    /// existing in-process test call sites (which invoke MCPTools directly, with
    /// no wired `BridgeAuth`) compile + stay unauthenticated.
    public func invoke(name: String, arguments: JSONValue, auth: WriteAuthContext = WriteAuthContext()) async throws -> JSONValue {
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
            var name: String? = nil
            var fromDate: Date? = nil
            var toDate: Date? = nil
            if case .object(let args) = arguments {
                if case .string(let s)? = args["probe"] { probe = s }
                // B1a: MCP parity with REST — `name` selects one metric series
                // within a probe (e.g. probe=battery, name=charge_pct). REST
                // already honoured it; the MCP tool previously dropped it.
                if case .string(let s)? = args["name"]  { name = s }
                if case .string(let s)? = args["from"] { fromDate = RESTHandlers.parseISO8601(s) }
                if case .string(let s)? = args["to"]   { toDate   = RESTHandlers.parseISO8601(s) }
            }
            let resp = await rest.metrics(probe: probe, name: name, from: fromDate, to: toDate)
            return MCPTools.wrap(resp)

        case "uzora_list_metrics":
            // Read-only (B1a, plan D-L5): enumerate the distinct metric series
            // actually present (source: MetricsStore.distinctSeries()) so an LLM
            // stops guessing name strings. Single-sourced through the same REST
            // handler `GET /metrics/catalog` uses.
            let resp = await rest.metricsCatalog()
            return MCPTools.wrap(resp)

        case "uzora_get_layout":
            // Read-only (B1a, plan D-C4): the CURRENT effective popover layout
            // (blocks + tiles with visibility/order), resolved from the live
            // config preset + optional customized layout JSON. Same handler as
            // `GET /layout`; no write path.
            let resp = await rest.layout()
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
            // same REST handler `POST /alerts/ack` uses; the handler enforces
            // the `allow_writes` gate (403 → isError), the B1b bearer + loopback
            // gate (401/403 → isError, using the threaded `auth`), and 404 for
            // an unknown id.
            var id: String? = nil
            if case .object(let args) = arguments,
               case .string(let s)? = args["id"] {
                id = s
            }
            let resp = await rest.acknowledgeAlert(id: id, auth: auth)
            return MCPTools.wrap(resp)

        case "uzora_set_probe_config":
            // Write: reconfigure one probe and persist to config.toml (the
            // existing hot-reload observer then applies it). Same handler as
            // `POST /config/probe`; the handler enforces `allow_writes` (403),
            // the B1b bearer + loopback gate (401/403, via `auth`),
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
            let resp = await rest.reconfigureProbe(name: probe, patch: patch, auth: auth)
            return MCPTools.wrap(resp)

        case "uzora_subscribe":
            // MCP notifications-over-SSE-transport is deferred; until then the
            // tool returns the real `GET /stream` SSE URL so the LLM client
            // knows where to subscribe. B1a: `/stream` now carries the
            // diagnosis fan-out too, so advertise ALL event names — the three
            // watchdog events PLUS the new diagnosis events (plan D-L4).
            let url = "\(httpBaseURL)/stream"
            let events: [JSONValue] = [
                "appeared", "escalated", "cleared",
                "diagnosed", "rediagnosed", "resolved", "verdict_changed",
            ].map { .string($0) }
            return .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Connect to \(url) (Server-Sent Events) for real-time uZora updates. Watchdog alert events: appeared / escalated / cleared. Diagnosis events (plan D-L4): diagnosed / rediagnosed / resolved (per finding) and verdict_changed (aggregate good/watch/degraded/problem transitions). MCP notifications-over-transport are deferred to a later phase; subscribe to the SSE URL instead.")
                    ])
                ]),
                "structuredContent": .object([
                    "sse_url": .string(url),
                    "transport": .string("server-sent-events"),
                    "events": .array(events),
                    "note": .string("MCP notifications-over-transport deferred; subscribe to the SSE URL. /stream carries watchdog alert events + diagnosis findings/verdict events.")
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
            "description": .string("Get the historical metric series for a probe between two timestamps. Optionally narrow to a single metric series with `name` (use uzora_list_metrics to discover the (probe, name) pairs)."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "probe": .object([
                        "type": .string("string"),
                        "description": .string("Probe name, e.g. 'disk', 'cpu_temp', 'thermal'."),
                    ]),
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Optional metric series name within the probe, e.g. 'temp_c', 'free_pct', 'charge_pct'. Omit for all of the probe's series. Discover valid names via uzora_list_metrics."),
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
            "name": .string("uzora_list_metrics"),
            "description": .string("List the available metric series — the distinct (probe, name) pairs actually recorded in the store, each with its sample count and most-recent value/timestamp. Use this to discover exact metric names for uzora_get_metric instead of guessing."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
        ],
        [
            "name": .string("uzora_get_layout"),
            "description": .string("Read-only: return the CURRENT effective menu-bar popover layout — the ordered content blocks and System-overview tiles, each with its visibility — resolved from the active preset (minimal/balanced/diagnosis/power) plus any customized layout JSON. Does not modify anything."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
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
            "description": .string("Return the Server-Sent Events URL to connect to for real-time updates over GET /stream. Carries watchdog alert events (appeared / escalated / cleared) AND diagnosis events (diagnosed / rediagnosed / resolved per finding, plus verdict_changed on aggregate health transitions). MCP notifications-over-transport are deferred; subscribe to the SSE URL instead."),
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
        // B1b: every write now additionally requires the bridge bearer token,
        // presented on the HTTP request as `Authorization: Bearer <token>` (the
        // token lives in ~/Library/Application Support/uZora/bridge-token; B5
        // surfaces it in Settings). Reads stay unauthenticated on loopback.
        let bearer = " Requires the bridge bearer token (HTTP header `Authorization: Bearer <token>`); a missing/invalid token returns a 401 error."
        return [
            [
                "name": .string("uzora_ack_alert"),
                "description": .string("Acknowledge (dismiss) a currently-firing alert by id. UI-state only — does NOT touch the OS, only hides the alert from the active set until it escalates or clears. Get ids from uzora_list_alerts (the `id` field, e.g. 'disk:/')." + bearer + gate),
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
                "description": .string("Change one probe's configuration (enabled / thresholds / poll interval), persisted to config.toml and hot-reloaded. Threshold units: disk=percent-free, cpu_temp/kernel_task/top_cpu=direct (°C or CPU%), top_mem=GiB, top_net=MiB/s. fan/battery/smart/thermal IGNORE thresholds (enabled + poll only) — a threshold sent to those is not persisted and a warning is returned." + bearer + gate),
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
