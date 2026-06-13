import Foundation

/// Top-level user-editable configuration loaded from
/// `~/Library/Application Support/uZora/config.toml`.
///
/// The struct is `Codable` for JSON parity (and for unit testing), but
/// the canonical disk format is TOML — handled by `TOMLValue` mapping
/// methods below rather than the Codable encoder.
public struct UZoraConfig: Sendable, Codable, Equatable {
    public var general: GeneralConfig
    public var http: HTTPConfig
    public var mcp: MCPConfig
    public var probes: ProbesConfig
    public var notifications: NotificationsConfig
    public var powerProfiles: PowerProfilesConfig
    /// Q10 auto-actions — per-action opt-in + global safety knobs.
    public var actions: ActionsConfig

    public init(
        general: GeneralConfig = GeneralConfig(),
        http: HTTPConfig = HTTPConfig(),
        mcp: MCPConfig = MCPConfig(),
        probes: ProbesConfig = ProbesConfig(),
        notifications: NotificationsConfig = NotificationsConfig(),
        powerProfiles: PowerProfilesConfig = PowerProfilesConfig(),
        actions: ActionsConfig = ActionsConfig()
    ) {
        self.general = general
        self.http = http
        self.mcp = mcp
        self.probes = probes
        self.notifications = notifications
        self.powerProfiles = powerProfiles
        self.actions = actions
    }

    public static let `default` = UZoraConfig()
}

public struct GeneralConfig: Sendable, Codable, Equatable {
    /// Register the app with `SMAppService.mainApp` so it relaunches at login.
    public var startAtLogin: Bool
    /// `"system"`, `"en"`, or `"ru"` — drives the runtime locale override.
    public var language: String
    /// `"system"`, `"light"`, `"dark"`.
    public var theme: String
    /// Daily JSONL retention (days). Mirrored to `JSONLEventSink.retentionDays`.
    public var logRetentionDays: Int

    public init(
        startAtLogin: Bool = false,
        language: String = "system",
        theme: String = "system",
        logRetentionDays: Int = 30
    ) {
        self.startAtLogin = startAtLogin
        self.language = language
        self.theme = theme
        self.logRetentionDays = logRetentionDays
    }
}

public struct HTTPConfig: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var port: UInt16

    public init(enabled: Bool = true, port: UInt16 = 39842) {
        self.enabled = enabled
        self.port = port
    }
}

public struct MCPConfig: Sendable, Codable, Equatable {
    public var enabled: Bool
    /// Global write gate for the bridge (Phase 7). When `true` (the default —
    /// loopback-only personal use) the write endpoints/tools (`uzora_ack_alert`,
    /// `uzora_set_probe_config`, `POST /alerts/ack`, `POST /config/probe`) are
    /// live. When `false` they all return 403 / MCP isError. Lightweight
    /// precursor to real per-client auth.
    public var allowWrites: Bool

    public init(enabled: Bool = true, allowWrites: Bool = true) {
        self.enabled = enabled
        self.allowWrites = allowWrites
    }
}

/// Per-probe enable/threshold overrides. All fields optional → uses the
/// probe's built-in default when nil.
public struct ProbeOverride: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var warnThreshold: Double?
    public var criticalThreshold: Double?
    public var pollIntervalSec: Int?

    public init(
        enabled: Bool = true,
        warnThreshold: Double? = nil,
        criticalThreshold: Double? = nil,
        pollIntervalSec: Int? = nil
    ) {
        self.enabled = enabled
        self.warnThreshold = warnThreshold
        self.criticalThreshold = criticalThreshold
        self.pollIntervalSec = pollIntervalSec
    }
}

