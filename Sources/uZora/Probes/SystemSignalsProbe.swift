import Foundation
import os

/// Metrics-only Tier-A probe that persists the proactive-diagnosis layer's
/// in-process system signals (Phase 1). It emits **no alerts** — `run()`
/// always returns `[]`. It is pure metric collection that the Phase-2
/// `DiagnosisEngine` consumes from `MetricsStore` history; the detectors,
/// findings, and verdict live in later phases.
///
/// Persisted metrics (one row, keyed at the probe's canonical key):
///  - `mem_pressure_level` — 0 normal / 1 warn / 2 critical (the ordinal of
///    `SystemSignals.MemoryPressureLevel`; the CORRECT memory signal, not
///    swap size).
///  - `swapin_rate` — swap-in pages/sec (delta of the cumulative counter;
///    available from the second poll onward).
///  - `gpu_util_pct` — GPU `Device Utilization %` point sample.
///  - `cores_pinned` — count of logical cores whose busy% ≥ `pinnedThreshold`
///    over the last poll interval (available from the second poll onward).
///  - `top_proc_cpu_pct` — highest own-uid per-process CPU% over the last
///    interval (own-uid only; libproc EPERMs cross-uid daemons, deferred to
///    Phase 3's gated `ps`). Available from the second poll onward.
///
/// Each signal degrades INDEPENDENTLY: a `nil` from any sampler simply omits
/// that one metric this poll rather than failing the whole harvest, so a
/// single broken API never blanks the others.
///
/// Tests inject the sampler closures + a clock so the rate/cores math is
/// exercised deterministically without touching hardware (the
/// `CPUTempProbe` / `KernelTaskProbe` idiom).
public final class SystemSignalsProbe: Probe, @unchecked Sendable {

    public let name = "system_signals"
    public let pollInterval: Duration

    /// Per-core busy% at/above which a core is counted as "pinned". 70% per
    /// the feasibility report's "cores sustained >70%" trigger.
    public let pinnedThreshold: Double

    /// Injected live readers — overridable for deterministic unit tests.
    public struct Samplers: Sendable {
        public var memoryPressure: @Sendable () -> SystemSignals.MemoryPressureLevel?
        public var swap: @Sendable () -> SystemSignals.SwapSample?
        public var gpuUtilization: @Sendable () -> Int?
        public var cpuSnapshot: @Sendable () -> SystemSignals.CPUSnapshot?
        public var processSnapshots: @Sendable () -> [ProcessSampler.Snapshot]

        public init(
            memoryPressure: @escaping @Sendable () -> SystemSignals.MemoryPressureLevel?,
            swap: @escaping @Sendable () -> SystemSignals.SwapSample?,
            gpuUtilization: @escaping @Sendable () -> Int?,
            cpuSnapshot: @escaping @Sendable () -> SystemSignals.CPUSnapshot?,
            processSnapshots: @escaping @Sendable () -> [ProcessSampler.Snapshot]
        ) {
            self.memoryPressure = memoryPressure
            self.swap = swap
            self.gpuUtilization = gpuUtilization
            self.cpuSnapshot = cpuSnapshot
            self.processSnapshots = processSnapshots
        }

        /// The production samplers — all live, in-process, no-sudo.
        public static var live: Samplers {
            Samplers(
                memoryPressure: { SystemSignals.readMemoryPressureLevel() },
                swap: { SystemSignals.readSwapSample() },
                gpuUtilization: { SystemSignals.readGPUUtilization() },
                cpuSnapshot: { SystemSignals.readCPUSnapshot() },
                processSnapshots: { ProcessSampler.snapshotAll() }
            )
        }
    }

    private let samplers: Samplers

    /// State carried between polls so the rate/delta signals can be computed.
    private var prevSwap: SystemSignals.SwapSample?
    private var prevCPU: SystemSignals.CPUSnapshot?
    private var prevProcCPUTime: [Int32: ProcessSampler.Snapshot] = [:]

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "system_signals")

    public convenience init(pollInterval: Duration = .seconds(5), pinnedThreshold: Double = 70) {
        self.init(pollInterval: pollInterval, pinnedThreshold: pinnedThreshold, samplers: .live)
    }

    /// Designated init — samplers injectable for unit tests.
    public init(
        pollInterval: Duration = .seconds(5),
        pinnedThreshold: Double = 70,
        samplers: Samplers
    ) {
        self.pollInterval = pollInterval
        self.pinnedThreshold = pinnedThreshold
        self.samplers = samplers
    }

    public var defaultMetricKey: String { "system" }

    /// No alerts in Phase 1 — pure metric collection. The metric harvest
    /// happens via `currentMetrics()`, which the registry calls every poll.
    public func run() async throws -> [Alert] { [] }

    /// Sample every Tier-A signal and return the ones currently readable as a
    /// metrics row. Rate/delta signals appear from the second poll onward
    /// (they need a prior sample); absent ones are simply omitted this poll.
    public func currentMetrics() async -> [String: Double] {
        var out: [String: Double] = [:]

        // 1. Memory-pressure LEVEL.
        if let level = samplers.memoryPressure() {
            out["mem_pressure_level"] = level.ordinal
        }

        // 2. Swap-in RATE (needs a prior cumulative sample).
        if let swap = samplers.swap() {
            if let prev = prevSwap, let rate = SystemSignals.swapinRate(previous: prev, current: swap) {
                out["swapin_rate"] = rate
            }
            prevSwap = swap
        }

        // 3. GPU utilization %.
        if let gpu = samplers.gpuUtilization() {
            out["gpu_util_pct"] = Double(gpu)
        }

        // 4. Cores pinned (needs a prior tick snapshot).
        if let cpu = samplers.cpuSnapshot() {
            if let prev = prevCPU,
               let busy = SystemSignals.perCoreBusyPercent(previous: prev, current: cpu) {
                out["cores_pinned"] = Double(
                    SystemSignals.coresPinned(busyPercents: busy, threshold: pinnedThreshold)
                )
            }
            prevCPU = cpu
        }

        // 5. Top own-uid per-process CPU% (needs prior per-pid snapshots).
        //    `ProcessSampler.snapshotAll()` only returns PIDs whose
        //    `proc_pid_rusage` succeeds, which is own-uid-only no-sudo —
        //    cross-uid daemons EPERM and never appear (deferred to Phase 3's
        //    gated `ps`).
        let procs = samplers.processSnapshots()
        if !procs.isEmpty {
            if let top = Self.topProcessCPUPercent(previous: prevProcCPUTime, current: procs) {
                out["top_proc_cpu_pct"] = top
            }
            prevProcCPUTime = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        }

        return out
    }

    // MARK: - Pure helper (testable)

    /// Highest per-process CPU% over the interval between `previous` and
    /// `current` snapshots, matched by PID. Returns `nil` when no PID is
    /// present in both snapshots (first poll, or full process turnover).
    /// Pure — exercised in tests with synthetic `ProcessSampler.Snapshot`s.
    public static func topProcessCPUPercent(
        previous: [Int32: ProcessSampler.Snapshot],
        current: [ProcessSampler.Snapshot]
    ) -> Double? {
        var best: Double? = nil
        for curr in current {
            guard let prev = previous[curr.pid] else { continue }
            guard let pct = ProcessSampler.cpuPercent(previous: prev, current: curr) else { continue }
            if best == nil || pct > best! { best = pct }
        }
        return best
    }
}
