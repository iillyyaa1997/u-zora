import SwiftUI
import AppKit
@preconcurrency import UserNotifications  // see NotificationCenter.swift — cross-SDK Sendable gap
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
            if DemoDataSource.isEnabledInEnvironment {
                // Opt-in live preview (UZORA_DEMO_POPOVER): drive the popover
                // from the motion demo instead of the live pipeline. Default
                // off ⇒ this branch is never taken and behavior is unchanged.
                DemoPopoverHost(bindings: bindings)
            } else {
                // A3a: resolve the popover layout (preset + optional customized
                // JSON) from config and pass it in. `bindings` is observed here,
                // so a config edit re-evaluates this body → new layout →
                // hot-reloaded popover. `PopoverView` stays a pure function of
                // (state, layout) and never reads ConfigBindings itself.
                PopoverView(
                    state: appDelegate.uiState,
                    layout: effectiveLayout(
                        preset: bindings.current.ui.popover.preset,
                        layoutJSON: bindings.current.ui.popover.layoutJSON
                    ),
                    // A4c: the ONLY site that wires the REAL quick-action
                    // handlers (demo/preview keep the no-op defaults). A tap on
                    // a finding "Fix" runs the action confirmed; a tap on an
                    // "Other signals" "Ack" suppresses that alert.
                    onRunAction: { actionID in
                        await appDelegate.runConfirmedAction(actionID)
                    },
                    onAck: { alertID in
                        await appDelegate.acknowledgeAlert(alertID)
                    }
                )
                    .environmentObject(bindings)
                    // Re-render the popover when the user picks a different
                    // language in Settings — bindings is an ObservableObject,
                    // so changing config.general.language re-evaluates this
                    // body and applies the new locale to all child views.
                    .environment(\.locale, resolveLocale(from: bindings.current.general.language))
            }
        } else {
            ProgressView()
                .frame(width: 200, height: 100)
        }
    }
}