public struct ProbesConfig: Sendable, Codable, Equatable {
    public var disk: ProbeOverride
    public var cpuTemp: ProbeOverride
    public var thermal: ProbeOverride
    public var battery: ProbeOverride
    public var smart: ProbeOverride
    public var fan: ProbeOverride
    public var kernelTask: ProbeOverride
    public var topCPU: ProbeOverride
    public var topMem: ProbeOverride
    public var topNet: ProbeOverride
    /// Tier-A proactive-diagnosis signal collector (metrics-only, Phase 1).
    public var systemSignals: ProbeOverride

    public init(
        disk: ProbeOverride = ProbeOverride(),
        cpuTemp: ProbeOverride = ProbeOverride(),
        thermal: ProbeOverride = ProbeOverride(),
        battery: ProbeOverride = ProbeOverride(),
        smart: ProbeOverride = ProbeOverride(),
        fan: ProbeOverride = ProbeOverride(),
        kernelTask: ProbeOverride = ProbeOverride(),
        topCPU: ProbeOverride = ProbeOverride(),
        topMem: ProbeOverride = ProbeOverride(),
        topNet: ProbeOverride = ProbeOverride(),
        systemSignals: ProbeOverride = ProbeOverride()
    ) {
        self.disk = disk
        self.cpuTemp = cpuTemp
        self.thermal = thermal
        self.battery = battery
        self.smart = smart
        self.fan = fan
        self.kernelTask = kernelTask
        self.topCPU = topCPU
        self.topMem = topMem
        self.topNet = topNet
        self.systemSignals = systemSignals
    }

    /// One descriptor per config-known probe — the SINGLE source of truth for
    /// the probe-name ↔ `ProbeOverride` field mapping. The TOML key, the
    /// `WritableKeyPath` into this struct, and whether the probe accepts the
    /// generic warn/critical threshold pair are all spelled ONCE here; every
    /// other site (`ProbeRegistry.enabledProbeNames`, `RESTHandlers`
    /// known-names / override / setOverride / threshold-ignoring set) derives
    /// from this table rather than re-listing the ten names.
    ///
    /// `acceptsThresholds == false` ⇒ the probe's alerting is discrete
    /// (thermal) or multi-dimensional (battery/smart/fan) and a single generic
    /// warn/critical can't address it, so a threshold sent to it is dropped.
    /// `@unchecked Sendable`: `WritableKeyPath` isn't `Sendable` in Swift 6,
    /// but every descriptor here is a compile-time-constant key path into a
    /// stored property of the `Sendable` `ProbesConfig` value type — a
    /// stateless path that's safe to read concurrently. The descriptors are
    /// immutable (`let` fields, a `static let` table), so sharing them across
    /// actors carries no data race.
    public struct ProbeDescriptor: @unchecked Sendable {
        public let name: String
        public let path: WritableKeyPath<ProbesConfig, ProbeOverride>
        public let acceptsThresholds: Bool
    }

    /// The eleven descriptors in canonical order. The env-gated `synthetic` probe
    /// is intentionally absent — it has no `ProbesConfig` entry.
    public static let descriptors: [ProbeDescriptor] = [
        ProbeDescriptor(name: "disk",        path: \.disk,       acceptsThresholds: true),
        ProbeDescriptor(name: "cpu_temp",    path: \.cpuTemp,    acceptsThresholds: true),
        ProbeDescriptor(name: "thermal",     path: \.thermal,    acceptsThresholds: false),
        ProbeDescriptor(name: "battery",     path: \.battery,    acceptsThresholds: false),
        ProbeDescriptor(name: "smart",       path: \.smart,      acceptsThresholds: false),
        ProbeDescriptor(name: "fan",         path: \.fan,        acceptsThresholds: false),
        ProbeDescriptor(name: "kernel_task", path: \.kernelTask, acceptsThresholds: true),
        ProbeDescriptor(name: "top_cpu",     path: \.topCPU,     acceptsThresholds: true),
        ProbeDescriptor(name: "top_mem",     path: \.topMem,     acceptsThresholds: true),
        ProbeDescriptor(name: "top_net",     path: \.topNet,     acceptsThresholds: true),
        ProbeDescriptor(name: "system_signals", path: \.systemSignals, acceptsThresholds: false),
    ]

