import SwiftUI
import AppKit
import ServiceManagement
@preconcurrency import UserNotifications  // see NotificationCenter.swift — cross-SDK Sendable gap

/// Full Settings scene. Tabs: General / Probes / Notifications /
/// MCP & API / Logs. Each control is two-way bound to the live
/// `ConfigLoader.current`; writes flow back through
/// `ConfigBindings.update`, which calls `ConfigLoader.write(...)`.
public struct SettingsView: View {
    @ObservedObject var bindings: ConfigBindings
    @ObservedObject var state: UIState

    public init(bindings: ConfigBindings, state: UIState) {
        self.bindings = bindings
        self.state = state
    }

    public var body: some View {
        TabView {
            GeneralTab(bindings: bindings)
                .tabItem {
                    Label(String(localized: "General", defaultValue: "General"), systemImage: "gearshape")
                }
            ProbesTab(bindings: bindings)
                .tabItem {
                    Label(String(localized: "Probes", defaultValue: "Probes"), systemImage: "waveform")
                }
            NotificationsTab(bindings: bindings)
                .tabItem {
                    Label(String(localized: "Notifications", defaultValue: "Notifications"), systemImage: "bell.badge")
                }
            APITab(bindings: bindings, state: state)
                .tabItem {
                    Label(String(localized: "MCP & API", defaultValue: "MCP & API"), systemImage: "network")
                }
            LogsTab(bindings: bindings)
                .tabItem {
                    Label(String(localized: "Logs", defaultValue: "Logs"), systemImage: "doc.text")
                }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    @ObservedObject var bindings: ConfigBindings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { bindings.current.general.startAtLogin },
                    set: { newValue in
                        bindings.update { $0.general.startAtLogin = newValue }
                        Self.applyLoginItem(newValue)
                    }
                )) {
                    Text(String(localized: "Start at login", defaultValue: "Start at login"))
                }

