import Testing
import Foundation
@testable import uZora

/// Pure-function coverage for the Tier-A diagnosis signal sampler
/// (`SystemSignals`) and the metrics-only `SystemSignalsProbe`. Mirrors the
/// CPUTemp pattern: the hardware reads are exercised only for non-crash in
/// the live smoke suite; the decode / rate / cores-pinned MATH is tested here
/// with synthetic inputs.
@Suite("System signals — pure decode / rate / cores-pinned")
struct SystemSignalsTests {

    // MARK: - Memory-pressure LEVEL decode

    @Test func memPressure_decodesKnownLevels() {
        #expect(SystemSignals.decodeMemoryPressureLevel(1) == .normal)
        #expect(SystemSignals.decodeMemoryPressureLevel(2) == .warn)
        #expect(SystemSignals.decodeMemoryPressureLevel(4) == .critical)
    }

    @Test func memPressure_abstainsOnUnknown() {
        // 0 and 3 are not part of the {1,2,4} bitmask family → abstain.
        #expect(SystemSignals.decodeMemoryPressureLevel(0) == nil)
        #expect(SystemSignals.decodeMemoryPressureLevel(3) == nil)
        #expect(SystemSignals.decodeMemoryPressureLevel(99) == nil)
        #expect(SystemSignals.decodeMemoryPressureLevel(-1) == nil)
    }

    @Test func memPressure_ordinalLadder() {
        #expect(SystemSignals.MemoryPressureLevel.normal.ordinal == 0)
        #expect(SystemSignals.MemoryPressureLevel.warn.ordinal == 1)
        #expect(SystemSignals.MemoryPressureLevel.critical.ordinal == 2)
    }

    // MARK: - Swap-in RATE

    private func swap(_ ins: UInt64, _ t: TimeInterval) -> SystemSignals.SwapSample {
        SystemSignals.SwapSample(swapins: ins, sampledAt: Date(timeIntervalSince1970: t))
    }

    @Test func swapinRate_computesPagesPerSecond() {
        // +500 pages over 10 s = 50 pages/sec.
        let r = SystemSignals.swapinRate(previous: swap(1000, 0), current: swap(1500, 10))
        #expect(r != nil)
        #expect(abs((r ?? 0) - 50.0) < 1e-9)
    }

    @Test func swapinRate_zeroDeltaIsZeroRate() {
        let r = SystemSignals.swapinRate(previous: swap(2000, 0), current: swap(2000, 5))
        #expect(r == 0)
    }

    @Test func swapinRate_nonPositiveWallTimeAbstains() {
        #expect(SystemSignals.swapinRate(previous: swap(0, 10), current: swap(100, 10)) == nil)
        #expect(SystemSignals.swapinRate(previous: swap(0, 20), current: swap(100, 10)) == nil)
    }

    @Test func swapinRate_counterResetAbstains() {
        // Counter went backwards (boot / reset) → abstain, not a negative rate.
        #expect(SystemSignals.swapinRate(previous: swap(5000, 0), current: swap(10, 5)) == nil)
    }

    // MARK: - GPU utilization extraction

    @Test func gpuUtil_fromIntValue() {
        #expect(SystemSignals.gpuUtilization(from: ["Device Utilization %": 43]) == 43)
    }

    @Test func gpuUtil_fromNSNumber() {
        let dict: [String: Any] = ["Device Utilization %": NSNumber(value: 17)]
        #expect(SystemSignals.gpuUtilization(from: dict) == 17)
    }

    @Test func gpuUtil_absentKeyAbstains() {
        #expect(SystemSignals.gpuUtilization(from: ["Renderer Utilization %": 40]) == nil)
        #expect(SystemSignals.gpuUtilization(from: [:]) == nil)
    }

    @Test func gpuUtil_nonNumericAbstains() {
        #expect(SystemSignals.gpuUtilization(from: ["Device Utilization %": "high"]) == nil)
    }

    // MARK: - Per-core busy% + cores pinned

    private func ticks(_ u: UInt64, _ s: UInt64, _ n: UInt64, _ i: UInt64) -> SystemSignals.CoreTicks {
        SystemSignals.CoreTicks(user: u, system: s, nice: n, idle: i)
    }
    private func snap(_ cores: [SystemSignals.CoreTicks], _ t: TimeInterval) -> SystemSignals.CPUSnapshot {
        SystemSignals.CPUSnapshot(cores: cores, sampledAt: Date(timeIntervalSince1970: t))
    }