    /// Descriptor for a probe name, or nil if not a config-known probe.
    public static func descriptor(for name: String) -> ProbeDescriptor? {
        descriptors.first { $0.name == name }
    }

    /// Read a probe's override by name via the descriptor table.
    public subscript(name name: String) -> ProbeOverride? {
        guard let d = Self.descriptor(for: name) else { return nil }
        return self[keyPath: d.path]
    }

    /// Write a probe's override by name via the descriptor table (no-op for an
    /// unknown name).
    public mutating func setOverride(_ o: ProbeOverride, for name: String) {
        guard let d = Self.descriptor(for: name) else { return }
        self[keyPath: d.path] = o
    }
}

public struct NotificationsConfig: Sendable, Codable, Equatable {
    /// Minimum severity that triggers a banner (info/warn/critical). Below
    /// the floor the alert still flows to JSONL/SSE/MCP but no UN banner.
    public var bannerSeverityFloor: Severity
    /// Suppress warn-level banners while Focus is active. Critical always
    /// pierces regardless of this flag.
    public var respectFocus: Bool

    public init(
        bannerSeverityFloor: Severity = .warn,
        respectFocus: Bool = true
    ) {
        self.bannerSeverityFloor = bannerSeverityFloor
        self.respectFocus = respectFocus
    }
}

/// Per-PowerState override for poll multipliers and severity floors. All
/// fields optional → fall back to the hard-coded `PowerProfile.defaultMapping`.
public struct PowerProfileOverride: Sendable, Codable, Equatable {
    public var pollMultiplier: Double?
    public var alertSeverityFloor: Severity?

    public init(pollMultiplier: Double? = nil, alertSeverityFloor: Severity? = nil) {
        self.pollMultiplier = pollMultiplier
        self.alertSeverityFloor = alertSeverityFloor
    }
}

// MARK: - Actions (Q10 auto-actions)

/// Per-action config: opt-in auto-run flag (Q3 — default OFF for every
/// action) plus an optional override of the default alert binding (Q6
/// hybrid). All fields default to "safe / use built-in mapping".
public struct ActionOverride: Sendable, Codable, Equatable {
    /// Opt-in to FULLY-AUTOMATIC execution. Default `false` for every
    /// action (Q3). The notification "Run" button (confirmed trigger) works
    /// regardless of this flag — the user is clicking it themselves.
    public var autoEnabled: Bool
    /// Override which probe fires this action (nil → descriptor default,
    /// `"disk"`). Q6 config-override.
    public var probe: String?
    /// Override the minimum severity that makes this action eligible
    /// (nil → descriptor default, `.warn`). Q6 config-override.
    public var severityFloor: Severity?

    public init(
        autoEnabled: Bool = false,
        probe: String? = nil,
        severityFloor: Severity? = nil
    ) {
        self.autoEnabled = autoEnabled
        self.probe = probe
        self.severityFloor = severityFloor
    }
}

/// `[actions]` config section: per-action opt-in + the global PolicyEngine
/// safety knobs. Every safety mechanism is a toggle + params (Q4) EXCEPT
/// the audit log, which is always-on and therefore has no toggle here.
///
/// Defaults (Q4): cool_down_minutes=30, rate_limit_per_hour=6,
/// power_gate=true (skip auto on battery), focus_gate=true,
/// dry_run_preview=true. Every action `auto_enabled=false` (Q3).
public struct ActionsConfig: Sendable, Codable, Equatable {
    // ── Per-action opt-in (one field per MVP action; the descriptor table
    //    below is the single source of truth for the id ↔ field mapping). ──
    public var pruneApfsSnapshots: ActionOverride
    public var clearDerivedData: ActionOverride
    public var brewCleanup: ActionOverride
    public var clearUserCaches: ActionOverride