                Picker(String(localized: "Language", defaultValue: "Language"), selection: Binding(
                    get: { bindings.current.general.language },
                    set: { v in
                        bindings.update { $0.general.language = v }
                        // Foundation's Bundle reads AppleLanguages early
                        // and caches localizations. To make the change
                        // stick we have to write the override here and
                        // ask the user to restart — the on-screen note
                        // below explains.
                        if v == "system" {
                            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                        } else {
                            UserDefaults.standard.set([v], forKey: "AppleLanguages")
                        }
                    }
                )) {
                    Text(String(localized: "System", defaultValue: "System")).tag("system")
                    Text("English").tag("en")
                    Text("Русский").tag("ru")
                }
                .pickerStyle(.menu)
                Text(String(
                    localized: "Restart uZora to apply language change.",
                    defaultValue: "Restart uZora to apply language change."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                Picker(String(localized: "Theme", defaultValue: "Theme"), selection: Binding(
                    get: { bindings.current.general.theme },
                    set: { v in bindings.update { $0.general.theme = v } }
                )) {
                    Text(String(localized: "System", defaultValue: "System")).tag("system")
                    Text(String(localized: "Light", defaultValue: "Light")).tag("light")
                    Text(String(localized: "Dark", defaultValue: "Dark")).tag("dark")
                }
                .pickerStyle(.menu)
            }

            Section {
                HStack {
                    Text(String(localized: "uZora version", defaultValue: "uZora version"))
                    Spacer()
                    Text("0.5.0").foregroundStyle(.secondary)
                }
                Button {
                    // Placeholder — Sparkle integration arrives in Phase 7.
                } label: {
                    Text(String(localized: "Check for updates", defaultValue: "Check for updates"))
                }
                .disabled(true)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Register / unregister the app as a login item via SMAppService.
    private static func applyLoginItem(_ enabled: Bool) {
        let svc = SMAppService.mainApp
        do {
            if enabled {
                if svc.status != .enabled {
                    try svc.register()
                }
            } else {
                if svc.status == .enabled {
                    try svc.unregister()
                }
            }
        } catch {
            // Log but don't surface to the user — SMAppService failures are
            // generally about sandbox / bundle layout and need a real .app.
            print("SMAppService toggle failed: \(error)")
        }
    }
}

// MARK: - Probes tab

private struct ProbesTab: View {
    @ObservedObject var bindings: ConfigBindings

    /// Display metadata + a key-path into ProbesConfig for each probe.
    /// Tuple shape: (display name, default warn, default critical,
    /// "warn label", "critical label", units, default-interval-seconds,
    /// KeyPath into ProbesConfig).
    private struct ProbeMeta {
        let name: String
        let displayName: String
        let warnDefault: Double
        let criticalDefault: Double
        let warnLabel: String
        let criticalLabel: String
        let units: String
        let pollDefault: Int
        let path: WritableKeyPath<ProbesConfig, ProbeOverride>
    }

    private static let probeMeta: [ProbeMeta] = [
        ProbeMeta(name: "disk", displayName: "Disk free", warnDefault: 15, criticalDefault: 5,
                  warnLabel: "Warn at free %", criticalLabel: "Critical at free %",
                  units: "%", pollDefault: 60, path: \.disk),
        ProbeMeta(name: "cpu_temp", displayName: "CPU temperature", warnDefault: 90, criticalDefault: 100,
                  warnLabel: "Warn at °C", criticalLabel: "Critical at °C",
                  units: "°C", pollDefault: 10, path: \.cpuTemp),
        ProbeMeta(name: "thermal", displayName: "Thermal pressure", warnDefault: 0, criticalDefault: 0,
                  warnLabel: "—", criticalLabel: "—",
                  units: "", pollDefault: 5, path: \.thermal),
        ProbeMeta(name: "battery", displayName: "Battery", warnDefault: 20, criticalDefault: 10,
                  warnLabel: "Warn below %", criticalLabel: "Critical below %",
                  units: "%", pollDefault: 30, path: \.battery),
        ProbeMeta(name: "smart", displayName: "SMART health", warnDefault: 10, criticalDefault: 5,
                  warnLabel: "Spare warn %", criticalLabel: "Spare critical %",
                  units: "%", pollDefault: 900, path: \.smart),
        ProbeMeta(name: "fan", displayName: "Fan RPM", warnDefault: 200, criticalDefault: 6000,
                  warnLabel: "Low RPM warn", criticalLabel: "High RPM",
                  units: "RPM", pollDefault: 15, path: \.fan),
        ProbeMeta(name: "kernel_task", displayName: "kernel_task CPU", warnDefault: 25, criticalDefault: 50,
                  warnLabel: "Warn %", criticalLabel: "Critical %",
                  units: "%", pollDefault: 15, path: \.kernelTask),
        ProbeMeta(name: "top_cpu", displayName: "Top CPU process", warnDefault: 50, criticalDefault: 80,
                  warnLabel: "Warn %", criticalLabel: "Critical %",
                  units: "%", pollDefault: 10, path: \.topCPU),
        ProbeMeta(name: "top_mem", displayName: "Top memory process", warnDefault: 8, criticalDefault: 16,
                  warnLabel: "Warn GB", criticalLabel: "Critical GB",
                  units: "GB", pollDefault: 30, path: \.topMem),
        ProbeMeta(name: "top_net", displayName: "Top network process", warnDefault: 50, criticalDefault: 200,
                  warnLabel: "Warn MB/s", criticalLabel: "Critical MB/s",
                  units: "MB/s", pollDefault: 60, path: \.topNet),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.probeMeta, id: \.name) { meta in
                    probeCard(meta: meta)
                }
            }
            .padding()
        }
    }

    private func probeCard(meta: ProbeMeta) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: Binding(
                    get: { bindings.current.probes[keyPath: meta.path].enabled },
                    set: { v in bindings.update { $0.probes[keyPath: meta.path].enabled = v } }
                )) {
                    Text(meta.displayName).fontWeight(.medium)
                }
                Spacer()
            }
            if meta.units != "" {
                HStack(spacing: 12) {
                    LabeledNumberField(
                        label: meta.warnLabel,
                        value: Binding(
                            get: { bindings.current.probes[keyPath: meta.path].warnThreshold ?? meta.warnDefault },
                            set: { v in bindings.update { $0.probes[keyPath: meta.path].warnThreshold = v } }
                        ),
                        units: meta.units
                    )
                    LabeledNumberField(
                        label: meta.criticalLabel,
                        value: Binding(
                            get: { bindings.current.probes[keyPath: meta.path].criticalThreshold ?? meta.criticalDefault },
                            set: { v in bindings.update { $0.probes[keyPath: meta.path].criticalThreshold = v } }
                        ),
                        units: meta.units
                    )
                }
            }
            HStack {
                Text(String(localized: "Poll interval", defaultValue: "Poll interval"))
                Stepper(value: Binding(
                    get: { bindings.current.probes[keyPath: meta.path].pollIntervalSec ?? meta.pollDefault },
                    set: { v in bindings.update { $0.probes[keyPath: meta.path].pollIntervalSec = v } }
                ), in: 1...3600, step: 5) {
                    Text("\(bindings.current.probes[keyPath: meta.path].pollIntervalSec ?? meta.pollDefault)s")
                        .monospacedDigit()
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }
}

