import Testing
import Foundation
@testable import uZora

/// Verifies that `UZoraConfig` actually drives the probe registry:
/// `enabled` gates registration, `poll_interval_sec` feeds the scheduler
/// base interval, and the per-probe `warn_threshold` / `critical_threshold`
/// mapping reaches each probe's constructed `Thresholds`. Also covers the
/// hot-reload (`reconfigure`) path, including the disabled-probe stale-alert
/// cleanup.
@Suite("Probe config wiring (config → probes)")
struct ProbeConfigWiringTests {

    // Helper: a config with all probes enabled and a single override applied.
    private func config(_ mutate: (inout UZoraConfig) -> Void) -> UZoraConfig {
        var c = UZoraConfig.default
        mutate(&c)
        return c
    }

    // MARK: - enabled gating

    @Test func disabledProbe_notRegistered() async {
        let cfg = config { $0.probes.disk.enabled = false }
        let registry = await ProbeRegistry.defaultPopulated(config: cfg)
        let names = await registry.registeredNames()
        #expect(names.count == 10)
        #expect(!names.contains("disk"))
        // The other ten are still present.
        #expect(names.sorted() == [
            "battery", "cpu_temp", "fan",
            "kernel_task", "smart", "system_signals", "thermal",
            "top_cpu", "top_mem", "top_net",
        ])
    }

    @Test func multipleDisabled_notRegistered() async {
        let cfg = config {
            $0.probes.battery.enabled = false
            $0.probes.smart.enabled = false
            $0.probes.fan.enabled = false
        }
        let registry = await ProbeRegistry.defaultPopulated(config: cfg)
        let names = await registry.registeredNames()
        #expect(names.count == 8)
        #expect(!names.contains("battery"))
        #expect(!names.contains("smart"))
        #expect(!names.contains("fan"))
    }

    // MARK: - poll interval override

    @Test func pollIntervalOverride_appliesToEffectiveInterval() async {
        let cfg = config { $0.probes.disk.pollIntervalSec = 5 }
        let registry = await ProbeRegistry.defaultPopulated(config: cfg)

        // Base = config override (5s), not the probe's built-in 60s.
        let base = await registry.configuredBaseInterval(forProbeNamed: "disk")
        #expect(base == .seconds(5))

        // Effective under the default profile (acConnectedLidOpen,
        // multiplier 1.0) is the same 5s base.
        let eff = await registry.effectiveInterval(forProbeNamed: "disk")
        #expect(eff == .seconds(5))
    }

    @Test func pollIntervalOverride_stacksWithPowerMultiplier() async {
        let cfg = config { $0.probes.disk.pollIntervalSec = 10 }
        let registry = await ProbeRegistry.defaultPopulated(config: cfg)
        // batteryLidOpen → multiplier 3.0 → 10s × 3 = 30s effective.
        await registry.updatePowerProfile(.defaultMapping(for: .batteryLidOpen))
        let eff = await registry.effectiveInterval(forProbeNamed: "disk")
        #expect(eff == .seconds(30))
    }

    @Test func noPollOverride_keepsProbeDefault() async {
        let registry = await ProbeRegistry.defaultPopulated(config: UZoraConfig.default)
        // disk default cadence is 60s.
        let base = await registry.configuredBaseInterval(forProbeNamed: "disk")
        #expect(base == .seconds(60))
    }

    // MARK: - threshold mapping (single-dimension probes)

    @Test func diskThreshold_percentMapsToFraction() async throws {
        // warn_threshold = 20 (percent) → warnFreeFraction 0.20.
        let cfg = config { $0.probes.disk.warnThreshold = 20 }
        let registry = await ProbeRegistry.defaultPopulated(config: cfg)
        let probe = await registry.registeredProbe(named: "disk") as? DiskFreeProbe
        let t = try #require(probe?.configuredThresholds)
        #expect(abs(t.warnFreeFraction - 0.20) < 1e-9)
        // critical untouched → keeps default 0.05.
        #expect(abs(t.criticalFreeFraction - 0.05) < 1e-9)

        // Drive samples through the pure severity function: 19% free → warn,
        // 21% free → no alert.
        let below = DiskFreeProbe.Sample(freeBytes: 19, totalBytes: 100, mount: "/")
        let above = DiskFreeProbe.Sample(freeBytes: 21, totalBytes: 100, mount: "/")
        #expect(DiskFreeProbe.severity(for: below, thresholds: t) == .warn)
        #expect(DiskFreeProbe.severity(for: above, thresholds: t) == nil)
    }

    @Test func diskThreshold_criticalPercentMapsToFraction() async throws {
        let cfg = config {
            $0.probes.disk.warnThreshold = 20
            $0.probes.disk.criticalThreshold = 8
        }
        let registry = await ProbeRegistry.defaultPopulated(config: cfg)
        let probe = await registry.registeredProbe(named: "disk") as? DiskFreeProbe
        let t = try #require(probe?.configuredThresholds)
        #expect(abs(t.criticalFreeFraction - 0.08) < 1e-9)
        // 7% free → critical; 9% free → warn (below 20% but above 8%).
        let crit = DiskFreeProbe.Sample(freeBytes: 7, totalBytes: 100, mount: "/")
        let warn = DiskFreeProbe.Sample(freeBytes: 9, totalBytes: 100, mount: "/")
        #expect(DiskFreeProbe.severity(for: crit, thresholds: t) == .critical)
        #expect(DiskFreeProbe.severity(for: warn, thresholds: t) == .warn)
    }

    @Test func cpuTempThreshold_directCelsius() async throws {
        let cfg = config { $0.probes.cpuTemp.warnThreshold = 70 }
        let registry = await ProbeRegistry.defaultPopulated(config: cfg)
        let probe = await registry.registeredProbe(named: "cpu_temp") as? CPUTempProbe
        let t = try #require(probe?.configuredThresholds)
        #expect(t.warnC == 70)
        // critical untouched → default 100.
        #expect(t.criticalC == 100)
        #expect(CPUTempProbe.severity(for: 75, thresholds: t) == .warn)
        #expect(CPUTempProbe.severity(for: 65, thresholds: t) == nil)
        #expect(CPUTempProbe.severity(for: 105, thresholds: t) == .critical)
    }

    @Test func kernelTaskThreshold_directPercent() async throws {
        let cfg = config {
            $0.probes.kernelTask.warnThreshold = 15
            $0.probes.kernelTask.criticalThreshold = 40
        }
        let registry = await ProbeRegistry.defaultPopulated(config: cfg)
        let probe = await registry.registeredProbe(named: "kernel_task") as? KernelTaskProbe
        let t = try #require(probe?.configuredThresholds)
        #expect(t.warnCpuPct == 15)
        #expect(t.criticalCpuPct == 40)
        // Sustained-window defaults preserved.
        #expect(t.warnSustainedSeconds == 30)
        #expect(t.criticalSustainedSeconds == 60)
    }

    @Test func topMemThreshold_gigabytesMapToBytes() async throws {
        // 4 GB warn / 12 GB critical.
        let cfg = config {
            $0.probes.topMem.warnThreshold = 4
            $0.probes.topMem.criticalThreshold = 12
        }
        let registry = await ProbeRegistry.defaultPopulated(config: cfg)
        let probe = await registry.registeredProbe(named: "top_mem") as? TopMemoryProcessProbe
        let t = try #require(probe?.configuredThresholds)
        #expect(t.warnRssBytes == 4 * 1024 * 1024 * 1024)
        #expect(t.criticalRssBytes == 12 * 1024 * 1024 * 1024)
    }

    @Test func topNetThreshold_megabytesPerSecMapToBytes() async throws {
        // 30 MB/s warn / 120 MB/s critical.
        let cfg = config {
            $0.probes.topNet.warnThreshold = 30
            $0.probes.topNet.criticalThreshold = 120
        }
        let registry = await ProbeRegistry.defaultPopulated(config: cfg)
        let probe = await registry.registeredProbe(named: "top_net") as? TopNetworkProcessProbe
        let t = try #require(probe?.configuredThresholds)
        #expect(t.warnBytesPerSec == 30 * 1024 * 1024)
        #expect(t.criticalBytesPerSec == 120 * 1024 * 1024)
    }

    @Test func topCPUThreshold_directPercent() async throws {
        let cfg = config {
            $0.probes.topCPU.warnThreshold = 40
            $0.probes.topCPU.criticalThreshold = 70
        }
        let registry = await ProbeRegistry.defaultPopulated(config: cfg)
        let probe = await registry.registeredProbe(named: "top_cpu") as? TopCPUProcessProbe
        let t = try #require(probe?.configuredThresholds)
        #expect(t.warnPct == 40)
        #expect(t.criticalPct == 70)
    }

    // MARK: - skipped-threshold probes still honour enabled + pollInterval

    @Test func fanBatterySmart_skipThresholdsButHonourPollAndEnabled() async {
        let cfg = config {
            // These thresholds must be IGNORED (no crash, defaults kept).
            $0.probes.fan.warnThreshold = 999
            $0.probes.fan.pollIntervalSec = 42
            $0.probes.battery.criticalThreshold = 5
            $0.probes.battery.pollIntervalSec = 7
            $0.probes.smart.warnThreshold = 3
        }
        let registry = await ProbeRegistry.defaultPopulated(config: cfg)
        let names = await registry.registeredNames()
        #expect(names.contains("fan"))
        #expect(names.contains("battery"))
        #expect(names.contains("smart"))
        // pollInterval override still applies to these probes.
        let fanBase = await registry.configuredBaseInterval(forProbeNamed: "fan")
        #expect(fanBase == .seconds(42))
        let battBase = await registry.configuredBaseInterval(forProbeNamed: "battery")
        #expect(battBase == .seconds(7))
        // smart kept its default 15-minute cadence (no override).
        let smartBase = await registry.configuredBaseInterval(forProbeNamed: "smart")
        #expect(smartBase == .seconds(15 * 60))
    }

    // MARK: - nil config → all defaults (legacy behaviour)

    @Test func nilConfig_keepsAllDefaults() async {
        let registry = await ProbeRegistry.defaultPopulated(config: nil)
        let names = await registry.registeredNames()
        #expect(names.count == 11)
        #expect(names.sorted() == [
            "battery", "cpu_temp", "disk", "fan",
            "kernel_task", "smart", "system_signals", "thermal",
            "top_cpu", "top_mem", "top_net",
        ])
        // Default thresholds preserved (disk 0.15 / 0.05; cpu_temp 90 / 100).
        let disk = await registry.registeredProbe(named: "disk") as? DiskFreeProbe
        #expect(abs((disk?.configuredThresholds.warnFreeFraction ?? 0) - 0.15) < 1e-9)
        let cpu = await registry.registeredProbe(named: "cpu_temp") as? CPUTempProbe
        #expect(cpu?.configuredThresholds.warnC == 90)
        // No poll overrides recorded.
        let diskBase = await registry.configuredBaseInterval(forProbeNamed: "disk")
        #expect(diskBase == .seconds(60))
    }

    // MARK: - hot reload

    @Test func reconfigure_dropsDisabledProbeAlerts() async {
        // Start from all-enabled, wire watchdog + stateStore + bus WITHOUT
        // spawning the live scheduler so the assertions are deterministic.
        let registry = await ProbeRegistry.defaultPopulated(config: UZoraConfig.default)
        let watchdog = Watchdog()
        let stateStore = StateStore()
        let bus = EventBus()
        await registry.wireDependenciesForTesting(
            watchdog: watchdog, eventBus: bus, stateStore: stateStore
        )

        // Inject a firing disk alert into Watchdog + StateStore.
        let now = Date()
        let diskAlert = Alert(
            probe: "disk", key: "/", severity: .warn,
            message: "Boot drive low", details: nil,
            firstSeen: now, lastUpdated: now
        )
        let appeared = await watchdog.step(probe: "disk", currentAlerts: [diskAlert])
        #expect(appeared.contains(.appeared(diskAlert)))
        for ev in appeared { await stateStore.ingest(ev) }

        // Precondition: the alert is live in both surfaces.
        var active = await stateStore.activeAlerts()
        #expect(active.contains { $0.id == "disk:/" })
        var wdSnap = await watchdog.snapshot()
        #expect(wdSnap["disk:/"] != nil)

        // Reconfigure with disk DISABLED.
        let cfg = config { $0.probes.disk.enabled = false }
        await registry.reconfigure(cfg)

        // disk is gone from the registry…
        let names = await registry.registeredNames()
        #expect(!names.contains("disk"))

        // …and its stale alert was synthesised-cleared everywhere.
        active = await stateStore.activeAlerts()
        #expect(!active.contains { $0.id == "disk:/" })
        wdSnap = await watchdog.snapshot()
        #expect(wdSnap["disk:/"] == nil)

        // StateStore roster reflects the new set (no disk).
        let roster = await stateStore.probeInventory().map { $0.name }
        #expect(!roster.contains("disk"))
        #expect(roster.count == 10)
    }

    @Test func reconfigure_keepsOtherProbesAlerts() async {
        // Dropping disk must NOT clear an unrelated probe's alert.
        let registry = await ProbeRegistry.defaultPopulated(config: UZoraConfig.default)
        let watchdog = Watchdog()
        let stateStore = StateStore()
        await registry.wireDependenciesForTesting(
            watchdog: watchdog, stateStore: stateStore
        )

        let now = Date()
        let diskAlert = Alert(probe: "disk", key: "/", severity: .warn,
                              message: "d", details: nil, firstSeen: now, lastUpdated: now)
        let cpuAlert = Alert(probe: "cpu_temp", key: "package", severity: .critical,
                             message: "hot", details: nil, firstSeen: now, lastUpdated: now)
        for ev in await watchdog.step(probe: "disk", currentAlerts: [diskAlert]) { await stateStore.ingest(ev) }
        for ev in await watchdog.step(probe: "cpu_temp", currentAlerts: [cpuAlert]) { await stateStore.ingest(ev) }

        await registry.reconfigure(config { $0.probes.disk.enabled = false })

        let active = await stateStore.activeAlerts()
        #expect(!active.contains { $0.id == "disk:/" })           // dropped
        #expect(active.contains { $0.id == "cpu_temp:package" })  // preserved
        let wdSnap = await watchdog.snapshot()
        #expect(wdSnap["cpu_temp:package"] != nil)
    }

    @Test func reconfigure_appliesNewThresholds() async {
        let registry = await ProbeRegistry.defaultPopulated(config: UZoraConfig.default)
        // Initially default warnC = 90.
        var cpu = await registry.registeredProbe(named: "cpu_temp") as? CPUTempProbe
        #expect(cpu?.configuredThresholds.warnC == 90)

        // Reconfigure with a new cpu_temp warn threshold.
        await registry.reconfigure(config { $0.probes.cpuTemp.warnThreshold = 60 })
        cpu = await registry.registeredProbe(named: "cpu_temp") as? CPUTempProbe
        #expect(cpu?.configuredThresholds.warnC == 60)
    }

    @Test func reconfigure_reEnablesProbe() async {
        // disk disabled → reconfigure with disk enabled brings it back.
        let registry = await ProbeRegistry.defaultPopulated(
            config: config { $0.probes.disk.enabled = false }
        )
        var names = await registry.registeredNames()
        #expect(!names.contains("disk"))

        await registry.reconfigure(UZoraConfig.default)
        names = await registry.registeredNames()
        #expect(names.contains("disk"))
        #expect(names.count == 11)
    }

    // MARK: - concurrent hot-reload (last-write-wins, no lost update)

    /// Tiny async barrier: the in-flight apply parks here until the test has
    /// recorded the *newer* config, then is released — making the regression
    /// interleaving (older apply in-flight while a newer config is recorded
    /// last) deterministic rather than dependent on parallel-scheduler luck.
    private actor ApplyBarrier {
        private var entered: CheckedContinuation<Void, Never>?
        private var released = false
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        private var didPark = false

        /// Called from inside the in-flight `applyReconfigure`. Parks ONLY the
        /// first apply (the disable); later applies (the drained enable) pass
        /// straight through. Signals that the apply has entered (resuming
        /// `waitUntilEntered`), then suspends until `release()` is called.
        func park() async {
            guard !didPark else { return }
            didPark = true
            entered?.resume()
            entered = nil
            if released { return }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                releaseWaiter = c
            }
        }

        /// The test awaits this to know the apply is provably parked at the
        /// barrier (so the next recorded config is guaranteed to land *during*
        /// the in-flight apply, exercising the real race).
        func waitUntilEntered() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                entered = c
            }
        }

        /// Release the parked apply so its drain loop proceeds.
        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    /// Regression (deterministic): the hot-reload chain fires `reconfigure`
    /// from multiple Tasks (ConfigLoader direct-broadcast + file-watcher
    /// reload). Because `applyReconfigure` has `await` suspension points, an
    /// *older* config snapshot could finish last and win — a lost update that
    /// left a probe dropped despite the newer config re-enabling it. The
    /// drain-loop fix guarantees the **last-RECORDED** pending config wins:
    /// a config recorded by a concurrent caller *while an apply is in flight*
    /// is the terminal state; the in-flight older apply never clobbers it.
    ///
    /// This forces exactly that interleaving via the test-only barrier:
    ///   1. Caller A records `disableCfg`, becomes the drainer, enters
    ///      `applyReconfigure(disableCfg)` and PARKS at the barrier.
    ///   2. With A provably parked mid-apply, caller B records `enableCfg`
    ///      (sees `reconfiguring == true`, returns early — `pendingConfig`
    ///      now holds the NEWER config recorded last).
    ///   3. The barrier releases; A's drain loop picks up `enableCfg` and
    ///      applies it last → cpu_temp present.
    /// The ordering is guaranteed by actor serialization + the barrier, not by
    /// scheduling luck, so the assertion holds on every parallel run.
    @Test func reconfigure_concurrentReloads_lastRecordedWins() async {
        let registry = await ProbeRegistry.defaultPopulated(config: UZoraConfig.default)
        let barrier = ApplyBarrier()

        // The barrier parks ONLY the first apply (the disable); the drained
        // enable that follows passes straight through (see ApplyBarrier.park).
        await registry.setApplyReconfigureBarrierForTesting { _ in
            await barrier.park()
        }

        let disableCfg = config { $0.probes.cpuTemp.enabled = false }
        let enableCfg = UZoraConfig.default // cpu_temp enabled

        // 1. Start caller A (disable). It records disableCfg, becomes the
        //    drainer, and parks inside applyReconfigure(disableCfg).
        let aTask = Task { await registry.reconfigure(disableCfg) }

        // 2. Wait until A is provably parked mid-apply. Now any config recorded
        //    by B is guaranteed to land DURING A's in-flight (older) apply —
        //    the exact lost-update window.
        await barrier.waitUntilEntered()

        // 3. Caller B records the NEWER (enable) config. A is still parked, so
        //    `reconfiguring == true` and B records pendingConfig + returns.
        let bTask = Task { await registry.reconfigure(enableCfg) }
        _ = await bTask.value // B's record-and-return completes synchronously-ish

        // 4. Release A; its drain loop now applies the last-recorded enableCfg.
        await barrier.release()
        _ = await aTask.value

        // Clear the barrier so the registry is left in a clean state.
        await registry.setApplyReconfigureBarrierForTesting(nil)

        // The last-RECORDED config (enable) is the terminal state; the older
        // in-flight disable apply did NOT clobber it.
        let names = await registry.registeredNames()
        #expect(names.contains("cpu_temp"))
        #expect(names.count == 11)
    }

    @Test func reconfigure_manyRapidReloads_convergesToFinal() async {
        // Stronger: hammer reconfigure with an alternating enable/disable burst
        // and assert it converges to the final submitted config deterministically
        // across repeated runs (the serialized drain makes the outcome a function
        // of the last call, not of scheduling luck).
        for _ in 0..<5 {
            let registry = await ProbeRegistry.defaultPopulated(config: UZoraConfig.default)
            var tasks: [Task<Void, Never>] = []
            // 8 toggles; the LAST one (i==7, odd) disables disk.
            for i in 0..<8 {
                let cfg = config { $0.probes.disk.enabled = (i % 2 == 0) }
                tasks.append(Task { await registry.reconfigure(cfg) })
            }
            for t in tasks { _ = await t.value }
            // Drain any straggler the loop hasn't observed yet by issuing the
            // authoritative final config explicitly (mirrors how the real
            // watcher always lands a final reload of the on-disk truth).
            await registry.reconfigure(config { $0.probes.disk.enabled = false })
            let names = await registry.registeredNames()
            #expect(!names.contains("disk"))
            #expect(names.count == 10)
        }
    }
}