    // ── Global safety toggles + params (each configurable, Q4). ──
    /// Cool-down toggle (don't repeat the same action within N minutes).
    public var coolDownEnabled: Bool
    /// Cool-down window in minutes. Sanitized into a sane range.
    public var coolDownMinutes: Int
    /// Rate-limit toggle (cap auto-runs per rolling hour).
    public var rateLimitEnabled: Bool
    /// Max auto-runs per rolling hour. Sanitized into a sane range.
    public var rateLimitPerHour: Int
    /// Power gate: skip AUTO actions while on battery (confirmed runs are
    /// unaffected). Default true.
    public var powerGate: Bool
    /// Focus gate: skip AUTO actions while Focus is active. Default true.
    public var focusGate: Bool
    /// Compute + surface a dry-run preview before executing. Default true.
    public var dryRunPreview: Bool

    public init(
        pruneApfsSnapshots: ActionOverride = ActionOverride(),
        clearDerivedData: ActionOverride = ActionOverride(),
        brewCleanup: ActionOverride = ActionOverride(),
        clearUserCaches: ActionOverride = ActionOverride(),
        coolDownEnabled: Bool = true,
        coolDownMinutes: Int = 30,
        rateLimitEnabled: Bool = true,
        rateLimitPerHour: Int = 6,
        powerGate: Bool = true,
        focusGate: Bool = true,
        dryRunPreview: Bool = true
    ) {
        self.pruneApfsSnapshots = pruneApfsSnapshots
        self.clearDerivedData = clearDerivedData
        self.brewCleanup = brewCleanup
        self.clearUserCaches = clearUserCaches
        self.coolDownEnabled = coolDownEnabled
        self.coolDownMinutes = coolDownMinutes
        self.rateLimitEnabled = rateLimitEnabled
        self.rateLimitPerHour = rateLimitPerHour
        self.powerGate = powerGate
        self.focusGate = focusGate
        self.dryRunPreview = dryRunPreview
    }

    /// One descriptor per config-known action — the SINGLE source of truth
    /// for the action-id ↔ `ActionOverride` field mapping (mirrors
    /// `ProbesConfig.descriptors`). Every other site derives from this
    /// table rather than re-listing the four ids.
    ///
    /// `@unchecked Sendable`: same rationale as `ProbesConfig.ProbeDescriptor`
    /// — each `WritableKeyPath` is a compile-time-constant path into a stored
    /// property of the `Sendable` value type, immutable + safe to share.
    public struct ActionDescriptorKey: @unchecked Sendable {
        public let id: String
        public let path: WritableKeyPath<ActionsConfig, ActionOverride>
    }

    /// The four MVP action ids in canonical order.
    public static let descriptors: [ActionDescriptorKey] = [
        ActionDescriptorKey(id: "prune_apfs_snapshots", path: \.pruneApfsSnapshots),
        ActionDescriptorKey(id: "clear_derived_data",   path: \.clearDerivedData),
        ActionDescriptorKey(id: "brew_cleanup",         path: \.brewCleanup),
        ActionDescriptorKey(id: "clear_user_caches",    path: \.clearUserCaches),
    ]

    /// Descriptor for an action id, or nil if unknown.
    public static func descriptor(for id: String) -> ActionDescriptorKey? {
        descriptors.first { $0.id == id }
    }

    /// Read an action's override by id via the descriptor table.
    public subscript(id id: String) -> ActionOverride? {
        guard let d = Self.descriptor(for: id) else { return nil }
        return self[keyPath: d.path]
    }

    /// Write an action's override by id via the descriptor table (no-op for
    /// an unknown id).
    public mutating func setOverride(_ o: ActionOverride, for id: String) {
        guard let d = Self.descriptor(for: id) else { return }
        self[keyPath: d.path] = o
    }
}

public struct PowerProfilesConfig: Sendable, Codable, Equatable {
    public var acOpen: PowerProfileOverride
    public var acClosed: PowerProfileOverride
    public var batteryOpen: PowerProfileOverride
    public var batteryClosed: PowerProfileOverride
    public var focus: PowerProfileOverride

