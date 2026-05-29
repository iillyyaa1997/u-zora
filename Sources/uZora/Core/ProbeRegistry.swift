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
        currentProfile.effectiveInterval(probe.pollInterval)
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
        Task { await registry.installDefaultProbes() }
        return registry
    }

    /// Synchronous variant of `default()` that awaits the install. Use
    /// from `async` contexts (e.g. app launch) when you need the registry
    /// to be fully populated before the next operation.
    public static func defaultPopulated() async -> ProbeRegistry {
        let registry = ProbeRegistry()
        await registry.installDefaultProbes()
        return registry
    }

    private func installDefaultProbes() {
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
        // E2E-only: a deterministic always-firing probe, registered solely
        // when UZORA_E2E_SYNTHETIC_ALERT is set. No-op in production.
        if let synthetic = SyntheticAlertProbe.fromEnvironment() {
            register(synthetic)
        }
    }
}
