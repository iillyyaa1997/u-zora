import Foundation
import os

/// Holds registered probes and runs them on a schedule.
///
/// Phase 3 adds the actual scheduler loop: for each registered probe a
/// long-lived `Task` is spawned that calls `probe.run()` on its
/// `pollInterval` (multiplied by the current `PowerProfile.pollMultiplier`),
/// feeds the result into `Watchdog.step(currentAlerts:)`, then forwards
/// the emitted events to the `EventBus`.
///
/// Severity-floor suppression happens *at the EventBus boundary* so that
/// the Watchdog's diff state remains authoritative regardless of profile
/// — when the user comes back from Focus mode we still know which warn
/// alerts had been suppressed and can replay them on the first non-Focus
/// poll. Suppression in Phase 3 simply drops the event; Phase 4 will add
/// a "deferred" channel for replay.
public actor ProbeRegistry {
    private var probes: [String: any Probe] = [:]
    private var lastSnapshotByProbe: [String: [Alert]] = [:]
    private var lastAggregateSnapshot: [Alert] = []
    private var isRunning: Bool = false

    private var probeTasks: [String: Task<Void, Never>] = [:]
    private var currentProfile: PowerProfile = .defaultMapping(for: .acConnectedLidOpen)
    private var watchdog: Watchdog?
    private var eventBus: EventBus?
    private var stateStore: StateStore?

    /// Hot-reload serialization (see `reconfigure(_:)`). `pendingConfig` is the
    /// most-recently-requested config; `reconfiguring` guards the single
    /// in-flight applier so overlapping reloads can't apply a stale snapshot
    /// last.
    private var pendingConfig: UZoraConfig?
    private var reconfiguring = false

    /// Config-derived per-probe poll-interval overrides (the *base* cadence,
    /// before the PowerProfile multiplier is applied). Populated from
    /// `ProbeOverride.pollIntervalSec`; a probe absent from this map keeps
    /// its built-in `Probe.pollInterval`. See `effectiveInterval(for:)`.
    private var configPollOverrides: [String: Duration] = [:]

    /// Phase 6: optional metrics sink. When set, `runProbeOnce` flushes
    /// `Probe.currentMetricRows()` to the store every poll.
    private var metricsStore: MetricsStore?

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "registry")

    public init() {}

    /// Register a probe. Replaces any existing probe with the same `name`.
    public func register(_ probe: any Probe) {
        probes[probe.name] = probe
    }

    /// Currently registered probe names (stable order: sorted).
    public func registeredNames() -> [String] {
        probes.keys.sorted()
    }

    /// Number of currently registered probes.
    public var count: Int {
        probes.count
    }

    /// Push a new power profile from the monitor. The scheduler tasks
    /// pick this up on the next `Task.sleep` boundary — there's no
    /// pre-emption mid-poll.
    public func updatePowerProfile(_ profile: PowerProfile) {
        let previousState = currentProfile.state
        currentProfile = profile
        if previousState != profile.state {
            log.info("Power profile updated: \(previousState.rawValue, privacy: .public) → \(profile.state.rawValue, privacy: .public); pollMultiplier=\(profile.pollMultiplier, privacy: .public)")
        }
    }

    public func powerProfile() -> PowerProfile { currentProfile }

    /// Attach a `MetricsStore` so each probe's `currentMetricRows()` is
    /// persisted on every poll. Optional — without it, alerts still flow
    /// to EventBus / channels but no historical metrics are recorded.
    public func attachMetricsStore(_ store: MetricsStore) {
        self.metricsStore = store
    }

    /// Begin scheduled polling.
    ///
    /// Wires `watchdog` and `eventBus` if provided (Phase 3 production
    /// call). Without them the scheduler still runs but events have
    /// nowhere to go — useful for Phase 2-compatible smoke tests.
    /// Idempotent.
    public func start(
        watchdog: Watchdog? = nil,
        eventBus: EventBus? = nil,
        metricsStore: MetricsStore? = nil
    ) {
        guard !isRunning else { return }
        isRunning = true
        self.watchdog = watchdog
        self.eventBus = eventBus
        if let metricsStore { self.metricsStore = metricsStore }

        let probeCount = probes.count
        let names = registeredNames().joined(separator: ", ")
        log.info("ProbeRegistry starting with \(probeCount, privacy: .public) probes: \(names, privacy: .public)")

        for (name, probe) in probes {
            spawnProbeTask(name: name, probe: probe)
        }
    }

    /// Stop scheduled polling. Cancels every probe task and waits for
    /// them to settle. Idempotent.
    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        for (_, task) in probeTasks {
            task.cancel()
        }
        for (_, task) in probeTasks {
            _ = await task.value
        }
        probeTasks.removeAll()
        log.info("ProbeRegistry stopped")
    }

    /// Snapshot of the most recent alert set across all probes.
    public func snapshot() -> [Alert] {
        lastAggregateSnapshot
    }

    /// Snapshot for a single probe by name. Useful for tests asserting a
    /// scheduler tick actually flowed through.
    public func snapshotForProbe(_ name: String) -> [Alert]? {
        lastSnapshotByProbe[name]
    }

    // MARK: - Per-probe loop

    private func spawnProbeTask(name: String, probe: any Probe) {
        let task = Task<Void, Never> { [weak self] in
            // Stagger startup a touch so the very first tick of every
            // probe doesn't slam the CPU at t=0.
            try? await Task.sleep(for: .milliseconds(Int.random(in: 50...500)))
            while !Task.isCancelled {
                await self?.runProbeOnce(name: name, probe: probe)

                let interval = await self?.effectiveInterval(for: probe) ?? probe.pollInterval
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    // Cancelled — exit loop.
                    return
                }
            }
        }
        probeTasks[name] = task
    }

    private func effectiveInterval(for probe: any Probe) -> Duration {
        // Base cadence = config override (if any) else the probe's built-in
        // pollInterval; the PowerProfile multiplier is then layered on top.
        // So effective = (configOverride ?? probe.pollInterval) × multiplier.
        let base = configPollOverrides[probe.name] ?? probe.pollInterval
        return currentProfile.effectiveInterval(base)
    }

    /// Testable accessor: the *base* poll interval a probe schedules at,
    /// i.e. the config override if present else the probe's built-in
    /// cadence — **without** the PowerProfile multiplier. Returns nil if
    /// no probe by that name is registered.
    func configuredBaseInterval(forProbeNamed name: String) -> Duration? {
        guard let probe = probes[name] else { return nil }
        return configPollOverrides[name] ?? probe.pollInterval
    }

    /// Testable accessor: the *effective* poll interval for a registered
    /// probe under the current PowerProfile (config base × multiplier).
    /// Returns nil if no probe by that name is registered.
    func effectiveInterval(forProbeNamed name: String) -> Duration? {
        guard let probe = probes[name] else { return nil }
        return effectiveInterval(for: probe)
    }

    /// Testable accessor: the currently-registered probe instance by name
    /// (so tests can introspect the constructed Thresholds via the probe's
    /// own pure `severity(...)` functions). Internal — `@testable import`.
    func registeredProbe(named name: String) -> (any Probe)? {
        probes[name]
    }

    /// Attach a `StateStore` so `reconfigure(_:)` can refresh the probe
    /// roster and synthesise clears for alerts belonging to probes that a
    /// reload disables. Optional — without it, reconfigure still rebuilds
    /// the probe set and scheduler.
    public func attachStateStore(_ store: StateStore) {
        self.stateStore = store
    }

    /// Test affordance: wire the Watchdog / EventBus / StateStore the same
    /// way `start(...)` would, but WITHOUT spawning the scheduler tasks —
    /// so a test can exercise `reconfigure(_:)`'s disabled-probe clear
    /// path deterministically without live probes racing the assertions.
    /// Internal — `@testable import`.
    func wireDependenciesForTesting(
        watchdog: Watchdog? = nil,
        eventBus: EventBus? = nil,
        stateStore: StateStore? = nil
    ) {
        if let watchdog { self.watchdog = watchdog }
        if let eventBus { self.eventBus = eventBus }
        if let stateStore { self.stateStore = stateStore }
    }

    private func runProbeOnce(name: String, probe: any Probe) async {
        do {
            let alerts = try await probe.run()
            await ingestProbeResult(name: name, alerts: alerts)
            await harvestMetrics(name: name, probe: probe)
        } catch {
            log.error("probe \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Phase 6: pull current numeric metrics from the probe and persist
    /// them. Silent if no store is attached or the probe returns no
    /// metrics.
    private func harvestMetrics(name: String, probe: any Probe) async {
        guard let store = metricsStore else { return }
        let rows = await probe.currentMetricRows()
        guard !rows.isEmpty else { return }
        let now = Date()
        var samples: [MetricsStore.Sample] = []
        samples.reserveCapacity(rows.reduce(0) { $0 + $1.values.count })
        for row in rows {
            for (metricName, value) in row.values {
                samples.append(MetricsStore.Sample(
                    probe: name,
                    key: row.key,
                    name: metricName,
                    value: value,
                    at: now
                ))
            }
        }
        do {
            try await store.recordSamples(samples)
        } catch {
            log.error("metrics persist failed for \(name, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func ingestProbeResult(name: String, alerts: [Alert]) async {
        lastSnapshotByProbe[name] = alerts
        // Aggregate: union over all probes' latest snapshots (StateStore consumers
        // still want the full picture).
        let aggregate = lastSnapshotByProbe.values.flatMap { $0 }
        lastAggregateSnapshot = aggregate

        guard let watchdog else { return }
        // Per-probe diff: only this probe's slice of state changes here, so
        // cold-start partial-aggregate ticks don't false-clear alerts from
        // other probes that haven't run yet.
        let events = await watchdog.step(probe: name, currentAlerts: alerts)
        guard let eventBus else { return }

        // Severity-floor suppression at the bus boundary.
        let floor = currentProfile.alertSeverityFloor
        let surviving = events.filter { Self.shouldEmit($0, floor: floor) }
        for event in surviving {
            await eventBus.emit(event)
        }
    }

    /// True if an event should clear the severity floor for the current
    /// profile. `cleared` events always pass — once an alert resolves the
    /// UI should learn about it regardless of profile floor.
    public static func shouldEmit(_ event: WatchdogEvent, floor: Severity) -> Bool {
        switch event {
        case .cleared:
            return true
        case .appeared(let alert):
            return alert.severity >= floor
        case .escalated(let alert, _):
            return alert.severity >= floor
        }
    }

    // MARK: - Phase 2/3 factory

    /// Build a registry pre-populated with the MVP probe set:
    /// disk, cpu_temp, thermal, battery, smart, fan, plus the four
    /// Phase 3 process probes (kernel_task, top_cpu, top_mem, top_net).
    ///
    /// Probes that cannot collect data on the host (e.g. fanless device,
    /// missing SMART properties) are still registered — they just emit
    /// empty alert arrays. This keeps the registry shape stable so the
    /// scheduler + UI can iterate `registeredNames()` without conditional
    /// plumbing.
    public static func `default`() -> ProbeRegistry {
        let registry = ProbeRegistry()
        Task { await registry.installDefaultProbes(config: nil) }
        return registry
    }

    /// Synchronous variant of `default()` that awaits the install. Use
    /// from `async` contexts (e.g. app launch) when you need the registry
    /// to be fully populated before the next operation.
    ///
    /// `config == nil` → register all 10 MVP probes with their built-in
    /// `.default` thresholds and no poll overrides (preserves the legacy
    /// behaviour relied on by unit tests + the E2E synthetic-probe path).
    /// `config != nil` → register only the **enabled** probes, each built
    /// with config-derived thresholds, and seed `configPollOverrides`.
    public static func defaultPopulated(config: UZoraConfig? = nil) async -> ProbeRegistry {
        let registry = ProbeRegistry()
        await registry.installDefaultProbes(config: config)
        return registry
    }

    /// (Re)build the probe set from `config`. Pure with respect to
    /// scheduling — callers must `start()` (or `reconfigure(_:)` does it).
    ///
    /// Probe registration rules:
    /// - `enabled == false` (or the whole override absent in a non-nil
    ///   config that opted a probe out) → the probe is NOT registered.
    /// - `warn_threshold` / `critical_threshold` are mapped per-probe to
    ///   that probe's `Thresholds` (single-dimension probes only — see the
    ///   mapping table below). Multi-dimensional / non-numeric probes keep
    ///   their built-in thresholds.
    /// - `poll_interval_sec` is recorded in `configPollOverrides` and
    ///   applied as the scheduling base in `effectiveInterval(for:)`.
    private func installDefaultProbes(config: UZoraConfig?) {
        probes.removeAll()
        configPollOverrides.removeAll()

        guard let config else {
            // nil → legacy all-defaults path (10 probes, built-in thresholds).
            register(DiskFreeProbe())
            register(CPUTempProbe())
            register(ThermalPressureProbe())
            register(BatteryProbe())
            register(SMARTProbe())
            register(FanRPMProbe())
            register(KernelTaskProbe())
            register(TopCPUProcessProbe())
            register(TopMemoryProcessProbe())
            register(TopNetworkProcessProbe())
            registerSyntheticIfRequested()
            return
        }

        let p = config.probes

        // ── disk ──────────────────────────────────────────────────────
        // Config units: PERCENT free (Settings shows "15" meaning 15%).
        // The probe wants a *fraction* 0..1, so divide by 100. Thresholds are
        // clamped at this read boundary so a hand-edited config can't inject a
        // non-finite / out-of-range value.
        if p.disk.enabled {
            let base = DiskFreeProbe.Thresholds.default
            let t = DiskFreeProbe.Thresholds(
                warnFreeFraction:     Self.clampedThreshold(p.disk.warnThreshold, unit: .percent, label: "disk.warn_threshold").map { $0 / 100.0 } ?? base.warnFreeFraction,
                criticalFreeFraction: Self.clampedThreshold(p.disk.criticalThreshold, unit: .percent, label: "disk.critical_threshold").map { $0 / 100.0 } ?? base.criticalFreeFraction
            )
            register(DiskFreeProbe(thresholds: t))
            applyPollOverride(p.disk, name: "disk")
        }

        // ── cpu_temp ──────────────────────────────────────────────────
        // Config units: degrees Celsius — direct (read-boundary clamped).
        if p.cpuTemp.enabled {
            let base = CPUTempProbe.Thresholds.default
            let t = CPUTempProbe.Thresholds(
                warnC:     Self.clampedThreshold(p.cpuTemp.warnThreshold, unit: .celsius, label: "cpu_temp.warn_threshold") ?? base.warnC,
                criticalC: Self.clampedThreshold(p.cpuTemp.criticalThreshold, unit: .celsius, label: "cpu_temp.critical_threshold") ?? base.criticalC
            )
            register(CPUTempProbe(thresholds: t))
            applyPollOverride(p.cpuTemp, name: "cpu_temp")
        }

        // ── thermal ───────────────────────────────────────────────────
        // NOTE: ThermalPressureProbe has NO thresholds (discrete
        // ProcessInfo.ThermalState mapping). Only enabled + pollInterval
        // apply; warn/critical_threshold are ignored.
        if p.thermal.enabled {
            register(ThermalPressureProbe())
            applyPollOverride(p.thermal, name: "thermal")
        }

        // ── battery ───────────────────────────────────────────────────
        // NOTE: multi-dimensional thresholds (charge %, cycle count,
        // condition string). A single generic warn/critical can't address
        // them cleanly, so threshold overrides are intentionally NOT
        // exposed in MVP — only enabled + pollInterval apply.
        if p.battery.enabled {
            register(BatteryProbe())
            applyPollOverride(p.battery, name: "battery")
        }

        // ── smart ─────────────────────────────────────────────────────
        // NOTE: multi-dimensional thresholds (available-spare %, used %,
        // media errors, critical-warning bitmask). Not config-exposed in
        // MVP — only enabled + pollInterval apply.
        if p.smart.enabled {
            register(SMARTProbe())
            applyPollOverride(p.smart, name: "smart")
        }

        // ── fan ───────────────────────────────────────────────────────
        // NOTE: fan thresholds are two-sided (low RPM / high RPM); a
        // generic single warn/critical doesn't fit a low+high band, so
        // threshold overrides are NOT config-exposed in MVP — only enabled
        // + pollInterval apply.
        if p.fan.enabled {
            register(FanRPMProbe())
            applyPollOverride(p.fan, name: "fan")
        }

        // ── kernel_task ───────────────────────────────────────────────
        // Config units: CPU percent — direct to warn/critical cpu fields.
        // Sustained-window seconds keep their built-in defaults.
        if p.kernelTask.enabled {
            let base = KernelTaskProbe.Thresholds.default
            let t = KernelTaskProbe.Thresholds(
                warnCpuPct:               Self.clampedThreshold(p.kernelTask.warnThreshold, unit: .percent, label: "kernel_task.warn_threshold") ?? base.warnCpuPct,
                warnSustainedSeconds:     base.warnSustainedSeconds,
                criticalCpuPct:           Self.clampedThreshold(p.kernelTask.criticalThreshold, unit: .percent, label: "kernel_task.critical_threshold") ?? base.criticalCpuPct,
                criticalSustainedSeconds: base.criticalSustainedSeconds
            )
            register(KernelTaskProbe(thresholds: t))
            applyPollOverride(p.kernelTask, name: "kernel_task")
        }

        // ── top_cpu ───────────────────────────────────────────────────
        // Config units: CPU percent — direct. Sustained-window seconds +
        // topN keep their built-in defaults.
        if p.topCPU.enabled {
            let base = TopCPUProcessProbe.Thresholds.default
            let t = TopCPUProcessProbe.Thresholds(
                warnPct:                  Self.clampedThreshold(p.topCPU.warnThreshold, unit: .percent, label: "top_cpu.warn_threshold") ?? base.warnPct,
                warnSustainedSeconds:     base.warnSustainedSeconds,
                criticalPct:              Self.clampedThreshold(p.topCPU.criticalThreshold, unit: .percent, label: "top_cpu.critical_threshold") ?? base.criticalPct,
                criticalSustainedSeconds: base.criticalSustainedSeconds,
                topN:                     base.topN
            )
            register(TopCPUProcessProbe(thresholds: t))
            applyPollOverride(p.topCPU, name: "top_cpu")
        }

        // ── top_mem ───────────────────────────────────────────────────
        // Config units: GIGABYTES (Settings-friendly). The probe's
        // Thresholds are RSS in *bytes* (UInt64), so multiply GB by
        // 1024^3 to get bytes (binary GiB, matching the probe's built-in
        // defaults which use 8 * 1024^3 / 16 * 1024^3). topN keeps default.
        if p.topMem.enabled {
            let base = TopMemoryProcessProbe.Thresholds.default
            // Clamp GiB into 0…1024 at the read boundary, THEN convert (the
            // conversion is itself trap-guarded, but clamping first keeps the
            // documented range + a clear log over a silent UInt64.max).
            let t = TopMemoryProcessProbe.Thresholds(
                warnRssBytes:     Self.clampedThreshold(p.topMem.warnThreshold, unit: .gibibytes, label: "top_mem.warn_threshold").map(Self.gibToBytes) ?? base.warnRssBytes,
                criticalRssBytes: Self.clampedThreshold(p.topMem.criticalThreshold, unit: .gibibytes, label: "top_mem.critical_threshold").map(Self.gibToBytes) ?? base.criticalRssBytes,
                topN:             base.topN
            )
            register(TopMemoryProcessProbe(thresholds: t))
            applyPollOverride(p.topMem, name: "top_mem")
        }

        // ── top_net ───────────────────────────────────────────────────
        // Config units: MEGABYTES per second. The probe's Thresholds are
        // bytes/sec (UInt64), so multiply MB/s by 1024^2 (binary MiB,
        // matching the probe's built-in 50 * 1024^2 / 200 * 1024^2
        // defaults). Sustained-window seconds keep their defaults.
        if p.topNet.enabled {
            let base = TopNetworkProcessProbe.Thresholds.default
            let t = TopNetworkProcessProbe.Thresholds(
                warnBytesPerSec:          Self.clampedThreshold(p.topNet.warnThreshold, unit: .mibPerSec, label: "top_net.warn_threshold").map(Self.mibToBytes) ?? base.warnBytesPerSec,
                warnSustainedSeconds:     base.warnSustainedSeconds,
                criticalBytesPerSec:      Self.clampedThreshold(p.topNet.criticalThreshold, unit: .mibPerSec, label: "top_net.critical_threshold").map(Self.mibToBytes) ?? base.criticalBytesPerSec,
                criticalSustainedSeconds: base.criticalSustainedSeconds
            )
            register(TopNetworkProcessProbe(thresholds: t))
            applyPollOverride(p.topNet, name: "top_net")
        }

        // E2E synthetic probe is NOT part of ProbesConfig — it always
        // registers when the env var is set, regardless of config.
        registerSyntheticIfRequested()
    }

    /// Record a probe's `poll_interval_sec` override (if any) as a
    /// `Duration`. Non-positive values are ignored (keep probe default); a
    /// value beyond the sane 24h ceiling is clamped (defensive read-boundary
    /// — the write path already rejects these, but a hand-edited config.toml
    /// bypasses the write path entirely).
    private func applyPollOverride(_ override: ProbeOverride, name: String) {
        if let sec = override.pollIntervalSec, sec > 0 {
            let clamped = ConfigSanitizer.clampPollIntervalSec(sec)
            configPollOverrides[name] = .seconds(clamped)
        }
    }

    /// Read-boundary threshold clamp: nil passes through (keep probe default),
    /// a present value is run through `ConfigSanitizer.clampThreshold` (which
    /// coerces out-of-range / drops non-finite + logs). Centralises the
    /// per-probe read-side guard so a hand-edited config can't poison a probe.
    static func clampedThreshold(_ value: Double?, unit: ConfigSanitizer.ThresholdUnit, label: String) -> Double? {
        guard let value else { return nil }
        return ConfigSanitizer.clampThreshold(value, unit: unit, label: label)
    }

    /// Convert binary GiB → bytes, guarding against trap-inducing inputs.
    /// `UInt64(double.rounded())` traps on negative, NaN/∞, or values beyond
    /// `UInt64.max`. A hand-edited config (e.g. top_mem warn_threshold = -1)
    /// reaches here through the read boundary; rather than crash-loop the
    /// daemon we clamp to a safe value: negative/NaN → 0, overflow → UInt64.max.
    static func gibToBytes(_ gib: Double) -> UInt64 {
        clampToBytes(gib * 1024.0 * 1024.0 * 1024.0)
    }

    /// Convert binary MiB → bytes/sec, with the same trap guards as
    /// `gibToBytes`.
    static func mibToBytes(_ mib: Double) -> UInt64 {
        clampToBytes(mib * 1024.0 * 1024.0)
    }

    /// Clamp an already-scaled byte count (Double) into the UInt64 range
    /// without trapping. The largest exactly-representable Double strictly
    /// below `UInt64.max` is 1.8446744073709550e19 (UInt64.max itself,
    /// 1.8446744073709552e19, is not exactly representable and rounds UP past
    /// the max, so `UInt64(_:)` would trap on it — hence the strict `<` guard).
    static func clampToBytes(_ value: Double) -> UInt64 {
        guard value.isFinite, value >= 0 else { return 0 }
        let maxAsDouble = 18_446_744_073_709_549_568.0 // < UInt64.max, exactly representable
        if value >= maxAsDouble { return UInt64.max }
        return UInt64(value.rounded())
    }

    /// E2E-only: a deterministic always-firing probe, registered solely
    /// when UZORA_E2E_SYNTHETIC_ALERT is set. No-op in production.
    private func registerSyntheticIfRequested() {
        if let synthetic = SyntheticAlertProbe.fromEnvironment() {
            register(synthetic)
        }
    }

    // MARK: - Hot reload

    /// Apply a freshly-loaded `UZoraConfig` to the running registry.
    ///
    /// Steps:
    /// 1. Cancel every running probe task.
    /// 2. Compute which probes are being **dropped** (registered before,
    ///    not after) and synthesise `cleared` events for any of their
    ///    outstanding alerts so they don't linger in Watchdog / StateStore
    ///    forever (a disabled probe never ticks to report an empty set, so
    ///    nothing else would ever clear them).
    /// 3. Rebuild the probe set + poll overrides from the new config.
    /// 4. Refresh the StateStore probe roster.
    /// 5. Restart the scheduler (if it was running).
    ///
    /// Safe to call whether or not `start()` has run yet — if the scheduler
    /// was idle the probe set is simply rebuilt and left idle.
    ///
    /// **Serialized + last-write-wins.** The hot-reload chain fires this from
    /// detached `Task`s (the ConfigLoader direct-broadcast AND the file-watcher
    /// reload both trigger it), so two reloads in quick succession used to spawn
    /// overlapping `reconfigure` invocations. Because the actual apply has
    /// `await` suspension points, an *older* config snapshot could finish last
    /// and win — a lost update (verified: rapid disable→enable left the probe
    /// dropped despite config.toml saying enabled). We now record the latest
    /// requested config and drain it through a single in-flight applier, so the
    /// terminal probe set always reflects the most-recently-submitted config.
    public func reconfigure(_ config: UZoraConfig) async {
        // Record the newest desired config. If an apply is already draining,
        // it will pick this up — return without starting a second one.
        pendingConfig = config
        if reconfiguring { return }
        reconfiguring = true
        defer { reconfiguring = false }
        // Drain: apply the latest pending config until none is queued. A
        // config that arrives *during* an apply (set on `pendingConfig` by a
        // concurrent caller) is handled by the next loop iteration, so the
        // last writer always wins and we never apply a stale snapshot last.
        while let next = pendingConfig {
            pendingConfig = nil
            await applyReconfigure(next)
        }
    }

    /// The actual rebuild. Only ever invoked from the serialized drain loop in
    /// `reconfigure(_:)`, so its `await` points can't interleave with another
    /// apply.
    private func applyReconfigure(_ config: UZoraConfig) async {
        let wasRunning = isRunning

        // 1. Stop current tasks (mirrors stop() but keeps wiring refs).
        for (_, task) in probeTasks { task.cancel() }
        for (_, task) in probeTasks { _ = await task.value }
        probeTasks.removeAll()
        isRunning = false

        // 2. Determine dropped probes BEFORE we rebuild the set.
        let oldNames = Set(probes.keys)
        let newNames = Self.enabledProbeNames(for: config)
        let droppedNames = oldNames.subtracting(newNames)

        // Synthesise clears for alerts owned by dropped probes. We feed the
        // Watchdog an empty set *for that probe* — its per-probe diff emits
        // `.cleared` for each outstanding alert AND purges them from the
        // persisted snapshot, so a relaunch won't resurrect them.
        if !droppedNames.isEmpty {
            var clears: [WatchdogEvent] = []
            if let watchdog {
                for name in droppedNames.sorted() {
                    clears.append(contentsOf: await watchdog.step(probe: name, currentAlerts: []))
                }
            }
            // Drop their cached snapshots from the aggregate too.
            for name in droppedNames {
                lastSnapshotByProbe[name] = nil
            }
            lastAggregateSnapshot = lastSnapshotByProbe.values.flatMap { $0 }

            // Update the user-visible surfaces: StateStore (drives /alerts,
            // /status, MCP, popover) gets the clears directly+awaited so
            // they're gone deterministically; the EventBus gets them too so
            // JSONL/SSE record the transition and the popover refreshes
            // promptly. (`cleared` always clears the severity floor.)
            if let stateStore {
                for ev in clears { await stateStore.ingest(ev) }
            }
            if let eventBus {
                for ev in clears { await eventBus.emit(ev) }
            }
            if !clears.isEmpty {
                log.info("reconfigure dropped \(droppedNames.count, privacy: .public) probe(s) [\(droppedNames.sorted().joined(separator: ", "), privacy: .public)], cleared \(clears.count, privacy: .public) stale alert(s)")
            }
        }

        // 3. Rebuild from config.
        installDefaultProbes(config: config)

        // 4. Refresh StateStore roster.
        if let stateStore {
            let infos = registeredNames().map { name -> StateStore.ProbeInfo in
                let secs = (configuredBaseInterval(forProbeNamed: name)?.components.seconds).map(Double.init) ?? 0
                return StateStore.ProbeInfo(name: name, pollIntervalSeconds: secs, lastRunAt: nil)
            }
            await stateStore.setProbes(infos)
        }

        log.info("reconfigured: \(self.probes.count, privacy: .public) probe(s) registered [\(self.registeredNames().joined(separator: ", "), privacy: .public)]")

        // 5. Restart scheduler if it had been running.
        if wasRunning {
            isRunning = true
            for (name, probe) in probes {
                spawnProbeTask(name: name, probe: probe)
            }
        }
    }

    /// The set of probe names a given config would register from the MVP
    /// ProbesConfig (enabled probes only). Excludes the env-gated synthetic
    /// probe — that is keyed off the environment, not config, and persists
    /// across reconfigures untouched.
    static func enabledProbeNames(for config: UZoraConfig) -> Set<String> {
        let p = config.probes
        // Derive from the single descriptor table — one enabled-check per
        // descriptor rather than ten hand-spelled `if`s that can drift.
        var names = Set(
            ProbesConfig.descriptors
                .filter { p[keyPath: $0.path].enabled }
                .map(\.name)
        )
        // Synthetic probe survives reconfigure if the env var is set.
        if SyntheticAlertProbe.fromEnvironment() != nil {
            names.insert("synthetic")
        }
        return names
    }
}
