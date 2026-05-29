import SwiftUI
import AppKit
import UserNotifications
import os

@main
struct uZoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            // Live dashboard popover. Replaces the placeholder Phase 4 menu.
            // Gating-logic lives in a child View with explicit @ObservedObject
            // so it actually re-renders when AppDelegate.bindings flips from
            // nil to non-nil during async bootstrap.
            PopoverGate(appDelegate: appDelegate)
        } label: {
            MenuBarLabel(appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsGate(appDelegate: appDelegate)
        }
    }
}

/// Resolve a SwiftUI `Locale` from the config value:
/// `"system"` → no override (returns `Locale.current` so xcstrings falls
/// back to the system preferred languages); explicit `"en"` / `"ru"` /
/// any BCP-47 tag forces that locale's String Catalog entries.
private func resolveLocale(from configValue: String) -> Locale {
    if configValue == "system" || configValue.isEmpty {
        return Locale.current
    }
    return Locale(identifier: configValue)
}

private struct PopoverGate: View {
    @ObservedObject var appDelegate: AppDelegate
    var body: some View {
        if let bindings = appDelegate.bindings {
            PopoverView(state: appDelegate.uiState)
                .environmentObject(bindings)
                // Re-render the popover when the user picks a different
                // language in Settings — bindings is an ObservableObject,
                // so changing config.general.language re-evaluates this
                // body and applies the new locale to all child views.
                .environment(\.locale, resolveLocale(from: bindings.current.general.language))
        } else {
            ProgressView()
                .frame(width: 200, height: 100)
        }
    }
}