private struct LabeledNumberField: View {
    let label: String
    @Binding var value: Double
    let units: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("", value: $value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Text(units)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Notifications tab

private struct NotificationsTab: View {
    @ObservedObject var bindings: ConfigBindings

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Banner severity floor", defaultValue: "Banner severity floor"),
                       selection: Binding(
                        get: { bindings.current.notifications.bannerSeverityFloor },
                        set: { v in bindings.update { $0.notifications.bannerSeverityFloor = v } }
                       )) {
                    Text(String(localized: "Info", defaultValue: "Info")).tag(Severity.info)
                    Text(String(localized: "Warning", defaultValue: "Warning")).tag(Severity.warn)
                    Text(String(localized: "Critical", defaultValue: "Critical")).tag(Severity.critical)
                }
                .pickerStyle(.menu)

                Toggle(isOn: Binding(
                    get: { bindings.current.notifications.respectFocus },
                    set: { v in bindings.update { $0.notifications.respectFocus = v } }
                )) {
                    Text(String(localized: "Respect Focus mode", defaultValue: "Respect Focus mode"))
                }
                Text(String(
                    localized: "Focus is handled by macOS: warn banners are withheld during Focus automatically, while critical alerts pierce as Time-Sensitive notifications.",
                    defaultValue: "Focus is handled by macOS: warn banners are withheld during Focus automatically, while critical alerts pierce as Time-Sensitive notifications."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    Task { await Self.fireTestNotification() }
                } label: {
                    Text(String(localized: "Test notification", defaultValue: "Test notification"))
                }
                Button {
                    // Critical alerts only pierce Focus if the user has
                    // allowed Time-Sensitive notifications for uZora. Open
                    // the Notifications pane so they can enable it.
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text(String(localized: "Notification Settings…", defaultValue: "Notification Settings…"))
                }
                Text(String(
                    localized: "Enable “Time-Sensitive Notifications” for uZora there so critical alerts can pierce Focus.",
                    defaultValue: "Enable “Time-Sensitive Notifications” for uZora there so critical alerts can pierce Focus."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private static func fireTestNotification() async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "uZora"
        content.body = String(localized: "Test notification — uZora is wired up.", defaultValue: "Test notification — uZora is wired up.")
        content.interruptionLevel = .active
        let req = UNNotificationRequest(identifier: "uzora.test.\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        try? await center.add(req)
    }
}

// MARK: - MCP & API tab

private struct APITab: View {
    @ObservedObject var bindings: ConfigBindings
    @ObservedObject var state: UIState

    var body: some View {
        Form {
            Section(header: Text("HTTP")) {
                Toggle(isOn: Binding(
                    get: { bindings.current.http.enabled },
                    set: { v in bindings.update { $0.http.enabled = v } }
                )) {
                    Text(String(localized: "HTTP server enabled", defaultValue: "HTTP server enabled"))
                }
                HStack {
                    Text(String(localized: "Port", defaultValue: "Port"))
                    TextField("", value: Binding(
                        get: { bindings.current.http.port },
                        set: { v in bindings.update { $0.http.port = v } }
                    ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }
            Section(header: Text("MCP")) {
                Toggle(isOn: Binding(
                    get: { bindings.current.mcp.enabled },
                    set: { v in bindings.update { $0.mcp.enabled = v } }
                )) {
                    Text(String(localized: "MCP server enabled", defaultValue: "MCP server enabled"))
                }
                LabeledCopyField(
                    label: String(localized: "MCP URL", defaultValue: "MCP URL"),
                    value: mcpURL
                )
            }
            Section(header: Text(String(localized: "Sample client configs", defaultValue: "Sample client configs"))) {
                CodeSnippetCopyView(
                    title: String(localized: "Claude Code / Cursor (HTTP MCP)", defaultValue: "Claude Code / Cursor (HTTP MCP)"),
                    snippet: claudeCodeSnippet
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var mcpURL: String {
        "http://127.0.0.1:\(bindings.current.http.port)/mcp"
    }

    private var claudeCodeSnippet: String {
        """
        {
          "mcpServers": {
            "uzora": {
              "type": "http",
              "url": "\(mcpURL)"
            }
          }
        }
        """
    }
}

private struct LabeledCopyField: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            TextField("", text: .constant(value))
                .textFieldStyle(.roundedBorder)
                .disabled(true)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct CodeSnippetCopyView: View {
    let title: String
    let snippet: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                } label: {
                    Label(String(localized: "Copy", defaultValue: "Copy"), systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(snippet)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
            }
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        }
    }
}

// MARK: - Logs tab

private struct LogsTab: View {
    @ObservedObject var bindings: ConfigBindings

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(String(localized: "Retention", defaultValue: "Retention"))
                    Spacer()
                    Stepper(value: Binding(
                        get: { bindings.current.general.logRetentionDays },
                        set: { v in bindings.update { $0.general.logRetentionDays = v } }
                    ), in: 1...365, step: 1) {
                        Text("\(bindings.current.general.logRetentionDays) " +
                             String(localized: "days", defaultValue: "days"))
                            .monospacedDigit()
                    }
                }
            }
            Section {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([Self.eventsDir])
                } label: {
                    Text(String(localized: "Open events folder", defaultValue: "Open events folder"))
                }
                Button {
                    let today = Self.todayEventFile
                    if FileManager.default.fileExists(atPath: today.path) {
                        NSWorkspace.shared.open(today)
                    }
                } label: {
                    Text(String(localized: "View today's events", defaultValue: "View today's events"))
                }
            }
            Section(header: Text(String(localized: "Stats", defaultValue: "Stats"))) {
                HStack {
                    Text(String(localized: "SQLite metrics history", defaultValue: "SQLite metrics history"))
                    Spacer()
                    Text(String(localized: "Coming in Phase 6", defaultValue: "Coming in Phase 6"))
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private static var eventsDir: URL {
        JSONLEventSink.defaultDirectory()
    }

    private static var todayEventFile: URL {
        eventsDir.appendingPathComponent("events-\(JSONLEventSink.dayKey(for: Date())).jsonl")
    }
}

// MARK: - Bindings adapter

/// MainActor-bound bridge between SwiftUI and the actor-backed
/// ConfigLoader. SwiftUI views observe `current`; mutations are routed
/// through `update(_:)` which schedules an async write back to the
/// loader on a `Task`.
@MainActor
public final class ConfigBindings: ObservableObject {
    @Published public var current: UZoraConfig
    private let loader: ConfigLoader

    public init(loader: ConfigLoader, initial: UZoraConfig) {
        self.loader = loader
        self.current = initial
    }

    /// Apply a mutation to the cached config + persist to disk.
    public func update(_ mutate: (inout UZoraConfig) -> Void) {
        var copy = current
        mutate(&copy)
        current = copy
        Task { [loader, copy] in
            do {
                try await loader.write(copy)
            } catch {
                // Persist failure: leave UI optimistic; next reload will
                // reconcile. Logged via the loader's own os.Logger.
            }
        }
    }

    /// Push a config snapshot in from the loader (used by the watcher
    /// reload callback).
    public func sync(_ config: UZoraConfig) {
        current = config
    }
}