    @Test func perCoreBusy_computesDeltaPercents() {
        // Core 0: +90 busy / +10 idle over the interval → 90% busy.
        // Core 1: +10 busy / +90 idle → 10% busy.
        let prev = snap([ticks(0, 0, 0, 0), ticks(0, 0, 0, 0)], 0)
        let curr = snap([ticks(60, 20, 10, 10), ticks(5, 3, 2, 90)], 5)
        let busy = SystemSignals.perCoreBusyPercent(previous: prev, current: curr)
        #expect(busy != nil)
        #expect(abs((busy?[0] ?? 0) - 90.0) < 1e-9)
        #expect(abs((busy?[1] ?? 0) - 10.0) < 1e-9)
    }

    @Test func perCoreBusy_zeroActivityCoreIsZero() {
        // A core with no tick movement at all contributes 0%, not NaN.
        let prev = snap([ticks(100, 0, 0, 200)], 0)
        let curr = snap([ticks(100, 0, 0, 200)], 5)
        let busy = SystemSignals.perCoreBusyPercent(previous: prev, current: curr)
        #expect(busy == [0.0])
    }

    @Test func perCoreBusy_counterResetCoreIsZero() {
        // Busy/total went backwards on a core (reset) → that core reads 0%.
        let prev = snap([ticks(500, 0, 0, 500)], 0)
        let curr = snap([ticks(1, 0, 0, 1)], 5)
        let busy = SystemSignals.perCoreBusyPercent(previous: prev, current: curr)
        #expect(busy == [0.0])
    }

    @Test func perCoreBusy_topologyChangeAbstains() {
        let prev = snap([ticks(0, 0, 0, 0), ticks(0, 0, 0, 0)], 0)
        let curr = snap([ticks(1, 0, 0, 1)], 5) // core count changed
        #expect(SystemSignals.perCoreBusyPercent(previous: prev, current: curr) == nil)
    }

    @Test func perCoreBusy_emptyAbstains() {
        #expect(SystemSignals.perCoreBusyPercent(previous: snap([], 0), current: snap([], 5)) == nil)
    }

    @Test func coresPinned_countsAtOrAboveThreshold() {
        let busy = [98.0, 71.0, 70.0, 69.9, 5.0]
        #expect(SystemSignals.coresPinned(busyPercents: busy, threshold: 70) == 3)
        #expect(SystemSignals.coresPinned(busyPercents: busy, threshold: 99) == 0)
        #expect(SystemSignals.coresPinned(busyPercents: busy, threshold: 0) == 5)
    }

    // MARK: - Top own-uid process CPU% (probe pure helper)

    private func proc(_ pid: Int32, cpuNanos: UInt64, at t: TimeInterval) -> ProcessSampler.Snapshot {
        ProcessSampler.Snapshot(
            pid: pid, name: "p\(pid)", cpuTimeNanos: cpuNanos,
            residentSizeBytes: 0, virtualSizeBytes: 0,
            startTime: Date(timeIntervalSince1970: 0),
            sampledAt: Date(timeIntervalSince1970: t)
        )
    }

    @Test func topProcessCPU_picksHighestDelta() {
        // pid 10: +1s CPU over 1s wall = 100%. pid 20: +0.5s over 1s = 50%.
        let prev: [Int32: ProcessSampler.Snapshot] = [
            10: proc(10, cpuNanos: 0, at: 0),
            20: proc(20, cpuNanos: 0, at: 0),
        ]
        let curr = [
            proc(10, cpuNanos: 1_000_000_000, at: 1),
            proc(20, cpuNanos: 500_000_000, at: 1),
        ]
        let top = SystemSignalsProbe.topProcessCPUPercent(previous: prev, current: curr)
        #expect(top != nil)
        #expect(abs((top ?? 0) - 100.0) < 1e-6)
    }

    @Test func topProcessCPU_firstPollAbstains() {
        // No prior snapshots → no PID matched in both → nil.
        let curr = [proc(10, cpuNanos: 1_000_000_000, at: 1)]
        #expect(SystemSignalsProbe.topProcessCPUPercent(previous: [:], current: curr) == nil)
    }

    @Test func topProcessCPU_ignoresUnmatchedPIDs() {
        // pid 99 is new this poll (no prior) → skipped; only pid 10 counts.
        let prev: [Int32: ProcessSampler.Snapshot] = [10: proc(10, cpuNanos: 0, at: 0)]
        let curr = [
            proc(99, cpuNanos: 9_000_000_000, at: 1), // huge, but unmatched → ignored
            proc(10, cpuNanos: 200_000_000, at: 1),    // +0.2s/1s = 20%
        ]
        let top = SystemSignalsProbe.topProcessCPUPercent(previous: prev, current: curr)
        #expect(abs((top ?? 0) - 20.0) < 1e-6)
    }
}

/// Probe-level behavioural coverage: metrics-only (no alerts), rate signals
/// appear from the second poll, and each signal degrades independently.
@Suite("SystemSignalsProbe — metrics-only behaviour")
struct SystemSignalsProbeBehaviourTests {