/// Opt-in demo host (`UZORA_DEMO_POPOVER`): owns a single `DemoDataSource`
/// via `@StateObject` so its motion timer persists across popover re-renders.
private struct DemoPopoverHost: View {
    @StateObject private var demo = DemoDataSource()
    let bindings: ConfigBindings
    var body: some View {
        PopoverView(
            state: demo,
            layout: effectiveLayout(
                preset: bindings.current.ui.popover.preset,
                layoutJSON: bindings.current.ui.popover.layoutJSON
            )
        )
            .environmentObject(bindings)
            .environment(\.locale, resolveLocale(from: bindings.current.general.language))
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
            // Raw-critical probe firing → the existing red "!" (D5: keep it).
            if appDelegate.uiState.overallSeverity == .critical {
                Text("!")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            // Diagnosis `problem` verdict → a DISTINCT glyph (D5: "distinct
            // menu-bar glyph for problem-slowdown vs the raw-critical !").
            // A red ECG/waveform symbol reads as "diagnosis / something's
            // wrong with how the Mac is *behaving*", visually unlike the bare
            // "!" of a single threshold trip. Plain `Image(systemName:)` so it
            // compiles cross-SDK.
            if appDelegate.uiState.verdict == .problem {
                Image(systemName: "waveform.path.ecg")
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

    // A4c inline quick-actions (plan D-C2): runnable actions pre-resolved per
    // probe (keyed by probe name) off the `ActionRegistry` actor, so the
    // popover's finding cards can decide the "Fix" button synchronously.
    // Recomputed from the active alerts' probes on each refresh + after an ack.
    @Published public var availableActionsByProbe: [String: [ActionDescriptor]] = [:]

    // Diagnosis-layer (Phase 4) verdict mirror. The proactive "is my Mac OK?"
    // aggregate, distinct from the raw `overallSeverity` (which reflects probe
    // firings). Driven by the DiagnosisEngine cycle via `applyDiagnosis(_:)`.
    @Published public var verdict: VerdictLevel = .good
    @Published public var verdictHeadline: String = Verdict.healthyHeadline
    @Published public var findings: [Finding] = []

    /// Process top-5 / top-3 lists for the popover.
    public struct ProcessSnap: Sendable, Equatable {
        public let pid: Int32
        public let name: String
        public let cpuPct: Double
        public let rssBytes: UInt64
    }
    @Published public var topCPUProcesses: [ProcessSnap] = []
    @Published public var topMemProcesses: [ProcessSnap] = []

    /// A4b top-network-talkers row (`topNet` block). Mirrors
    /// `TopNetworkProcessProbe.ProcessEntry` but nested on UIState next to
    /// `ProcessSnap`, so the popover surface stays self-contained.
    public struct NetSnap: Sendable, Equatable {
        public let pid: Int32
        public let command: String
        public let bytesInPerSec: UInt64
        public let bytesOutPerSec: UInt64
        public init(pid: Int32, command: String, bytesInPerSec: UInt64, bytesOutPerSec: UInt64) {
            self.pid = pid
            self.command = command
            self.bytesInPerSec = bytesInPerSec
            self.bytesOutPerSec = bytesOutPerSec
        }
    }
    /// A4b top-network-talkers list, written by the 60s AppDelegate sampler.
    @Published public var topNetProcesses: [NetSnap] = []

    /// A4b 7-day history series (CPU temperature) bucketed to ~hourly averages,
    /// written by the slow (~5 min) AppDelegate loader off the durable store.
    @Published public var sevenDayHistory: [Double] = []

    // Mini-tile current labels.
    @Published public var cpuTempLabel: String = "—"
    @Published public var diskFreeLabel: String = "—"
    @Published public var batteryLabel: String = "—"
    @Published public var memoryLabel: String = "—"

    // A4a expanded-catalog tile labels (opt-in, default-OFF). Each mirrors a
    // Rail-1 series uZora already persists; populated in the refresh path from
    // the metrics store. `memoryUsed%` reuses `memoryLabel`/`memoryHistory`.
    @Published public var gpuLabel: String = "—"
    @Published public var coresPinnedLabel: String = "—"
    @Published public var swapInLabel: String = "—"
    @Published public var kernelTaskLabel: String = "—"

    // Ring buffers for sparklines (last 60 samples).
    @Published public var cpuTempHistory: [Double] = []
    @Published public var diskFreeHistory: [Double] = []
    @Published public var batteryHistory: [Double] = []
    @Published public var memoryHistory: [Double] = []

    // A4a expanded-catalog sparkline buffers (last 60 samples).
    @Published public var gpuHistory: [Double] = []
    @Published public var coresPinnedHistory: [Double] = []
    @Published public var swapInHistory: [Double] = []
    @Published public var kernelTaskHistory: [Double] = []

    // A2/D6: macOS memory-pressure LEVEL for the default Memory tile — the
    // CORRECT memory signal (0 normal / 1 warn / 2 critical), surfaced from
    // `system_signals`' `mem_pressure_level` ordinal. `nil` until first read.
    @Published public var memPressureLevel: Int? = nil

    // Channel up-state indicators.
    @Published public var httpAlive: Bool = false
    @Published public var mcpAlive: Bool = false
    @Published public var jsonlAlive: Bool = false

    /// Q10: recent action audit entries for the popover "Recent actions"
    /// section. Newest last; mirror of the AuditLog in-memory tail.
    @Published public var recentActions: [AuditLog.Entry] = []

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

    /// Color for the diagnosis `Verdict` (popover card dot + menu-bar badge).
    /// good=green, watch=blue, degraded=orange, problem=red (plan D5).
    public var verdictTint: Color {
        switch verdict {
        case .good:     return .green
        case .watch:    return .blue
        case .degraded: return .orange
        case .problem:  return .red
        }
    }

    /// Push a freshly-derived `Verdict` into the observable fields the
    /// popover Verdict card + menu-bar glyph read. Called once per
    /// DiagnosisEngine cycle from `AppDelegate.runDiagnosisCycle()`.
    public func applyDiagnosis(_ v: Verdict) {
        verdict = v.level
        verdictHeadline = v.headline
        findings = v.findings
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
        case "gpu":
            gpuHistory.append(value)
            if gpuHistory.count > 60 { gpuHistory.removeFirst(gpuHistory.count - 60) }
            gpuLabel = String(format: "%.0f%%", value)
        case "cores_pinned":
            coresPinnedHistory.append(value)
            if coresPinnedHistory.count > 60 { coresPinnedHistory.removeFirst(coresPinnedHistory.count - 60) }
            coresPinnedLabel = String(format: "%.0f", value)
        case "swap_in":
            swapInHistory.append(value)
            if swapInHistory.count > 60 { swapInHistory.removeFirst(swapInHistory.count - 60) }
            swapInLabel = String(format: "%.0f/s", value)
        case "kernel_task":
            kernelTaskHistory.append(value)
            if kernelTaskHistory.count > 60 { kernelTaskHistory.removeFirst(kernelTaskHistory.count - 60) }
            kernelTaskLabel = String(format: "%.0f%%", value)
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
    // A4b: two SLOW samplers, deliberately OFF the 5s main-actor refresh.
    // `sevenDayTimer` reloads the durable 7-day series (~5 min); `topNetTimer`
    // samples nettop (~60s, expensive subprocess). Both write UIState off async
    // tasks so they never block the UI.
    private var sevenDayTimer: Timer?
    private var topNetTimer: Timer?
    // Diagnosis layer (Phase 4). All optional / nil until bootstrap wires
    // them; the cycle no-ops when the engine/watchdog are absent (e.g. no
    // MetricsStore), so it never blocks or breaks startup.
    private var diagnosisEngine: DiagnosisEngine?
    private var findingWatchdog: FindingWatchdog?
    // Phase 5: read-only diagnosis snapshot the channel layer reads
    // (`GET /findings` + `/verdict`, MCP read tools). Created UNCONDITIONALLY
    // in bootstrap (even with no MetricsStore → empty/`good`) so channels
    // always have it; the diagnosis loop is its only writer.
    private var diagnosisStore: DiagnosisStore?
    // B1a (plan D-L4): parallel diagnosis-layer fan-out onto `/stream`. Created
    // UNCONDITIONALLY alongside `diagnosisStore` and handed to the ChannelHost →
    // SSEStream. `runDiagnosisCycle()` emits finding + verdict_changed events
    // here (in ADDITION to the existing notify + store-update calls).
    private var diagnosisBus: DiagnosisEventBus?
    // B1a: last aggregate verdict LEVEL, so the cycle emits `verdict_changed`
    // only on an actual level transition (good↔watch↔degraded↔problem). Seeded
    // from any persisted-findings verdict at boot so a restart doesn't re-fire.
    private var lastVerdictLevel: VerdictLevel = .good
    private var diagnosisTimer: Timer?
    // Q10 auto-actions.
    private var actionRegistry: ActionRegistry?
    private var policyEngine: PolicyEngine?
    private var auditLog: AuditLog?
    private var actionRunner: ActionRunner?
    // B3 proactive-push (plan D-L1): the ONE zero-egress event→local-agent
    // producer. OFF by default — constructed always, but only STARTED
    // (subscribed) when `[push] enabled`. Its own push-audit + outbox files.
    private var proactivePush: ProactivePush?
    private var pushAuditLog: PushAuditLog?
    private var pushOutbox: PushOutbox?

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
        // Reconcile persisted Watchdog state against the CURRENT config before
        // seeding. The watchdog reloads every prior alert (loadState applies no
        // enabled-filter); if the user disabled a probe between runs, that
        // probe's persisted alert would otherwise seed StateStore + UIState yet
        // never tick again (the registry doesn't register a disabled probe), so
        // it would linger forever in /alerts, /status, MCP, and the popover.
        // Mirror reconfigure()'s dropped-probe cleanup at boot: synthesise a
        // clear for each persisted alert whose probe is NOT in the registered
        // (enabled) set — which both purges the watchdog's on-disk state (so a
        // relaunch can't resurrect it) and yields the clears to ingest.
        let registeredNames = Set(await registry.registeredNames())
        let bootClears = await watchdog.reconcileAgainstRegistered(registeredNames)
        if !bootClears.isEmpty {
            // Push the clears through StateStore so any (future) seed/consumer
            // path stays consistent; the seed below already excludes them.
            for ev in bootClears { await stateStore.ingest(ev) }
            log.info("boot reconcile: cleared \(bootClears.count, privacy: .public) persisted alert(s) for disabled probe(s)")
        }
        // Seed StateStore from the reconciled Watchdog state so /alerts and the
        // popover surface still-firing alerts immediately on restart —
        // without waiting for fresh `appeared` events (Watchdog correctly
        // suppresses those when state was loaded from disk). Only alerts for
        // still-registered probes survive the reconcile above.
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

        // ── Proactive diagnosis layer (Phase 4) ─────────────────────────
        // Phase 5: create the read-only DiagnosisStore UNCONDITIONALLY so the
        // channel layer always has a snapshot to serve on `/findings` +
        // `/verdict` (an un-fed store answers empty + `good`, which is exactly
        // the correct clean-machine result). The diagnosis loop below — when a
        // MetricsStore exists — becomes its only writer.
        let diagnosisStore = DiagnosisStore()
        self.diagnosisStore = diagnosisStore

        // B1a (plan D-L4): create the parallel diagnosis fan-out UNCONDITIONALLY
        // too (like the store), so `/stream` can relay finding + verdict events
        // whenever the diagnosis loop runs. Handed to the ChannelHost → SSEStream
        // below; `runDiagnosisCycle()` is its only emitter.
        let diagnosisBus = DiagnosisEventBus()
        self.diagnosisBus = diagnosisBus

        // Build the engine ONLY when a MetricsStore exists (the detectors
        // read probe history). Without a store the whole layer stays dormant
        // — `runDiagnosisCycle()` guard-fails and no-ops, so a store-less
        // launch (or e2e where history is empty) never blocks or breaks
        // bootstrap.
        if let metricsStore {
            let engine = DiagnosisEngine(
                detectors: DiagnosisEngine.v1Detectors(),
                store: metricsStore
            )
            // Persist finding state alongside the watchdog state so
            // diagnosed/resolved events stay idempotent across restarts.
            // Override via UZORA_FINDINGS_STATE_PATH for isolated E2E/tests
            // (mirrors the UZORA_WATCHDOG_STATE_PATH block above so the
            // operator's real finding state is never clobbered).
            let findingsStateURL: URL?
            if let envPath = ProcessInfo.processInfo.environment["UZORA_FINDINGS_STATE_PATH"] {
                findingsStateURL = URL(fileURLWithPath: envPath)
            } else {
                let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                findingsStateURL = supportDir?.appendingPathComponent("uZora/findings-state.json")
            }
            let fw = FindingWatchdog(stateURL: findingsStateURL)
            self.diagnosisEngine = engine
            self.findingWatchdog = fw

            // Seed UIState from persisted findings so the popover Verdict card
            // + menu-bar glyph reflect a still-active diagnosis immediately on
            // restart (idempotent — the watchdog suppresses re-`diagnosed`
            // events for findings restored from disk).
            let persisted = Array(await fw.snapshot().values)
            if !persisted.isEmpty {
                let seededVerdict = Verdict.derive(from: persisted)
                uiState.applyDiagnosis(seededVerdict)
                // Phase 5: seed the channel-readable snapshot too, so a query
                // immediately after restart reflects the still-active diagnosis
                // (derive ONCE; UI + store get the same verdict).
                await diagnosisStore.update(findings: persisted, verdict: seededVerdict)
                // B1a: seed the last verdict level so the FIRST post-restart
                // cycle only emits `verdict_changed` if the level ACTUALLY moves
                // (a persisted diagnosis surviving relaunch is not a transition).
                self.lastVerdictLevel = seededVerdict.level
            }
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

        // ── Q10 auto-actions ────────────────────────────────────────────
        // Build the action subsystem: registry (4 reversible actions) +
        // policy engine (gate chain) + always-on audit log + runner. The
        // runner is wired into the channel host (read-only /actions +
        // uzora_list_actions), the EventBus (auto path), and the
        // notification center (confirmed "Run" button).
        let actionRegistry = ActionRegistry.defaultPopulated()
        let policyEngine = PolicyEngine()
        let auditLog: AuditLog?
        do {
            auditLog = try AuditLog(retentionDays: initial.general.logRetentionDays)
            await auditLog?.startRotationLoop()
        } catch {
            log.error("AuditLog init failed: \(String(describing: error), privacy: .public); actions disabled")
            auditLog = nil
        }
        self.actionRegistry = actionRegistry
        self.policyEngine = policyEngine
        self.auditLog = auditLog

        // Context provider for the PolicyEngine: live power state + Focus +
        // the current [actions] config. Power/Focus are read from the
        // registry's current profile (kept in sync by the PowerMonitor).
        let registryForCtx = registry
        let loaderForCtx = loader
        let actionRunner: ActionRunner?
        if let auditLog {
            actionRunner = ActionRunner(
                registry: actionRegistry,
                policy: policyEngine,
                audit: auditLog,
                contextProvider: { [registryForCtx, loaderForCtx] in
                    let profile = await registryForCtx.powerProfile()
                    let cfg = await loaderForCtx.current.actions
                    return PolicyEngine.Context(
                        powerState: profile.state,
                        focusActive: profile.state == .focusActive,
                        config: cfg
                    )
                }
            )
        } else {
            actionRunner = nil
        }
        self.actionRunner = actionRunner

        // Confirmed-action path: the notification "Run" button. Only probes
        // that currently map to at least one action get the button. MVP: the
        // four actions all bind to `disk`, so derive the set from the
        // registry mapping at the alert floor.
        if actionRunner != nil {
            let actionableProbes = Set(ActionRegistry.Descriptors.all.map(\.relatedProbe))
            notifs.wireRunAction(actionableProbes: actionableProbes) { [weak self] probe, severity in
                guard let runner = await self?.actionRunner else { return }
                let cfg = await loaderForCtx.current.actions
                // Run EVERY action mapped to this probe+severity with
                // trigger=confirmed (the user clicked). PolicyEngine bypasses
                // the enabled/power/focus/cooldown/rate gates for a confirmed
                // run but still enforces reversibility + audits the outcome.
                let mapped = await actionRegistry.actionsFor(probe: probe, severity: severity, config: cfg)
                for action in mapped {
                    _ = await runner.run(actionID: action.descriptor.id, trigger: .confirmed)
                }
            }

            // B2 Execute tier: the LLM-requested run-approval path. A tap on the
            // "Approve run of X?" banner runs THAT specific action id through the
            // SAME confirmed path (PolicyEngine bypasses the behavioural gates for
            // a confirmed run but still enforces reversibility + audits).
            notifs.wireRunActionByID { [weak self] actionID in
                guard let runner = await self?.actionRunner else { return }
                _ = await runner.run(actionID: actionID, trigger: .confirmed)
            }
        }

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

        // Q10 AUTO path: on a mapped alert, run any auto-enabled action(s)
        // through the policy gate chain. The runner itself short-circuits
        // when no action is auto-enabled (the Q3 default), so this is inert
        // until the user opts in. After a run, refresh the popover's recent-
        // actions mirror from the audit log.
        if let actionRunner {
            let runnerRef = actionRunner
            await eventBus.subscribe { [weak weakState] event in
                // Whole Task isolated to MainActor: actor hops (runnerRef) are
                // explicit awaits, and weakState is touched on its own actor —
                // no cross-isolation "sending" (which the macos-15 SDK's
                // region analyzer flags, unlike the local 26 SDK).
                Task { @MainActor [weak weakState] in
                    await runnerRef.handleAlertEvent(event)
                    let recent = await runnerRef.recentAudit(20)
                    weakState?.recentActions = recent
                }
            }
        }

        // B1b: load (or first-launch-generate) the bridge bearer token from its
        // 0600 sidecar file, SEPARATE from the world-readable config.toml. Every
        // write (ack / set_probe_config, REST + MCP) now requires this token as
        // `Authorization: Bearer <token>`; reads stay open on loopback. Wired
        // into the ChannelHost below. `loadOrCreate` never throws — a persist
        // failure still yields an in-memory token (writes fail closed).
        let bridgeAuth = BridgeAuth.loadOrCreate()

        // B2 Execute tier: the human-tap approval poster handed to the bridge.
        // When an LLM-requested real run needs confirmation, `RESTHandlers` calls
        // this → the notification center posts an "Approve run of X?" banner whose
        // tap runs THAT id via the confirmed path (wired above). `notifs` is a
        // @MainActor class (implicitly Sendable); the closure awaits into it.
        let notifsForApproval = notifs
        let approvalRequester: @Sendable (String, String) async -> Void = { actionID, actionName in
            await notifsForApproval.postRunApproval(actionID: actionID, actionName: actionName)
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
                allowWrites: initial.mcp.allowWrites,
                // Q10: read-only actions surface (/actions + uzora_list_actions).
                actionRunner: actionRunner,
                // Phase 5: read-only diagnosis surface (/findings + /verdict +
                // the MCP read tools). Always present (created unconditionally
                // above); the diagnosis loop feeds it each cycle.
                diagnosisStore: diagnosisStore,
                // B1a (plan D-L4): parallel diagnosis fan-out onto /stream.
                diagnosisBus: diagnosisBus,
                // B1b: bearer-token gate for the write tier.
                bridgeAuth: bridgeAuth,
                // B2 Execute tier: master switch + optional unattended capability
                // token (both from [mcp] config), plus the human-tap approval poster.
                executeEnabled: initial.mcp.executeEnabled,
                capabilityToken: initial.mcp.capabilityToken,
                approvalRequester: approvalRequester
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
            Task { @MainActor in
                await registryRef.reconfigure(config)
                let updatedNames = await registryRef.registeredNames()
                uiStateForRoster.probeNames = updatedNames
            }
        }
        await loader.observe(reconfigureOnReload, skippingInitial: true)

        // ── B3 proactive-push (plan D-L1) ───────────────────────────────
        // The ONE zero-egress event→local-agent producer. Subscribes to BOTH
        // the WatchdogEvent bus and the DiagnosisEventBus, maps each event to a
        // unified PushEvent, and (filter → coalesce → rate-limit → dispatch)
        // pushes via the two ZERO-EGRESS backends (local-exec + outbox). OFF BY
        // DEFAULT: built unconditionally, but only STARTED when [push] enabled,
        // so out-of-the-box behavior is unchanged. NO outbound HTTP anywhere.
        // The [push] config is Settings/config-ONLY (no bridge write mutates it).
        let pushAudit: PushAuditLog?
        do {
            pushAudit = try PushAuditLog(retentionDays: initial.general.logRetentionDays)
            await pushAudit?.startRotationLoop()
        } catch {
            log.error("PushAuditLog init failed: \(String(describing: error), privacy: .public); proactive-push disabled")
            pushAudit = nil
        }
        self.pushAuditLog = pushAudit
        if let pushAudit {
            // Build the outbox backend from the config path (a directory; empty
            // ⇒ default under Application Support). Built regardless of the
            // enable flag — dispatch gates on `outbox_enabled`.
            let outboxDir = PushOutbox.resolveDirectory(from: initial.push.outboxPath)
            let outbox = try? PushOutbox(baseDir: outboxDir, retentionDays: initial.general.logRetentionDays)
            await outbox?.startRotationLoop()
            self.pushOutbox = outbox

            let producer = ProactivePush(
                eventBus: eventBus,
                diagnosisBus: diagnosisBus,
                config: initial.push,
                audit: pushAudit,
                outbox: outbox
            )
            self.proactivePush = producer
            // Only subscribe when enabled (off by default ⇒ zero behavior change).
            if initial.push.enabled {
                await producer.start()
            }
            // Hot-reload: flip enabled on ⇒ start, off ⇒ stop; new floor/kinds/
            // backend flags apply live. Skip the initial synchronous fire (the
            // producer was just built from `initial`).
            let producerRef = producer
            await loader.observe({ config in
                Task { await producerRef.reconfigure(config.push) }
            }, skippingInitial: true)
        }

        // Drive a 5s refresh loop that pulls metric sparklines + process
        // top-N from the live samplers. Phase 5 stops short of SQLite —
        // these are session-local ring buffers.
        startMetricRefresh()

        // Phase 4: drive the proactive diagnosis cycle (engine → watchdog →
        // verdict → two-track finding notifications). Dormant + no-op until a
        // store-backed engine exists; never blocks bootstrap.
        startDiagnosisLoop()

        // A4b: two SLOW opt-in-block samplers, both OFF the 5s refresh tick.
        // The 7-day loader pulls the durable CPU-temp series and buckets it
        // hourly (~5 min cadence); the net sampler runs nettop (~60s cadence).
        // Each writes UIState off an async task, so neither blocks the UI.
        startSevenDayHistoryLoader()
        startTopNetSampler()

        // A4c: resolve the per-probe runnable-action map ONCE at boot so a
        // restart that seeded persisted alerts already offers the finding-card
        // "Fix" button, without waiting for the first 5s refresh tick.
        await recomputeAvailableActions()
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

    /// Phase 4: run a diagnosis cycle every 30s. MIRRORS `startMetricRefresh`
    /// EXACTLY — a plain `Timer` whose tick spawns a `Task { @MainActor in
    /// await … }`, which is the proven cross-SDK-safe loop pattern (no
    /// non-isolated async `Task`, no `Task.detached` touching `@MainActor`
    /// state). The cycle itself no-ops until the engine + watchdog are wired.
    @MainActor
    private func startDiagnosisLoop() {
        diagnosisTimer?.invalidate()
        diagnosisTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.runDiagnosisCycle()
            }
        }
    }

    /// A4b: is the given content block PRESENT and VISIBLE in the current
    /// effective layout? The two slow samplers gate their expensive work on this
    /// (D-C3.iv). `bindings == nil` (pre-bootstrap) ⇒ not visible — the blocks
    /// are default-OFF, so this is the correct conservative default.
    @MainActor
    private func blockVisible(_ kind: WidgetKind) -> Bool {
        guard let bindings else { return false }
        return blockIsVisibleInLayout(
            kind,
            preset: bindings.current.ui.popover.preset,
            layoutJSON: bindings.current.ui.popover.layoutJSON
        )
    }

    /// A4b: reload the 7-day history series on a SLOW ~5 min cadence (NEVER on
    /// the 5s refresh). A 7-day pull at 5s cadence is ≈120k rows, so this is far
    /// too heavy for the visual tick. Same cross-SDK-safe loop idiom as the
    /// other timers (a plain `Timer` whose tick spawns a `Task { @MainActor }`);
    /// the store query itself runs off-main on the `MetricsStore` actor. Also
    /// kicks ONE load right after launch so the block paints without a 5 min
    /// wait. No-ops (leaves the series empty ⇒ block hides) when no store.
    @MainActor
    private func startSevenDayHistoryLoader() {
        sevenDayTimer?.invalidate()
        sevenDayTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.loadSevenDayHistory()
            }
        }
        // Eager first load (off-main query) so the chart isn't blank for 5 min.
        Task { @MainActor [weak self] in
            await self?.loadSevenDayHistory()
        }
    }

    /// One 7-day load: pull the durable CPU-temperature series
    /// (`cpu_temp`/`temp_c`) for the last 7 days off the store actor, bucket it
    /// to ~hourly averages (~168 points for a full week) in a detached task —
    /// so the ~120k-row reduce stays off the main actor — then publish. An empty
    /// result leaves `sevenDayHistory` empty and the block hides.
    @MainActor
    private func loadSevenDayHistory() async {
        // D-C3.iv: skip the heavy 7-day query + bucketing while the block is
        // hidden (default-OFF). Gates BOTH the eager launch load and each tick;
        // enabling the block in Settings starts populating on the next tick.
        guard blockVisible(.sevenDayChart) else { return }
        guard let store = self.metricsStore else { return }
        let now = Date()
        let from = now.addingTimeInterval(-7 * 24 * 3600)
        let samples = (try? await store.query(probe: "cpu_temp", from: from, to: now, name: "temp_c")) ?? []
        // Bucket off-main: `Sample` is Sendable and `bucketHourly` is a pure
        // nonisolated free function, so the heavy reduce never runs on the UI.
        let bucketed = await Task.detached(priority: .utility) { bucketHourly(samples) }.value
        uiState.sevenDayHistory = bucketed
    }

    /// A4b: sample the top-network talkers on a SLOW 60s cadence (NEVER on the
    /// 5s refresh). `TopNetworkProcessProbe.liveSample()` runs `nettop` on a
    /// background queue behind a checked continuation with a 3s hard timeout, so
    /// the `await` merely suspends — the main actor is never blocked. Same
    /// cross-SDK-safe loop idiom; an eager first sample paints the block soon
    /// after launch.
    @MainActor
    private func startTopNetSampler() {
        topNetTimer?.invalidate()
        topNetTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.sampleTopNet()
            }
        }
        Task { @MainActor [weak self] in
            await self?.sampleTopNet()
        }
    }

    /// One nettop sample: take the top-5 processes by total throughput and map
    /// them to `NetSnap`. On timeout / error / no-data the sampler returns an
    /// empty array — we KEEP the last published value (never clear on a transient
    /// miss, never crash).
    @MainActor
    private func sampleTopNet() async {
        // D-C3.iv: only spawn the expensive nettop subprocess when the Network
        // block is actually visible (default-OFF ⇒ no extra nettop/min for a
        // hidden block). Gates BOTH the eager sample and each tick; enabling the
        // block in Settings starts sampling on the next 60s tick.
        guard blockVisible(.topNet) else { return }
        let entries = await TopNetworkProcessProbe.liveSample()
        guard !entries.isEmpty else { return }  // keep last on timeout/error
        let ranked = entries.sorted { $0.totalBytesPerSec > $1.totalBytesPerSec }
        let top = ranked.prefix(5).map { entry in
            UIState.NetSnap(
                pid: entry.pid,
                command: entry.command,
                bytesInPerSec: entry.bytesInPerSec,
                bytesOutPerSec: entry.bytesOutPerSec
            )
        }
        uiState.topNetProcesses = Array(top)
    }

    /// One diagnosis cycle: run every detector over loaded history, diff the
    /// findings against the prior set, push the derived `Verdict` into the
    /// UI, and emit two-track finding notifications for the diff events.
    ///
    /// Degrades gracefully: with no engine/watchdog (e.g. no MetricsStore) it
    /// returns immediately. Every actor hop is an explicit `await`; the whole
    /// body runs on the MainActor.
    @MainActor
    private func runDiagnosisCycle() async {
        guard let engine = diagnosisEngine, let fw = findingWatchdog else { return }
        let findings = await engine.diagnose()
        let events = await fw.step(currentFindings: findings)
        // Derive the verdict ONCE and use it for BOTH surfaces so the popover
        // (UIState) and the channel snapshot (DiagnosisStore → /findings +
        // /verdict) can never disagree.
        let verdict = Verdict.derive(from: findings)
        uiState.applyDiagnosis(verdict)
        await diagnosisStore?.update(findings: findings, verdict: verdict)

        // B1a (plan D-L4): mirror the finding diff + verdict-level transition
        // onto the parallel `/stream` fan-out — an ADDITION alongside the
        // existing notify + store-update paths (which stay intact). Emitting a
        // finding event onto the bus is a no-op when nothing subscribes.
        if let diagBus = self.diagnosisBus {
            for ev in events {
                await diagBus.emit(.finding(ev))
            }
            // `verdict_changed` fires ONLY on an actual aggregate LEVEL move —
            // an idempotent same-level cycle emits nothing.
            if verdict.level != lastVerdictLevel {
                await diagBus.emit(.verdictChanged(
                    from: lastVerdictLevel,
                    to: verdict.level,
                    headline: verdict.headline
                ))
                lastVerdictLevel = verdict.level
            }
        }

        if let notifs = self.notifications {
            // Use the SAME notifications config the rest of bootstrap reads.
            // `bindings` is set early in bootstrap and never cleared, so the
            // guard is defensive: fall back to defaults if it's somehow nil.
            let config = self.bindings?.current.notifications ?? NotificationsConfig()
            for ev in events {
                _ = await notifs.notifyFinding(event: ev, config: config)
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

        // A4a expanded catalog: hydrate the five opt-in tiles from their
        // already-persisted Rail-1 series. `memoryUsed%` needs nothing here —
        // it reuses the live `memoryLabel`/`memoryHistory` populated below. A
        // series with no rows leaves the tile's "—"/placeholder (e.g. GPU on a
        // VM, where `gpu_util_pct` is never written).
        let gpuSamples = (try? await store.query(probe: "system_signals", from: fromTs, to: now, name: "gpu_util_pct")) ?? []
        if !gpuSamples.isEmpty {
            uiState.gpuHistory = gpuSamples.suffix(60).map { $0.value }
            if let last = gpuSamples.last { uiState.gpuLabel = String(format: "%.0f%%", last.value) }
        }

        let coresSamples = (try? await store.query(probe: "system_signals", from: fromTs, to: now, name: "cores_pinned")) ?? []
        if !coresSamples.isEmpty {
            uiState.coresPinnedHistory = coresSamples.suffix(60).map { $0.value }
            if let last = coresSamples.last { uiState.coresPinnedLabel = String(format: "%.0f", last.value) }
        }

        let swapSamples = (try? await store.query(probe: "system_signals", from: fromTs, to: now, name: "swapin_rate")) ?? []
        if !swapSamples.isEmpty {
            uiState.swapInHistory = swapSamples.suffix(60).map { $0.value }
            if let last = swapSamples.last { uiState.swapInLabel = String(format: "%.0f/s", last.value) }
        }

        let kernelSamples = (try? await store.query(probe: "kernel_task", from: fromTs, to: now, name: "cpu_pct")) ?? []
        if !kernelSamples.isEmpty {
            uiState.kernelTaskHistory = kernelSamples.suffix(60).map { $0.value }
            if let last = kernelSamples.last { uiState.kernelTaskLabel = String(format: "%.0f%%", last.value) }
        }
    }

    @MainActor
    private func refreshMetricsAndProcesses() async {
        // Phase 6: prefer persisted history (survives restart) and fall
        // back to live samplers below so day-zero charts still paint.
        await rehydrateSparklinesFromStore()

        // CPU temp.
        if let s = CPUTempProbe.sampleViaIOHID() {
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
        // One ProcessSampler.snapshotAll() per tick — shared by the
        // memory-pressure %, the top-mem list, and the top-cpu delta. (Was
        // sampled twice per 5s tick; a full PID walk is not free.)
        let snaps = ProcessSampler.snapshotAll()

        // Memory pressure: rough — used / total %. Kept for the later opt-in
        // used% catalog tile (A4); NOT the default Memory tile anymore.
        let totalBytes = ProcessSampler.hostTotalMemoryBytes()
        if totalBytes > 0 {
            let totalRSS = snaps.reduce(UInt64(0)) { $0 + $1.residentSizeBytes }
            let pct = Double(totalRSS) / Double(totalBytes) * 100
            uiState.recordMetric(probe: "memory", value: min(pct, 100))
        }

        // A2/D6: memory-pressure LEVEL — the CORRECT memory signal for the
        // default Memory tile (0 normal / 1 warn / 2 critical, the
        // `mem_pressure_level` ordinal). Live-sampled like the tiles above;
        // a `nil` read (abstain) leaves the last known level untouched.
        if let level = SystemSignals.readMemoryPressureLevel() {
            uiState.memPressureLevel = Int(level.ordinal)
        }

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

        // Q10: refresh the popover's recent-actions mirror so a confirmed
        // "Run" click (which doesn't go through the alert-event path) also
        // surfaces promptly, and so a fresh launch hydrates from the audit
        // log's restored tail.
        if let runner = self.actionRunner {
            let recent = await runner.recentAudit(20)
            uiState.recentActions = recent
        }

        // A4c: keep the popover's per-probe runnable-action map current with
        // the active alert set (periodic — the immediate paths are the alert
        // subscription + an ack), so a finding card can decide the "Fix" button
        // without touching the ActionRegistry actor from the view.
        await recomputeAvailableActions()
    }

    /// A4c: pre-resolve the runnable actions for the CURRENT active alerts'
    /// probes and publish them to `UIState.availableActionsByProbe`, so the
    /// popover's finding cards can decide the "Fix" button synchronously. Runs
    /// off the `ActionRegistry` actor (+ reads the live `[actions]` config); a
    /// no-op when the action subsystem is absent (audit-log init failed). Only
    /// probes with ≥1 eligible action are kept, so the map is empty on a clean
    /// machine.
    @MainActor
    private func recomputeAvailableActions() async {
        guard let actionRegistry = self.actionRegistry, let loader = self.loader else {
            return
        }
        let floors = probeSeverityFloors(uiState.activeAlerts)
        guard !floors.isEmpty else {
            if !uiState.availableActionsByProbe.isEmpty {
                uiState.availableActionsByProbe = [:]
            }
            return
        }
        let cfg = await loader.current.actions
        var map: [String: [ActionDescriptor]] = [:]
        for (probe, severity) in floors {
            let descriptors = await actionRegistry.descriptorsFor(
                probe: probe, severity: severity, config: cfg
            )
            if !descriptors.isEmpty { map[probe] = descriptors }
        }
        uiState.availableActionsByProbe = map
    }

    /// A4c CONFIRMED run from a popover "Fix" tap (plan D-L2). A direct UI tap
    /// IS the confirmation, so run with `trigger: .confirmed` — `PolicyEngine`
    /// bypasses the behavioural gates (enabled/power/focus/cooldown/rate) but
    /// still enforces reversibility and audits the outcome. Reuses the EXISTING
    /// `ActionRunner` (no new run/gate logic). Refreshes the recent-actions
    /// mirror so the run surfaces promptly in the popover.
    @MainActor
    fileprivate func runConfirmedAction(_ actionID: String) async {
        guard let runner = self.actionRunner else { return }
        _ = await runner.run(actionID: actionID, trigger: .confirmed)
        let recent = await runner.recentAudit(20)
        uiState.recentActions = recent
    }

    /// A4c per-alert ACK from a popover "Ack" tap. Non-destructive UI-state
    /// suppression via the EXISTING `StateStore` (does NOT touch the OS); hides
    /// the alert from `activeAlerts()`/REST/MCP/popover until it escalates or
    /// clears. Refreshes the popover's alert mirror + the action map afterwards
    /// so the acked alert (and any Fix button its probe fed) disappears at once.
    @MainActor
    fileprivate func acknowledgeAlert(_ alertID: Alert.ID) async {
        guard let store = self.stateStore else { return }
        _ = await store.acknowledgeResult(alertID)
        let active = await store.activeAlerts()
        uiState.apply(activeAlerts: active)
        await recomputeAvailableActions()
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
        let a = self.auditLog
        let pp = self.proactivePush
        let pa = self.pushAuditLog
        let po = self.pushOutbox
        metricsRetentionTask?.cancel()
        diagnosisTimer?.invalidate()
        sevenDayTimer?.invalidate()
        topNetTimer?.invalidate()
        Task {
            await h?.stop()
            await r?.stop()
            await l?.stopWatching()
            await m?.close()
            await a?.close()
            await pp?.stop()
            await pa?.close()
            await po?.close()
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

// MARK: - A4b: block-visibility gate (D-C3.iv)

/// Whether the given content block is PRESENT and VISIBLE in the effective
/// layout resolved from the persisted config (preset + optional customized
/// JSON). The A4b slow samplers gate their expensive work on this so a hidden
/// (default-OFF) block costs nothing — plan D-C3.iv: sample a widget's data only
/// when the widget is actually used. Pure + testable; reuses the same resolver
/// the popover renders through, so the gate can never disagree with what shows.
func blockIsVisibleInLayout(_ kind: WidgetKind, preset: String, layoutJSON: String) -> Bool {
    effectiveLayout(preset: preset, layoutJSON: layoutJSON)
        .blocks.first { $0.kind == kind }?.visible == true
}

// MARK: - A4b: 7-day client-side bucketing

/// Bucket a 7-day sample series into ~hourly averages (≈168 points for a full
/// week, at ANY poll cadence). There is no server-side downsample API and a
/// raw 7-day pull at the 5s cadence is ≈120k rows per series, so the popover
/// buckets client-side: samples are grouped by their floor-of-hour epoch bucket
/// and each bucket's `value`s are AVERAGED; the per-bucket averages are returned
/// ascending in time. Empty input ⇒ empty output (the `sevenDayChart` block then
/// hides). Pure + `nonisolated` so it can run off the main actor in a detached
/// task. Cross-SDK guard: the bucket size is a precomputed local (no multi-term
/// literal chain).
func bucketHourly(_ samples: [MetricsStore.Sample]) -> [Double] {
    if samples.isEmpty { return [] }
    let secondsPerHour = 3600.0
    var sums: [Int: Double] = [:]
    var counts: [Int: Int] = [:]
    for sample in samples {
        let bucket = Int(sample.at.timeIntervalSince1970 / secondsPerHour)
        sums[bucket, default: 0] += sample.value
        counts[bucket, default: 0] += 1
    }
    return sums.keys.sorted().map { bucket in
        let sum = sums[bucket] ?? 0
        let count = counts[bucket] ?? 1
        return sum / Double(count)
    }
}
