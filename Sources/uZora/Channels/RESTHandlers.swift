import Foundation
import os

/// Request handlers for the four REST endpoints described in DESIGN §3
/// (channels layer). Each handler reads from `StateStore` and returns
/// a JSON `HTTPResponse`.
///
/// Schema design rule: response keys are snake_case so the same JSON is
/// idiomatic for Python / shell consumers without renaming. Swift Codable
/// uses `convertToSnakeCase` strategy.
public struct RESTHandlers: Sendable {

    public let state: StateStore
    /// Phase 6: optional metrics store. When wired, `GET /metrics`
    /// returns persisted samples; when nil the endpoint still answers
    /// but returns an empty series with a "no store wired" note.
    public let metricsStore: MetricsStore?
    /// Write path (Phase 7): the config loader backing `POST /config/probe`.
    /// Optional so read-only test harnesses (and the existing read-only MCP
    /// suite) can build a `RESTHandlers` without one — a reconfigure request
    /// then returns a 500 "config writes not wired" rather than crashing.
    public let configLoader: ConfigLoader?
    /// Global write gate (Phase 7). When `false`, every write endpoint/tool
    /// answers 403 without touching state or disk. Default `true` —
    /// loopback-only personal use; see `MCPConfig.allowWrites`.
    public let allowWrites: Bool
    private let encoder: JSONEncoder
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "rest")

    public init(
        state: StateStore,
        metricsStore: MetricsStore? = nil,
        configLoader: ConfigLoader? = nil,
        allowWrites: Bool = true
    ) {
        self.state = state
        self.metricsStore = metricsStore
        self.configLoader = configLoader
        self.allowWrites = allowWrites
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        enc.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = enc
    }

    // MARK: - GET /status

    public struct StatusResponse: Codable, Sendable {
        public let status: String
        public let uptimeSec: Double
        public let activeAlertsCount: Int
        public let acknowledgedAlertsCount: Int
        public let probesRegistered: Int
        public let powerState: String
        public let writesEnabled: Bool

        public init(
            status: String,
            uptimeSec: Double,
            activeAlertsCount: Int,
            acknowledgedAlertsCount: Int,
            probesRegistered: Int,
            powerState: String,
            writesEnabled: Bool
        ) {
            self.status = status
            self.uptimeSec = uptimeSec
            self.activeAlertsCount = activeAlertsCount
            self.acknowledgedAlertsCount = acknowledgedAlertsCount
            self.probesRegistered = probesRegistered
            self.powerState = powerState
            self.writesEnabled = writesEnabled
        }
    }

    public func status() async -> HTTPResponse {
        let snap = await state.snapshot()
        let ackCount = await state.acknowledgedCount()
        let response = StatusResponse(
            status: "ok",
            uptimeSec: snap.uptimeSeconds,
            activeAlertsCount: snap.activeAlerts.count,
            acknowledgedAlertsCount: ackCount,
            probesRegistered: snap.probes.count,
            powerState: snap.powerState,
            writesEnabled: allowWrites
        )
        return encode(response)
    }

    // MARK: - GET /alerts

    public struct AlertsResponse: Codable, Sendable {
        public let alerts: [Alert]
        public init(alerts: [Alert]) { self.alerts = alerts }
    }

    public func alerts(minSeverity floor: Severity? = nil) async -> HTTPResponse {
        let alerts: [Alert]
        if let floor {
            alerts = await state.activeAlerts(minSeverity: floor)
        } else {
            alerts = await state.activeAlerts()
        }
        return encode(AlertsResponse(alerts: alerts))
    }

    // MARK: - GET /probes

    public struct ProbesResponse: Codable, Sendable {
        public let probes: [StateStore.ProbeInfo]
        public init(probes: [StateStore.ProbeInfo]) { self.probes = probes }
    }

    public func probes() async -> HTTPResponse {
        let probes = await state.probeInventory()
        return encode(ProbesResponse(probes: probes))
    }

    // MARK: - GET /metrics

    /// Phase 6 response: a flat list of samples for the requested
    /// (probe, optional metric name, time range). Keys are snake_case so
    /// the same JSON is idiomatic for Python / shell consumers.
    public struct MetricsResponse: Codable, Sendable {
        public let probe: String?
        public let name: String?
        public let from: Date?
        public let to: Date?
        public let samples: [MetricsStore.Sample]
        public let count: Int
        public let note: String?

        public init(
            probe: String?,
            name: String?,
            from: Date?,
            to: Date?,
            samples: [MetricsStore.Sample],
            note: String? = nil
        ) {
            self.probe = probe
            self.name = name
            self.from = from
            self.to = to
            self.samples = samples
            self.count = samples.count
            self.note = note
        }
    }

    public func metrics(probe: String?, name: String? = nil, from: Date?, to: Date?) async -> HTTPResponse {
        // Default time window: last 1 hour. Per DESIGN §3.2 the endpoint
        // exists primarily for popover-driven graphs which span minutes.
        let now = Date()
        let effectiveTo = to ?? now
        let effectiveFrom = from ?? effectiveTo.addingTimeInterval(-3600)

        guard let probe = probe, !probe.isEmpty else {
            return encode(MetricsResponse(
                probe: nil, name: name,
                from: effectiveFrom, to: effectiveTo,
                samples: [],
                note: "probe= query parameter is required"
            ), status: 400)
        }

        guard let store = metricsStore else {
            return encode(MetricsResponse(
                probe: probe, name: name,
                from: effectiveFrom, to: effectiveTo,
                samples: [],
                note: "metrics store not wired (running headless?)"
            ), status: 200)
        }

        do {
            let samples = try await store.query(
                probe: probe,
                from: effectiveFrom,
                to: effectiveTo,
                name: name
            )
            return encode(MetricsResponse(
                probe: probe, name: name,
                from: effectiveFrom, to: effectiveTo,
                samples: samples
            ), status: 200)
        } catch {
            log.error("metrics query failed: \(String(describing: error), privacy: .public)")
            return HTTPResponse.serverError("metrics query failed: \(error)")
        }
    }

    // MARK: - POST /alerts/ack  (write — acknowledge an alert)

    public struct AckResponse: Codable, Sendable {
        /// `true` only when THIS call performed the ack; `false` for a no-op
        /// re-ack of an already-acknowledged (still-firing) alert.
        public let acknowledged: Bool
        public let id: String
        /// Present + `true` only on a no-op re-ack, so a client can tell
        /// "I just acked it" from "it was already acked". Omitted on a fresh
        /// ack (snake_case encoder emits `already`).
        public let already: Bool?
        public init(acknowledged: Bool, id: String, already: Bool? = nil) {
            self.acknowledged = acknowledged
            self.id = id
            self.already = already
        }
    }

    /// Acknowledge a currently-firing alert by id (UI-state only — does not
    /// touch the OS). The id is taken from the JSON body (`{"id":"disk:/"}`)
    /// rather than the URL path: alert ids embed `:` and `/` (e.g. `disk:/`),
    /// which the exact-match HTTP router cannot carry as a path segment.
    ///
    /// - 403 when writes are globally disabled (`allow_writes = false`).
    /// - 400 when the body is missing / malformed / has no `id`.
    /// - 404 when no active alert carries that id.
    /// - 200 `{acknowledged:true, id:"..."}` on a fresh ack.
    /// - 200 `{acknowledged:false, id:"...", already:true}` on a no-op re-ack
    ///   of an already-acknowledged, still-firing alert (the alert IS acked,
    ///   so 200 not 404 — but `acknowledged:false` signals nothing changed).
    public func acknowledgeAlert(id rawID: String?) async -> HTTPResponse {
        guard allowWrites else { return Self.writesDisabledResponse() }
        guard let id = rawID, !id.isEmpty else {
            return encode(ErrorBody(error: "ack requires a non-empty alert id (body: {\"id\":\"disk:/\"})"), status: 400)
        }
        switch await state.acknowledgeResult(id) {
        case .acknowledged:
            log.info("alert acknowledged via bridge: \(id, privacy: .public)")
            return encode(AckResponse(acknowledged: true, id: id), status: 200)
        case .alreadyAcknowledged:
            // No-op: already acked + still firing. 200 (the alert is acked),
            // but acknowledged=false + already=true so the caller knows this
            // call changed nothing.
            return encode(AckResponse(acknowledged: false, id: id, already: true), status: 200)
        case .notFound:
            return encode(ErrorBody(error: "no active alert with id '\(id)'"), status: 404)
        }
    }

    // MARK: - POST /config/probe  (write — reconfigure a probe)

    public struct ReconfigureResponse: Codable, Sendable {
        public let updated: Bool
        public let probe: String
        public let config: ProbeOverride
        /// Non-fatal advisories — e.g. a threshold supplied for a probe that
        /// ignores thresholds was dropped (not persisted). Empty on a clean
        /// write. Encoded as `warnings` (snake_case strategy is a no-op here).
        public let warnings: [String]
        public init(updated: Bool, probe: String, config: ProbeOverride, warnings: [String]) {
            self.updated = updated
            self.probe = probe
            self.config = config
            self.warnings = warnings
        }
    }

    /// Parsed write request for a single probe override. All knobs optional;
    /// only supplied ones are applied. A field present in the body but `null`
    /// is treated as "not supplied" (keeps the current value).
    ///
    /// `pollIntervalSec` is carried as a raw `Double` (the JSON codec hands
    /// numbers through as Double) and is NOT pre-converted to Int — converting
    /// an absurd value (e.g. 1e22) via `Int(_:)` traps. The conversion +
    /// range check happens inside `reconfigureProbe` through `ConfigSanitizer`,
    /// so an out-of-range value yields a 400 instead of a crash.
    public struct ProbeConfigPatch: Sendable {
        public var enabled: Bool?
        public var warnThreshold: Double?
        public var criticalThreshold: Double?
        /// Raw, un-truncated poll interval (seconds). May be fractional or
        /// absurd; validated before use.
        public var pollIntervalSecRaw: Double?

        /// Convenience for callers (tests, SettingsView) that already have an
        /// `Int`: stores it as the raw Double. Reading back yields the rounded
        /// Int when the raw value is integral + in `Int` range, else nil.
        public var pollIntervalSec: Int? {
            get {
                guard let raw = pollIntervalSecRaw, raw.isFinite,
                      raw >= Double(Int.min), raw <= Double(Int.max) else { return nil }
                return Int(raw.rounded())
            }
            set { pollIntervalSecRaw = newValue.map(Double.init) }
        }

        public init(
            enabled: Bool? = nil,
            warnThreshold: Double? = nil,
            criticalThreshold: Double? = nil,
            pollIntervalSec: Int? = nil
        ) {
            self.enabled = enabled
            self.warnThreshold = warnThreshold
            self.criticalThreshold = criticalThreshold
            self.pollIntervalSecRaw = pollIntervalSec.map(Double.init)
        }

        /// Designated init carrying the raw poll double directly (used by the
        /// JSON/MCP parse path so an absurd value survives to validation).
        public init(
            enabled: Bool?,
            warnThreshold: Double?,
            criticalThreshold: Double?,
            pollIntervalSecRaw: Double?
        ) {
            self.enabled = enabled
            self.warnThreshold = warnThreshold
            self.criticalThreshold = criticalThreshold
            self.pollIntervalSecRaw = pollIntervalSecRaw
        }
    }

    /// Reconfigure one probe's override and persist it to config.toml. The
    /// existing ConfigLoader watcher / observer chain then hot-reloads the
    /// running registry — this handler only loads, mutates one keypath, and
    /// writes.
    ///
    /// - 403 when writes are globally disabled.
    /// - 400 when `probe` is missing or not one of the 10 known names.
    /// - 500 when no ConfigLoader is wired, or the write/load fails.
    /// - 200 `{updated:true, probe, config, warnings}` on success.
    ///
    /// Threshold units mirror `sample-config.toml` / `ProbeRegistry`:
    /// disk = percent-free, cpu_temp/kernel_task/top_cpu = direct, top_mem =
    /// GiB, top_net = MiB/s. The four discrete/multi-dimensional probes
    /// (fan, battery, smart, thermal) IGNORE thresholds — a threshold sent to
    /// one of them is **not persisted** and a `warnings` entry explains why
    /// (enabled / poll_interval_sec are still applied).
    public func reconfigureProbe(name rawName: String?, patch: ProbeConfigPatch) async -> HTTPResponse {
        guard allowWrites else { return Self.writesDisabledResponse() }
        guard let name = rawName, !name.isEmpty else {
            return encode(ErrorBody(error: "reconfigure requires a 'probe' name (one of: \(Self.knownProbeNames.joined(separator: ", ")))"), status: 400)
        }
        guard Self.knownProbeNames.contains(name) else {
            return encode(ErrorBody(error: "unknown probe '\(name)' (known: \(Self.knownProbeNames.joined(separator: ", ")))"), status: 400)
        }
        guard let loader = configLoader else {
            return encode(ErrorBody(error: "config writes not wired (no ConfigLoader)"), status: 500)
        }

        // Load current config (authoritative on-disk state), mutate the one
        // probe's override, write back. Use `current` — the loader keeps it in
        // sync with every prior write/reload, so no extra disk read is needed.
        var config = await loader.current
        var override = Self.override(for: name, in: config.probes)
        var warnings: [String] = []

        if let enabled = patch.enabled {
            override.enabled = enabled
        }

        // ── Validate numeric inputs BEFORE persisting ─────────────────────
        // A bad value (poll_interval_sec=1e22, top_mem warn=-1) would either
        // trap on the Int/UInt64 conversion or persist a poison value that
        // crash-loops the daemon on relaunch. Reject with 400 and DON'T write.
        let ignoresThresholds = Self.thresholdIgnoringProbes.contains(name)

        // poll_interval_sec: finite, integral, 1…86400.
        var validatedPoll: Int?
        if let rawPoll = patch.pollIntervalSecRaw {
            switch ConfigSanitizer.validatedPollInterval(fromDouble: rawPoll) {
            case .success(let sec):
                validatedPoll = sec
            case .failure(let err):
                return encode(ErrorBody(error: err.message), status: 400)
            }
        }

        // Thresholds: only validate for probes that accept them (others have
        // their thresholds dropped with a warning below, so a bad value there
        // is harmless — never persisted).
        if !ignoresThresholds {
            let unit = ConfigSanitizer.thresholdUnit(for: name)
            switch ConfigSanitizer.validate(
                pollIntervalSec: nil, // poll already validated above
                warnThreshold: patch.warnThreshold,
                criticalThreshold: patch.criticalThreshold,
                thresholdUnit: unit
            ) {
            case .success:
                break
            case .failure(let err):
                return encode(ErrorBody(error: err.message), status: 400)
            }
        }

        if let poll = validatedPoll {
            override.pollIntervalSec = poll
        }

        if patch.warnThreshold != nil || patch.criticalThreshold != nil {
            if ignoresThresholds {
                // Honest: do NOT persist a threshold the probe will ignore.
                warnings.append("probe '\(name)' ignores warn_threshold/critical_threshold (discrete or multi-dimensional alerting); threshold value(s) were NOT persisted. enabled/poll_interval_sec still applied.")
            } else {
                if let w = patch.warnThreshold { override.warnThreshold = w }
                if let c = patch.criticalThreshold { override.criticalThreshold = c }
            }
        }

        Self.setOverride(override, for: name, in: &config.probes)

        do {
            try await loader.write(config)
        } catch {
            log.error("config write failed for probe \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            return encode(ErrorBody(error: "config write failed: \(error)"), status: 500)
        }

        log.info("probe reconfigured via bridge: \(name, privacy: .public) enabled=\(override.enabled, privacy: .public)")
        return encode(
            ReconfigureResponse(updated: true, probe: name, config: override, warnings: warnings),
            status: 200
        )
    }

    // MARK: - Probe name ↔ ProbeOverride keypath mapping

    /// The 10 config-known probe names (TOML keys), derived from the single
    /// `ProbesConfig.descriptors` table. The env-gated `synthetic` probe is
    /// intentionally excluded — it has no ProbesConfig entry.
    public static let knownProbeNames: [String] = ProbesConfig.descriptors.map(\.name)

    /// Probes whose alerting is discrete (thermal) or multi-dimensional
    /// (battery, smart, fan) and therefore IGNORE the generic warn/critical
    /// threshold pair. Derived from the descriptor table's `acceptsThresholds`
    /// flag so it can never drift from the registry's threshold mapping.
    public static let thresholdIgnoringProbes: Set<String> = Set(
        ProbesConfig.descriptors.filter { !$0.acceptsThresholds }.map(\.name)
    )

    /// Read the current override for `name` out of a ProbesConfig (descriptor
    /// table; unknown name → a fresh default override).
    static func override(for name: String, in p: ProbesConfig) -> ProbeOverride {
        p[name: name] ?? ProbeOverride()
    }

    /// Write `override` back into the matching ProbesConfig field (descriptor
    /// table; unknown name → no-op).
    static func setOverride(_ o: ProbeOverride, for name: String, in p: inout ProbesConfig) {
        p.setOverride(o, for: name)
    }

    // MARK: - Dispatch helpers

    /// Resolve a REST request to a JSON response. Used by both the HTTP
    /// server route table and the MCP `tools/call` dispatcher.
    public func dispatch(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/status"):
            return await status()
        case ("GET", "/alerts"):
            let floor = request.query["severity"].flatMap { Severity(rawValue: $0) }
            return await alerts(minSeverity: floor)
        case ("GET", "/probes"):
            return await probes()
        case ("GET", "/metrics"):
            let probe = request.query["probe"]
            let name = request.query["name"]
            let from = request.query["from"].flatMap { Self.parseISO8601($0) }
            let to = request.query["to"].flatMap { Self.parseISO8601($0) }
            return await metrics(probe: probe, name: name, from: from, to: to)
        case ("POST", "/alerts/ack"):
            let id = Self.stringField("id", in: request.body)
            return await acknowledgeAlert(id: id)
        case ("POST", "/config/probe"):
            let body = (try? JSONValue.decode(request.body)) ?? .null
            guard case .object(let fields) = body else {
                return encode(ErrorBody(error: "reconfigure requires a JSON object body"), status: 400)
            }
            let name = Self.stringValue(fields["probe"])
            let patch = Self.parsePatch(from: fields)
            return await reconfigureProbe(name: name, patch: patch)
        default:
            return HTTPResponse.notFound("no REST route for \(request.method) \(request.path)")
        }
    }

    // MARK: - Internals

    /// Uniform error envelope so write endpoints emit the same `{error:"…"}`
    /// shape the static `HTTPResponse.badRequest/.notFound` factories produce,
    /// but through the snake_case Codable encoder.
    struct ErrorBody: Codable, Sendable {
        let error: String
    }

    /// Canonical 403 returned by every write surface when `allow_writes` is
    /// off. Built without the instance encoder so it's usable from `static`
    /// contexts and is byte-identical for REST + MCP.
    static func writesDisabledResponse() -> HTTPResponse {
        let body = Data(#"{"error":"writes disabled (set [mcp] allow_writes = true)"}"#.utf8)
        return HTTPResponse(
            status: 403,
            statusText: "Forbidden",
            headers: [("Content-Type", "application/json; charset=utf-8")],
            body: body
        )
    }

    /// Extract a string field from a JSON-object request body. Returns nil if
    /// the body isn't a JSON object or the key is missing / not a string.
    static func stringField(_ key: String, in body: Data) -> String? {
        guard case .object(let fields)? = try? JSONValue.decode(body) else { return nil }
        return stringValue(fields[key])
    }

    /// Unwrap a `JSONValue` to a `String` (nil unless it's `.string`).
    static func stringValue(_ v: JSONValue?) -> String? {
        if case .string(let s)? = v { return s }
        return nil
    }

    /// Build a `ProbeConfigPatch` from a decoded JSON-object body. Numbers
    /// arrive as `.int` or `.double` through the hand-rolled `JSONValue`
    /// codec, so accept both; an explicit JSON `null` is treated as absent.
    static func parsePatch(from fields: [String: JSONValue]) -> ProbeConfigPatch {
        var enabled: Bool?
        if case .bool(let b)? = fields["enabled"] { enabled = b }
        // Carry the raw poll double through UNCONVERTED — `Int(poll.rounded())`
        // traps for absurd values (1e22). Validation/conversion happens in
        // `reconfigureProbe` via ConfigSanitizer (→ 400, not a crash).
        return ProbeConfigPatch(
            enabled: enabled,
            warnThreshold: doubleValue(fields["warn_threshold"]),
            criticalThreshold: doubleValue(fields["critical_threshold"]),
            pollIntervalSecRaw: doubleValue(fields["poll_interval_sec"])
        )
    }

    /// Coerce a numeric `JSONValue` (`.int` or `.double`) to `Double`. Returns
    /// nil for null / absent / non-numeric.
    static func doubleValue(_ v: JSONValue?) -> Double? {
        switch v {
        case .int(let i):    return Double(i)
        case .double(let d): return d
        default:             return nil
        }
    }

    private func encode<T: Codable>(_ value: T, status: Int = 200) -> HTTPResponse {
        do {
            let data = try encoder.encode(value)
            return HTTPResponse.jsonData(data, status: status)
        } catch {
            return HTTPResponse.serverError("json encode failed: \(error)")
        }
    }

    static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