    /// A fully-synthetic sampler set the test mutates between polls.
    private func makeProbe(
        memoryPressure: @escaping @Sendable () -> SystemSignals.MemoryPressureLevel? = { .normal },
        swap: @escaping @Sendable () -> SystemSignals.SwapSample? = { nil },
        gpu: @escaping @Sendable () -> Int? = { 25 },
        cpu: @escaping @Sendable () -> SystemSignals.CPUSnapshot? = { nil },
        procs: @escaping @Sendable () -> [ProcessSampler.Snapshot] = { [] }
    ) -> SystemSignalsProbe {
        SystemSignalsProbe(
            pollInterval: .seconds(5),
            pinnedThreshold: 70,
            samplers: .init(
                memoryPressure: memoryPressure, swap: swap,
                gpuUtilization: gpu, cpuSnapshot: cpu, processSnapshots: procs
            )
        )
    }

    @Test func run_emitsNoAlerts() async throws {
        let probe = makeProbe()
        let alerts = try await probe.run()
        #expect(alerts.isEmpty)
    }

    @Test func currentMetrics_levelAndGpuOnFirstPoll() async {
        // mem-pressure level + gpu are point samples → present from poll 1.
        // swap/cores/top_proc need a delta → absent on poll 1.
        let probe = makeProbe(
            memoryPressure: { .warn },
            swap: { SystemSignals.SwapSample(swapins: 100, sampledAt: Date(timeIntervalSince1970: 0)) },
            gpu: { 42 }
        )
        let m = await probe.currentMetrics()
        #expect(m["mem_pressure_level"] == 1)   // .warn ordinal
        #expect(m["gpu_util_pct"] == 42)
        #expect(m["swapin_rate"] == nil)        // needs second poll
        #expect(m["cores_pinned"] == nil)
        #expect(m["top_proc_cpu_pct"] == nil)
    }

    @Test func currentMetrics_swapRateAppearsOnSecondPoll() async {
        // Two polls with an advancing counter + advancing clock → a rate lands
        // on the second poll.
        final class Clock: @unchecked Sendable { var ins: UInt64 = 1000; var t: TimeInterval = 0 }
        let c = Clock()
        let probe = makeProbe(swap: {
            SystemSignals.SwapSample(swapins: c.ins, sampledAt: Date(timeIntervalSince1970: c.t))
        })

        _ = await probe.currentMetrics()        // poll 1 — primes prevSwap
        c.ins = 1500; c.t = 10                   // +500 pages over 10 s = 50/s
        let m2 = await probe.currentMetrics()
        #expect(m2["swapin_rate"] != nil)
        #expect(abs((m2["swapin_rate"] ?? 0) - 50.0) < 1e-9)
    }

    @Test func currentMetrics_coresPinnedAppearsOnSecondPoll() async {
        final class State: @unchecked Sendable {
            var cores: [SystemSignals.CoreTicks]
            var t: TimeInterval = 0
            init(_ cores: [SystemSignals.CoreTicks]) { self.cores = cores }
        }
        // Two cores; on the second poll core 0 gains 95% busy, core 1 gains 10%.
        let st = State([
            SystemSignals.CoreTicks(user: 0, system: 0, nice: 0, idle: 0),
            SystemSignals.CoreTicks(user: 0, system: 0, nice: 0, idle: 0),
        ])
        let probe = makeProbe(cpu: {
            SystemSignals.CPUSnapshot(cores: st.cores, sampledAt: Date(timeIntervalSince1970: st.t))
        })

        _ = await probe.currentMetrics()        // poll 1 — primes prevCPU
        st.cores = [
            SystemSignals.CoreTicks(user: 90, system: 5, nice: 0, idle: 5),   // 95% busy → pinned
            SystemSignals.CoreTicks(user: 8, system: 2, nice: 0, idle: 90),   // 10% busy → not
        ]
        st.t = 5
        let m2 = await probe.currentMetrics()
        #expect(m2["cores_pinned"] == 1)
    }

    @Test func currentMetrics_independentDegradation() async {
        // GPU sampler abstains (nil) but mem-pressure still lands — one broken
        // signal must not blank the others.
        let probe = makeProbe(memoryPressure: { .critical }, gpu: { nil })
        let m = await probe.currentMetrics()
        #expect(m["mem_pressure_level"] == 2)   // .critical ordinal
        #expect(m["gpu_util_pct"] == nil)
    }

    @Test func currentMetrics_allAbstainYieldsEmpty() async {
        let probe = makeProbe(memoryPressure: { nil }, swap: { nil }, gpu: { nil }, cpu: { nil }, procs: { [] })
        let m = await probe.currentMetrics()
        #expect(m.isEmpty)
    }
}
