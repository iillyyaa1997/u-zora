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

    public init(
        general: GeneralConfig = GeneralConfig(),
        http: HTTPConfig = HTTPConfig(),
        mcp: MCPConfig = MCPConfig(),
        probes: ProbesConfig = ProbesConfig(),
        notifications: NotificationsConfig = NotificationsConfig(),
        powerProfiles: PowerProfilesConfig = PowerProfilesConfig()
    ) {
        self.general = general
        self.http = http
        self.mcp = mcp
        self.probes = probes
        self.notifications = notifications
        self.powerProfiles = powerProfiles
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
        topNet: ProbeOverride = ProbeOverride()
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

    /// The ten descriptors in canonical order. The env-gated `synthetic` probe
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
            ])),
            ("power_profiles", .table([
                ("ac_open", powerProfiles.acOpen.toTOMLValue()),
                ("ac_closed", powerProfiles.acClosed.toTOMLValue()),
                ("battery_open", powerProfiles.batteryOpen.toTOMLValue()),
                ("battery_closed", powerProfiles.batteryClosed.toTOMLValue()),
                ("focus", powerProfiles.focus.toTOMLValue()),
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
        }

        if let pp = toml.value(forKey: "power_profiles") {
            c.powerProfiles.acOpen = PowerProfileOverride(toml: pp.value(forKey: "ac_open"))
            c.powerProfiles.acClosed = PowerProfileOverride(toml: pp.value(forKey: "ac_closed"))
            c.powerProfiles.batteryOpen = PowerProfileOverride(toml: pp.value(forKey: "battery_open"))
            c.powerProfiles.batteryClosed = PowerProfileOverride(toml: pp.value(forKey: "battery_closed"))
            c.powerProfiles.focus = PowerProfileOverride(toml: pp.value(forKey: "focus"))
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