private struct SettingsGate: View {
    @ObservedObject var appDelegate: AppDelegate
    var body: some View {
        if let bindings = appDelegate.bindings {
            SettingsView(bindings: bindings, state: appDelegate.uiState)
                .environment(\.locale, resolveLocale(from: bindings.current.general.language))
        } else {
            ProgressView()
        }
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var appDelegate: AppDelegate
    var body: some View {
        // Tint the icon by overall severity so a glance at the menu
        // bar communicates "all clear / warn / critical".
        HStack(spacing: 4) {
            Image(systemName: "sunrise.fill")
                .foregroundStyle(appDelegate.uiState.overallSeverityTint)
            if appDelegate.uiState.overallSeverity == .critical {
                Text("!")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// SwiftUI-observable mirror of the running probe + channel pipeline.
@MainActor
public final class UIState: ObservableObject {
    // Probe inventory + last event log mirror (legacy Phase 4 fields).
    @Published public var probeNames: [String] = []
    @Published public var recentEventTexts: [String] = []
    @Published public var powerStateLabel: String = "—"
    @Published public var bridgeLabel: String = "bridge starting…"

    // Phase 5 dashboard fields.
    @Published public var activeAlerts: [Alert] = []
    @Published public var overallSeverity: Severity? = nil
    @Published public var startedAt: Date = Date()

    /// Process top-5 / top-3 lists for the popover.
    public struct ProcessSnap: Sendable, Equatable {
        public let pid: Int32
        public let name: String
        public let cpuPct: Double
        public let rssBytes: UInt64
    }
    @Published public var topCPUProcesses: [ProcessSnap] = []
    @Published public var topMemProcesses: [ProcessSnap] = []

    // Mini-tile current labels.
    @Published public var cpuTempLabel: String = "—"
    @Published public var diskFreeLabel: String = "—"
    @Published public var batteryLabel: String = "—"
    @Published public var memoryLabel: String = "—"

    // Ring buffers for sparklines (last 60 samples).
    @Published public var cpuTempHistory: [Double] = []
    @Published public var diskFreeHistory: [Double] = []
    @Published public var batteryHistory: [Double] = []
    @Published public var memoryHistory: [Double] = []

    // Channel up-state indicators.
    @Published public var httpAlive: Bool = false
    @Published public var mcpAlive: Bool = false
    @Published public var jsonlAlive: Bool = false

    public var uptimeLabel: String {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        if elapsed < 60 { return "uptime \(elapsed)s" }
        let mins = elapsed / 60
        if mins < 60 { return "uptime \(mins)m" }
        let hours = mins / 60
        return "uptime \(hours)h"
    }

    public var overallSeverityTint: Color {
        switch overallSeverity {
        case .some(.critical): return .red
        case .some(.warn):     return .yellow
        case .some(.info):     return .blue
        case .none:            return .gray
        }
    }

    /// Push the latest snapshot from the StateStore + samplers into the
    /// observable fields used by the popover.
    public func apply(activeAlerts: [Alert]) {
        self.activeAlerts = activeAlerts.sorted { $0.severity > $1.severity }
        self.overallSeverity = activeAlerts.max(by: { $0.severity < $1.severity })?.severity
    }

    /// Append a metric data point to a sparkline buffer (60-sample cap).
    public func recordMetric(probe: String, value: Double) {
        switch probe {
        case "cpu_temp":
            cpuTempHistory.append(value)
            if cpuTempHistory.count > 60 { cpuTempHistory.removeFirst(cpuTempHistory.count - 60) }
            cpuTempLabel = String(format: "%.0f°C", value)
        case "disk":
            diskFreeHistory.append(value)
            if diskFreeHistory.count > 60 { diskFreeHistory.removeFirst(diskFreeHistory.count - 60) }
            diskFreeLabel = String(format: "%.0f%%", value)
        case "battery":
            batteryHistory.append(value)
            if batteryHistory.count > 60 { batteryHistory.removeFirst(batteryHistory.count - 60) }
            batteryLabel = String(format: "%.0f%%", value)
        case "memory":
            memoryHistory.append(value)
            if memoryHistory.count > 60 { memoryHistory.removeFirst(memoryHistory.count - 60) }
            memoryLabel = String(format: "%.0f%%", value)
        default:
            break
        }
    }
}

/// AppDelegate driving the Phase 1+5 pipeline.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    public let uiState: UIState
    @Published public var bindings: ConfigBindings?

    public override init() {
        self.uiState = UIState()
        super.init()
    }

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "app")
    private var host: ChannelHost?
    private var registry: ProbeRegistry?
    private var bus: EventBus?
    private var loader: ConfigLoader?
    private var notifications: UZoraNotificationCenter?
    private var stateStore: StateStore?
    private var metricsStore: MetricsStore?
    private var refreshTimer: Timer?
    private var metricsRetentionTask: Task<Void, Never>?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await self.bootstrap()
        }
    }

    @MainActor
    private func bootstrap() async {
        // Phase 5: load config first so HTTP port / probe enables apply.
        let loader: ConfigLoader
        do {
            loader = try ConfigLoader()
            await loader.startWatching()
        } catch {
            log.error("config init failed: \(String(describing: error), privacy: .public); using defaults")
            // Fall back to an in-memory default; UI still works.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("uzora-fallback-\(UUID().uuidString).toml")
            loader = (try? ConfigLoader(configURL: tmp)) ?? {
                // Last-resort: a loader with a synthetic URL we'll never use.
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("uzora-noop.toml")
                return try! ConfigLoader(configURL: url)
            }()
        }
        self.loader = loader
        let initial = await loader.current
        let bindings = ConfigBindings(loader: loader, initial: initial)
        self.bindings = bindings

        // Subscribe to config reload broadcasts.
        await loader.observe { [weak bindings] config in
            Task { @MainActor [weak bindings] in
                bindings?.sync(config)
            }
        }

        // Phase 5: build the probe set FROM the loaded config so only
        // enabled probes register and config thresholds/poll-intervals
        // apply from the first tick (not just after a later hot-reload).
        let registry = await ProbeRegistry.defaultPopulated(config: initial)
        let powerMonitor = PowerProfileMonitor()
        // Persist watchdog state alongside config/events/metrics so
        // appeared/cleared events stay idempotent across app restarts.
        // Override the path via UZORA_WATCHDOG_STATE_PATH for isolated E2E
        // runs (so tests don't clobber the operator's real state file).
        let watchdogStateURL: URL?
        if let envPath = ProcessInfo.processInfo.environment["UZORA_WATCHDOG_STATE_PATH"] {
            watchdogStateURL = URL(fileURLWithPath: envPath)
        } else {
            let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            watchdogStateURL = supportDir?.appendingPathComponent("uZora/watchdog-state.json")
        }
        let watchdog = Watchdog(stateURL: watchdogStateURL)
        let eventBus = EventBus()
        let stateStore = StateStore()
        // Seed StateStore from persisted Watchdog state so /alerts and the
        // popover surface still-firing alerts immediately on restart —
        // without waiting for fresh `appeared` events (Watchdog correctly
        // suppresses those when state was loaded from disk).
        let persistedAlerts = Array(await watchdog.snapshot().values)
        if !persistedAlerts.isEmpty {
            await stateStore.seedActiveAlerts(persistedAlerts)
            // Also mirror into UIState so popover shows restored alerts
            // immediately on launch (event-bus subscription only fires on
            // transitions; idempotent re-runs emit nothing).
            uiState.apply(activeAlerts: persistedAlerts)
        }
        self.registry = registry
        self.bus = eventBus
        self.stateStore = stateStore
        // Let the registry refresh the probe roster + synthesise clears for
        // disabled probes during config hot-reload (reconfigure).
        await registry.attachStateStore(stateStore)

        // Phase 6: open the SQLite metrics store and start a daily purge
        // loop. Failure to open downgrades the app to "no historical
        // metrics" — REST /metrics still answers, just with empty arrays.
        let metricsStore: MetricsStore?
        do {
            metricsStore = try MetricsStore()
        } catch {
            log.error("MetricsStore init failed: \(String(describing: error), privacy: .public); continuing without history")
            metricsStore = nil
        }
        self.metricsStore = metricsStore
        if let metricsStore {
            await registry.attachMetricsStore(metricsStore)
            startMetricsRetentionLoop(store: metricsStore)
        }

        let jsonlSink: JSONLEventSink?
        do {
            jsonlSink = try JSONLEventSink(retentionDays: initial.general.logRetentionDays)
            uiState.jsonlAlive = true
        } catch {
            log.error("JSONLEventSink init failed: \(String(describing: error), privacy: .public)")
            jsonlSink = nil
            uiState.jsonlAlive = false
        }

        // Phase 5: notification center + auth.
        let notifs = UZoraNotificationCenter()
        await notifs.requestAuthorization()
        self.notifications = notifs

        // Seed the probe inventory in the state store, reflecting each
        // probe's config-effective base poll interval.
        let names = await registry.registeredNames()
        var inventory: [StateStore.ProbeInfo] = []
        for name in names {
            let secs = (await registry.configuredBaseInterval(forProbeNamed: name)?.components.seconds).map(Double.init) ?? 0
            inventory.append(StateStore.ProbeInfo(name: name, pollIntervalSeconds: secs, lastRunAt: nil))
        }
        await stateStore.setProbes(inventory)
        uiState.probeNames = names

        // EventBus → built-in sinks.
        await eventBus.attachLoggerSink()
        await eventBus.attachConsoleSink()

        // UI mirror of last events (legacy).
        let weakState = uiState
        await eventBus.subscribe { [weak weakState] event in
            let text = AppDelegate.format(event)
            Task { @MainActor in
                guard let weakState else { return }
                weakState.recentEventTexts.append(text)
                if weakState.recentEventTexts.count > 5 {
                    weakState.recentEventTexts.removeFirst(weakState.recentEventTexts.count - 5)
                }
            }
        }

        // Phase 5: bridge events → user notifications + active-alerts mirror.
        let notifsRef = notifs
        let bindingsRef = bindings
        let storeRef = stateStore
        await eventBus.subscribe { [weak weakState] event in
            Task { @MainActor [weak weakState] in
                guard let weakState else { return }
                let active = await storeRef.activeAlerts()
                weakState.apply(activeAlerts: active)
                let focusActive = false // Reserved for Phase 6 Focus detection.
                _ = await notifsRef.notify(
                    event: event,
                    config: bindingsRef.current.notifications,
                    focusActive: focusActive
                )
            }
        }

        // Bring up the four-channel bridge respecting HTTP/MCP enablement.
        let portConfig = initial.http.port
        let portEnv = ProcessInfo.processInfo.environment["UZORA_HTTP_PORT"].flatMap { UInt16($0) }
        let port = portEnv ?? portConfig
        if let jsonlSink, initial.http.enabled {
            let host = ChannelHost(
                port: port,
                state: stateStore,
                jsonl: jsonlSink,
                eventBus: eventBus,
                metrics: metricsStore,
                // Wire the live ConfigLoader so the reconfigure write path can
                // load → mutate → persist; the existing hot-reload observer
                // (registered later in this method) then applies the change.
                configLoader: loader,
                // Global write gate from config — default true (loopback-only).
                allowWrites: initial.mcp.allowWrites
            )
            do {
                try await host.start()
                let bound = await host.boundPort()
                uiState.bridgeLabel = "bridge: http://127.0.0.1:\(bound)"
                uiState.httpAlive = true
                uiState.mcpAlive = initial.mcp.enabled
                self.host = host
            } catch {
                uiState.bridgeLabel = "bridge: failed (\(error))"
                uiState.httpAlive = false
                log.error("ChannelHost start failed: \(String(describing: error), privacy: .public)")
            }
        } else {
            uiState.bridgeLabel = "bridge: disabled"
        }

        // PowerMonitor → registry + state-store + UI label.
        let uiStateRef = uiState
        await powerMonitor.observe { profile in
            Task {
                await registry.updatePowerProfile(profile)
                await stateStore.updatePowerState(profile.state.rawValue)
            }
            Task { @MainActor in
                uiStateRef.powerStateLabel = profile.state.rawValue
            }
        }
        await powerMonitor.start()

        await registry.start(watchdog: watchdog, eventBus: eventBus)
        log.info("uZora launched, registered \(names.count, privacy: .public) probes, bridge on :\(port, privacy: .public)")

        // Hot-reload: when config.toml changes, rebuild the probe set with
        // the new enables/thresholds/poll-intervals. The ConfigLoader
        // watcher already debounces ~150ms; `observe` fires once
        // synchronously at registration with the *current* config — we skip
        // that initial fire (the registry was just built from it) and only
        // act on subsequent reloads. Probe-roster changes are mirrored into
        // `uiState.probeNames` for the popover.
        let registryRef = registry
        let uiStateForRoster = uiState
        let reconfigureOnReload: ConfigLoader.ReloadCallback = { config in
            Task {
                await registryRef.reconfigure(config)
                let updatedNames = await registryRef.registeredNames()
                await MainActor.run { uiStateForRoster.probeNames = updatedNames }
            }
        }
        await loader.observe(reconfigureOnReload, skippingInitial: true)

        // Drive a 5s refresh loop that pulls metric sparklines + process
        // top-N from the live samplers. Phase 5 stops short of SQLite —
        // these are session-local ring buffers.
        startMetricRefresh()
    }

    /// Sample probes every 5s for popover-visible metrics (sparklines + top
    /// processes). The actual probe scheduler runs at probe cadence and
    /// drives alerts; this loop is purely visual.
    ///
    /// Phase 6: when a `MetricsStore` is wired, the sparkline buffers are
    /// rebuilt from the last 60 s of persisted samples each tick so the
    /// graph survives session restarts (instead of starting blank). The
    /// live samplers still run as a backup so the very first popover
    /// open also paints data on a brand-new install.
    @MainActor
    private func startMetricRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.refreshMetricsAndProcesses()
            }
        }
    }

    /// Phase 6: hydrate the popover sparkline buffers from the metrics
    /// store. Falls back silently when the store isn't available.
    @MainActor
    private func rehydrateSparklinesFromStore() async {
        guard let store = self.metricsStore else { return }
        let now = Date()
        let fromTs = now.addingTimeInterval(-300) // last 5 min

        let cpuSamples = (try? await store.query(probe: "cpu_temp", from: fromTs, to: now, name: "temp_c")) ?? []
        if !cpuSamples.isEmpty {
            uiState.cpuTempHistory = cpuSamples.suffix(60).map { $0.value }
            if let last = cpuSamples.last { uiState.cpuTempLabel = String(format: "%.0f°C", last.value) }
        }

        let diskSamples = (try? await store.query(probe: "disk", from: fromTs, to: now, name: "free_pct")) ?? []
        if !diskSamples.isEmpty {
            uiState.diskFreeHistory = diskSamples.suffix(60).map { $0.value }
            if let last = diskSamples.last { uiState.diskFreeLabel = String(format: "%.0f%%", last.value) }
        }

        let battSamples = (try? await store.query(probe: "battery", from: fromTs, to: now, name: "charge_pct")) ?? []
        if !battSamples.isEmpty {
            uiState.batteryHistory = battSamples.suffix(60).map { $0.value }
            if let last = battSamples.last { uiState.batteryLabel = String(format: "%.0f%%", last.value) }
        }
    }

    @MainActor
    private func refreshMetricsAndProcesses() async {
        // Phase 6: prefer persisted history (survives restart) and fall
        // back to live samplers below so day-zero charts still paint.
        await rehydrateSparklinesFromStore()

        // CPU temp.
        if let s = CPUTempProbe.sampleViaSMC() {
            uiState.recordMetric(probe: "cpu_temp", value: s.tempC)
        }
        // Disk free.
        if let s = DiskFreeProbe.sampleRoot() {
            uiState.recordMetric(probe: "disk", value: s.freeFraction * 100)
        }
        // Battery (laptops only).
        if let s = BatteryProbe.sampleInternalBattery() {
            uiState.recordMetric(probe: "battery", value: Double(s.chargePct))
        }
        // Memory pressure: rough — used / total %.
        let totalBytes = ProcessSampler.hostTotalMemoryBytes()
        if totalBytes > 0 {
            let snaps = ProcessSampler.snapshotAll()
            let totalRSS = snaps.reduce(UInt64(0)) { $0 + $1.residentSizeBytes }
            let pct = Double(totalRSS) / Double(totalBytes) * 100
            uiState.recordMetric(probe: "memory", value: min(pct, 100))
        }
        // Top processes — live computed from ProcessSampler snapshots.
        let snaps = ProcessSampler.snapshotAll()

        // Top memory: 3 largest RSS (skip system kernel_task at PID 0).
        let byMem = snaps
            .filter { $0.pid > 0 }
            .sorted { $0.residentSizeBytes > $1.residentSizeBytes }
            .prefix(3)
            .map {
                UIState.ProcessSnap(
                    pid: $0.pid,
                    name: $0.name,
                    cpuPct: 0,
                    rssBytes: $0.residentSizeBytes
                )
            }
        uiState.topMemProcesses = Array(byMem)

        // Top CPU: per-PID CPU% via snapshot delta against previous tick.
        // First tick has no previous → fall back to memory-by-RSS so the
        // section paints something instead of looking broken.
        var topCPU: [UIState.ProcessSnap] = []
        if let prev = previousSnaps {
            let prevByPID = Dictionary(uniqueKeysWithValues: prev.map { ($0.pid, $0) })
            var byCPU: [(snap: ProcessSampler.Snapshot, pct: Double)] = []
            for s in snaps where s.pid > 0 {
                guard let p = prevByPID[s.pid],
                      let pct = ProcessSampler.cpuPercent(previous: p, current: s),
                      pct > 0.05  // suppress idle / 0% noise
                else { continue }
                byCPU.append((s, pct))
            }
            byCPU.sort { $0.pct > $1.pct }
            topCPU = byCPU.prefix(5).map {
                UIState.ProcessSnap(
                    pid: $0.snap.pid,
                    name: $0.snap.name,
                    cpuPct: $0.pct,
                    rssBytes: $0.snap.residentSizeBytes
                )
            }
        }
        if topCPU.isEmpty {
            // Day-zero / quiet system: show top-RSS as placeholder so the
            // section never looks broken.
            topCPU = Array(byMem)
        }
        uiState.topCPUProcesses = topCPU
        self.previousSnaps = snaps
    }

    /// Previous ProcessSampler snapshot — kept on the actor for per-PID
    /// CPU% delta computation across refresh ticks.
    private var previousSnaps: [ProcessSampler.Snapshot]?

    /// Phase 6: prune metric rows older than 7 days every 24 h. Runs in
    /// a detached `Task` so it survives app-lifetime; cancelled on
    /// terminate.
    @MainActor
    private func startMetricsRetentionLoop(store: MetricsStore) {
        metricsRetentionTask?.cancel()
        metricsRetentionTask = Task.detached(priority: .background) { [weak self] in
            // Run one purge eagerly at startup, then once a day.
            while !Task.isCancelled {
                let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
                do {
                    let removed = try await store.purge(olderThan: cutoff)
                    if removed > 0 {
                        await self?.logMetricsPurge(removed: removed)
                    }
                } catch {
                    await self?.logMetricsPurgeError(error)
                }
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    @MainActor
    private func logMetricsPurge(removed: Int) {
        log.info("metrics retention: purged \(removed, privacy: .public) rows older than 7d")
    }

    @MainActor
    private func logMetricsPurgeError(_ error: Swift.Error) {
        log.error("metrics retention failed: \(String(describing: error), privacy: .public)")
    }

    public func applicationWillTerminate(_ notification: Notification) {
        let h = self.host
        let r = self.registry
        let l = self.loader
        let m = self.metricsStore
        metricsRetentionTask?.cancel()
        Task {
            await h?.stop()
            await r?.stop()
            await l?.stopWatching()
            await m?.close()
        }
    }

    nonisolated static func format(_ event: WatchdogEvent) -> String {
        switch event {
        case .appeared(let alert):
            return "▲ \(alert.id) [\(alert.severity.rawValue)]"
        case .escalated(let alert, let prev):
            return "↑ \(alert.id) \(prev.rawValue)→\(alert.severity.rawValue)"
        case .cleared(let id):
            return "✓ \(id) cleared"
        }
    }
}