    public init(
        acOpen: PowerProfileOverride = PowerProfileOverride(),
        acClosed: PowerProfileOverride = PowerProfileOverride(),
        batteryOpen: PowerProfileOverride = PowerProfileOverride(),
        batteryClosed: PowerProfileOverride = PowerProfileOverride(),
        focus: PowerProfileOverride = PowerProfileOverride()
    ) {
        self.acOpen = acOpen
        self.acClosed = acClosed
        self.batteryOpen = batteryOpen
        self.batteryClosed = batteryClosed
        self.focus = focus
    }
}

// MARK: - TOML coding

extension UZoraConfig {

    /// Decode from a TOML document string. Missing keys fall back to
    /// the type's `default` value.
    public static func fromTOML(_ text: String) throws -> UZoraConfig {
        let parser = TOMLParser()
        let root = try parser.parse(text)
        return UZoraConfig(toml: root)
    }

    /// Encode to a TOML document string suitable for writing to disk.
    public func toTOML() -> String {
        TOMLEmitter().emit(toTOMLValue())
    }

    /// Build a TOMLValue tree mirroring the typed struct.
    public func toTOMLValue() -> TOMLValue {
        .table([
            ("general", .table([
                ("start_at_login", .bool(general.startAtLogin)),
                ("language", .string(general.language)),
                ("theme", .string(general.theme)),
                ("log_retention_days", .integer(Int64(general.logRetentionDays))),
            ])),
            ("http", .table([
                ("enabled", .bool(http.enabled)),
                ("port", .integer(Int64(http.port))),
            ])),
            ("mcp", .table([
                ("enabled", .bool(mcp.enabled)),
                ("allow_writes", .bool(mcp.allowWrites)),
            ])),
            ("notifications", .table([
                ("banner_severity_floor", .string(notifications.bannerSeverityFloor.rawValue)),
                ("respect_focus", .bool(notifications.respectFocus)),
            ])),
            ("probes", .table([
                ("disk", probes.disk.toTOMLValue()),
                ("cpu_temp", probes.cpuTemp.toTOMLValue()),
                ("thermal", probes.thermal.toTOMLValue()),
                ("battery", probes.battery.toTOMLValue()),
                ("smart", probes.smart.toTOMLValue()),
                ("fan", probes.fan.toTOMLValue()),
                ("kernel_task", probes.kernelTask.toTOMLValue()),
                ("top_cpu", probes.topCPU.toTOMLValue()),
                ("top_mem", probes.topMem.toTOMLValue()),
                ("top_net", probes.topNet.toTOMLValue()),
                ("system_signals", probes.systemSignals.toTOMLValue()),
            ])),
            ("power_profiles", .table([
                ("ac_open", powerProfiles.acOpen.toTOMLValue()),
                ("ac_closed", powerProfiles.acClosed.toTOMLValue()),
                ("battery_open", powerProfiles.batteryOpen.toTOMLValue()),
                ("battery_closed", powerProfiles.batteryClosed.toTOMLValue()),
                ("focus", powerProfiles.focus.toTOMLValue()),
            ])),
            ("actions", .table([
                ("cool_down_enabled", .bool(actions.coolDownEnabled)),
                ("cool_down_minutes", .integer(Int64(actions.coolDownMinutes))),
                ("rate_limit_enabled", .bool(actions.rateLimitEnabled)),
                ("rate_limit_per_hour", .integer(Int64(actions.rateLimitPerHour))),
                ("power_gate", .bool(actions.powerGate)),
                ("focus_gate", .bool(actions.focusGate)),
                ("dry_run_preview", .bool(actions.dryRunPreview)),
                ("prune_apfs_snapshots", actions.pruneApfsSnapshots.toTOMLValue()),
                ("clear_derived_data", actions.clearDerivedData.toTOMLValue()),
                ("brew_cleanup", actions.brewCleanup.toTOMLValue()),
                ("clear_user_caches", actions.clearUserCaches.toTOMLValue()),
            ])),
        ])
    }

    /// Construct a typed config from a parsed TOML value (with default
    /// fall-back for any missing field). Never throws — malformed values
    /// silently degrade to defaults so a slightly corrupt config doesn't
    /// kill the agent.
    public init(toml: TOMLValue) {
        var c = UZoraConfig.default

        if let g = toml.value(forKey: "general") {
            if let v = g.value(forKey: "start_at_login")?.asBool { c.general.startAtLogin = v }
            if let v = g.value(forKey: "language")?.asString { c.general.language = v }
            if let v = g.value(forKey: "theme")?.asString { c.general.theme = v }
            if let v = g.value(forKey: "log_retention_days")?.asInt { c.general.logRetentionDays = Int(v) }
        }

        if let h = toml.value(forKey: "http") {
            if let v = h.value(forKey: "enabled")?.asBool { c.http.enabled = v }
            if let v = h.value(forKey: "port")?.asInt { c.http.port = UInt16(clamping: v) }
        }

        if let m = toml.value(forKey: "mcp") {
            if let v = m.value(forKey: "enabled")?.asBool { c.mcp.enabled = v }
            if let v = m.value(forKey: "allow_writes")?.asBool { c.mcp.allowWrites = v }
        }

        if let n = toml.value(forKey: "notifications") {
            if let v = n.value(forKey: "banner_severity_floor")?.asString, let sev = Severity(rawValue: v) {
                c.notifications.bannerSeverityFloor = sev
            }
            if let v = n.value(forKey: "respect_focus")?.asBool {
                c.notifications.respectFocus = v
            }
        }

        if let p = toml.value(forKey: "probes") {
            c.probes.disk = ProbeOverride(toml: p.value(forKey: "disk"))
            c.probes.cpuTemp = ProbeOverride(toml: p.value(forKey: "cpu_temp"))
            c.probes.thermal = ProbeOverride(toml: p.value(forKey: "thermal"))
            c.probes.battery = ProbeOverride(toml: p.value(forKey: "battery"))
            c.probes.smart = ProbeOverride(toml: p.value(forKey: "smart"))
            c.probes.fan = ProbeOverride(toml: p.value(forKey: "fan"))
            c.probes.kernelTask = ProbeOverride(toml: p.value(forKey: "kernel_task"))
            c.probes.topCPU = ProbeOverride(toml: p.value(forKey: "top_cpu"))
            c.probes.topMem = ProbeOverride(toml: p.value(forKey: "top_mem"))
            c.probes.topNet = ProbeOverride(toml: p.value(forKey: "top_net"))
            c.probes.systemSignals = ProbeOverride(toml: p.value(forKey: "system_signals"))
        }

        if let pp = toml.value(forKey: "power_profiles") {
            c.powerProfiles.acOpen = PowerProfileOverride(toml: pp.value(forKey: "ac_open"))
            c.powerProfiles.acClosed = PowerProfileOverride(toml: pp.value(forKey: "ac_closed"))
            c.powerProfiles.batteryOpen = PowerProfileOverride(toml: pp.value(forKey: "battery_open"))
            c.powerProfiles.batteryClosed = PowerProfileOverride(toml: pp.value(forKey: "battery_closed"))
            c.powerProfiles.focus = PowerProfileOverride(toml: pp.value(forKey: "focus"))
        }

        if let a = toml.value(forKey: "actions") {
            if let v = a.value(forKey: "cool_down_enabled")?.asBool { c.actions.coolDownEnabled = v }
            // Numeric safety params are clamped at the READ boundary so a
            // hand-edited config can't disable safety by overflow / negative
            // (ConfigSanitizer logs + coerces). The write boundary validates
            // separately.
            if let v = a.value(forKey: "cool_down_minutes")?.asInt {
                c.actions.coolDownMinutes = ConfigSanitizer.clampCoolDownMinutes(Int(v))
            }
            if let v = a.value(forKey: "rate_limit_enabled")?.asBool { c.actions.rateLimitEnabled = v }
            if let v = a.value(forKey: "rate_limit_per_hour")?.asInt {
                c.actions.rateLimitPerHour = ConfigSanitizer.clampRateLimitPerHour(Int(v))
            }
            if let v = a.value(forKey: "power_gate")?.asBool { c.actions.powerGate = v }
            if let v = a.value(forKey: "focus_gate")?.asBool { c.actions.focusGate = v }
            if let v = a.value(forKey: "dry_run_preview")?.asBool { c.actions.dryRunPreview = v }
            c.actions.pruneApfsSnapshots = ActionOverride(toml: a.value(forKey: "prune_apfs_snapshots"))
            c.actions.clearDerivedData = ActionOverride(toml: a.value(forKey: "clear_derived_data"))
            c.actions.brewCleanup = ActionOverride(toml: a.value(forKey: "brew_cleanup"))
            c.actions.clearUserCaches = ActionOverride(toml: a.value(forKey: "clear_user_caches"))
        }

        self = c
    }
}

extension ProbeOverride {
    public init(toml: TOMLValue?) {
        var o = ProbeOverride()
        guard let t = toml else { self = o; return }
        if let v = t.value(forKey: "enabled")?.asBool { o.enabled = v }
        if let v = t.value(forKey: "warn_threshold")?.asDouble { o.warnThreshold = v }
        if let v = t.value(forKey: "critical_threshold")?.asDouble { o.criticalThreshold = v }
        if let v = t.value(forKey: "poll_interval_sec")?.asInt { o.pollIntervalSec = Int(v) }
        self = o
    }

    public func toTOMLValue() -> TOMLValue {
        var entries: [(String, TOMLValue)] = [
            ("enabled", .bool(enabled)),
        ]
        if let w = warnThreshold { entries.append(("warn_threshold", .double(w))) }
        if let c = criticalThreshold { entries.append(("critical_threshold", .double(c))) }
        if let p = pollIntervalSec { entries.append(("poll_interval_sec", .integer(Int64(p)))) }
        return .table(entries)
    }
}

extension PowerProfileOverride {
    public init(toml: TOMLValue?) {
        var o = PowerProfileOverride()
        guard let t = toml else { self = o; return }
        if let v = t.value(forKey: "poll_multiplier")?.asDouble { o.pollMultiplier = v }
        if let v = t.value(forKey: "alert_severity_floor")?.asString,
           let sev = Severity(rawValue: v) {
            o.alertSeverityFloor = sev
        }
        self = o
    }

    public func toTOMLValue() -> TOMLValue {
        var entries: [(String, TOMLValue)] = []
        if let m = pollMultiplier { entries.append(("poll_multiplier", .double(m))) }
        if let s = alertSeverityFloor { entries.append(("alert_severity_floor", .string(s.rawValue))) }
        return .table(entries)
    }
}

extension ActionOverride {
    public init(toml: TOMLValue?) {
        var o = ActionOverride()
        guard let t = toml else { self = o; return }
        if let v = t.value(forKey: "auto_enabled")?.asBool { o.autoEnabled = v }
        if let v = t.value(forKey: "probe")?.asString, !v.isEmpty { o.probe = v }
        if let v = t.value(forKey: "severity_floor")?.asString,
           let sev = Severity(rawValue: v) {
            o.severityFloor = sev
        }
        self = o
    }

    public func toTOMLValue() -> TOMLValue {
        var entries: [(String, TOMLValue)] = [
            ("auto_enabled", .bool(autoEnabled)),
        ]
        if let p = probe { entries.append(("probe", .string(p))) }
        if let s = severityFloor { entries.append(("severity_floor", .string(s.rawValue))) }
        return .table(entries)
    }
}
