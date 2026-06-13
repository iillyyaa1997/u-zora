import Foundation
import IOKit
import Darwin
import os

/// Tier-A in-process system-signal sampler for the proactive-diagnosis layer.
///
/// Stateless enum (like `IOKitBridge` / `IOHIDThermal`) exposing the cheap,
/// always-on, no-sudo signals the Phase-2 `DiagnosisEngine` will consume:
///
///  - **Memory-pressure LEVEL** — `sysctl kern.memorystatus_vm_pressure_level`
///    (the CORRECT memory signal; NOT swap size, which produced the
///    "7 GB swap looked critical but Memory Pressure was GREEN" misdiagnosis).
///  - **Swap-in RATE** — `host_statistics64(HOST_VM_INFO64)` `.swapins`
///    cumulative counter, differenced across two timed samples → the real
///    thrash signal (not `vm.swapusage` total).
///  - **GPU utilization %** — the IORegistry `IOAccelerator`
///    `PerformanceStatistics["Device Utilization %"]` point sample, via the
///    `IOKitBridge` IORegistry helpers (no `ioreg` text-parsing).
///  - **Cores pinned** — `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`
///    per-core tick counters, differenced across two snapshots → per-core
///    busy% and the count of cores at/above a busy threshold (the cheapest
///    way to detect "~2 cores pinned" without enumerating processes).
///
/// Each signal degrades INDEPENDENTLY: an API/format failure returns `nil`
/// (abstain) rather than crashing, so a single broken signal never silences
/// the others. Read-only, no entitlement, ad-hoc-safe — verified live on
/// macOS 26 / Apple Silicon (M1 Pro) with no sudo.
///
/// Concurrency: stateless; every helper opens + releases its own kernel
/// resources before returning. The *rate* helpers are pure functions over
/// caller-held prior samples (the enum stores nothing itself), mirroring
/// `ProcessSampler.cpuPercent(previous:current:)`.
public enum SystemSignals {

    static let log = Logger(subsystem: "place.unicorns.uzora", category: "system-signals")

    // MARK: - Memory pressure LEVEL

    /// macOS memory-pressure level, as reported by
    /// `kern.memorystatus_vm_pressure_level`. This is the dispatch-source
    /// `DISPATCH_MEMORYPRESSURE_*` value family: the kernel uses a small
    /// bitmask, so we map the raw Int32 to a named level.
    public enum MemoryPressureLevel: Int, Sendable, Equatable {
        case normal = 1
        case warn = 2
        case critical = 4

        /// A monotone numeric for persistence / thresholding (1/2/4 raw values
        /// are not contiguous, so a 0/1/2 ladder is friendlier for graphs).
        public var ordinal: Double {
            switch self {
            case .normal: return 0
            case .warn: return 1
            case .critical: return 2
            }
        }
    }

    /// Pure decode of the raw `kern.memorystatus_vm_pressure_level` Int32 into
    /// the named level. Returns `nil` (abstain) for any value outside the
    /// known {1, 2, 4} set, so an unexpected future encoding never maps to a
    /// wrong level. Testable with synthetic inputs.
    public static func decodeMemoryPressureLevel(_ raw: Int32) -> MemoryPressureLevel? {
        MemoryPressureLevel(rawValue: Int(raw))
    }

    /// Live read of the memory-pressure level. Returns `nil` if the sysctl is
    /// unavailable or the value is unrecognised (abstain).
    public static func readMemoryPressureLevel() -> MemoryPressureLevel? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rc = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        guard rc == 0 else {
            log.debug("sysctl kern.memorystatus_vm_pressure_level failed: errno=\(errno)")
            return nil
        }
        return decodeMemoryPressureLevel(level)
    }

    // MARK: - Swap-in RATE

    /// One timed read of the cumulative `swapins` counter from
    /// `host_statistics64`. The counter is monotonic since boot; the RATE is
    /// the per-second delta between two samples (see `swapinRate`).
    public struct SwapSample: Sendable, Equatable {
        /// Cumulative count of pages swapped IN since boot.
        public let swapins: UInt64
        public let sampledAt: Date

        public init(swapins: UInt64, sampledAt: Date) {
            self.swapins = swapins
            self.sampledAt = sampledAt
        }
    }

    /// Pure swap-in rate (pages/sec) from two cumulative samples. Returns
    /// `nil` if the wall-time delta is non-positive or the counter went
    /// backwards (boot / counter reset). Mirrors
    /// `ProcessSampler.cpuPercent(previous:current:)`. Testable.
    public static func swapinRate(previous: SwapSample, current: SwapSample) -> Double? {
        let wall = current.sampledAt.timeIntervalSince(previous.sampledAt)
        guard wall > 0 else { return nil }
        guard current.swapins >= previous.swapins else { return nil } // reset
        let delta = current.swapins - previous.swapins
        return Double(delta) / wall
    }

    /// Live read of the cumulative swap-in counter. Returns `nil` if
    /// `host_statistics64` fails (abstain).
    public static func readSwapSample(now: Date = Date()) -> SwapSample? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            log.debug("host_statistics64(HOST_VM_INFO64) failed: kr=\(kr)")
            return nil
        }
        return SwapSample(swapins: info.swapins, sampledAt: now)
    }

    // MARK: - GPU utilization %

    /// The IORegistry key inside an `IOAccelerator` service's
    /// `PerformanceStatistics` dict that carries the integer GPU utilization
    /// percentage. Stable on M-series.
    public static let gpuPerformanceStatisticsKey = "PerformanceStatistics"
    public static let gpuDeviceUtilizationKey = "Device Utilization %"

    /// Pure extraction of the GPU utilization % from an already-copied
    /// `PerformanceStatistics` dictionary. Accepts the `Int` / `NSNumber`
    /// forms the IORegistry bridges to. Returns `nil` (abstain) when the key
    /// is absent or non-numeric. Testable with synthetic dicts.
    public static func gpuUtilization(from performanceStatistics: [String: Any]) -> Int? {
        guard let value = performanceStatistics[gpuDeviceUtilizationKey] else { return nil }
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    /// Live read of GPU utilization %. Walks every `IOAccelerator` service
    /// (a system can expose more than one, and not all carry the key — the
    /// real GPU's `PerformanceStatistics` does) and returns the first
    /// readable `Device Utilization %`. Returns `nil` (abstain) on VMs /
    /// hardware without the accelerator. Reuses `IOKitBridge`'s IORegistry
    /// property helpers — no `ioreg` text-parsing.
    public static func readGPUUtilization() -> Int? {
        var found: Int? = nil
        IOKitBridge.forEachMatchingService(className: "IOAccelerator") { svc in
            guard found == nil else { return }
            guard let stats: [String: Any] = IOKitBridge.copyProperty(
                svc, key: gpuPerformanceStatisticsKey
            ) else { return }
            if let util = gpuUtilization(from: stats) {
                found = util
            }
        }
        return found
    }

    // MARK: - Cores pinned (per-core CPU load)

    /// A per-core cumulative CPU-tick snapshot from
    /// `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`. Tick counters are
    /// monotonic since boot; per-core busy% is a delta between two snapshots.
    public struct CoreTicks: Sendable, Equatable {
        public let user: UInt64
        public let system: UInt64
        public let nice: UInt64
        public let idle: UInt64

        public init(user: UInt64, system: UInt64, nice: UInt64, idle: UInt64) {
            self.user = user
            self.system = system
            self.nice = nice
            self.idle = idle
        }

        /// Busy ticks = user + system + nice (everything that isn't idle).
        public var busy: UInt64 { user &+ system &+ nice }
        /// Total ticks across all states.
        public var total: UInt64 { busy &+ idle }
    }

    /// A full host snapshot: one `CoreTicks` per logical core, timestamped.
    public struct CPUSnapshot: Sendable, Equatable {
        public let cores: [CoreTicks]
        public let sampledAt: Date

        public init(cores: [CoreTicks], sampledAt: Date) {
            self.cores = cores
            self.sampledAt = sampledAt
        }
    }

    /// Pure per-core busy% over the delta between two snapshots. For each core
    /// the busy-tick delta is divided by the total-tick delta (× 100). Cores
    /// whose total delta is zero (no scheduling activity) contribute `0`.
    /// Returns `nil` if the snapshots disagree on core count (a topology
    /// change between polls — abstain). Testable with synthetic snapshots.
    public static func perCoreBusyPercent(
        previous: CPUSnapshot,
        current: CPUSnapshot
    ) -> [Double]? {
        guard previous.cores.count == current.cores.count,
              !current.cores.isEmpty else { return nil }
        var out: [Double] = []
        out.reserveCapacity(current.cores.count)
        for (prev, curr) in zip(previous.cores, current.cores) {
            // Counters can wrap (UInt64 is generous, but be defensive); a
            // backwards delta means a reset → treat that core as 0% rather
            // than a bogus huge value.
            guard curr.total >= prev.total, curr.busy >= prev.busy else {
                out.append(0)
                continue
            }
            let totalDelta = curr.total - prev.total
            guard totalDelta > 0 else { out.append(0); continue }
            let busyDelta = curr.busy - prev.busy
            out.append(Double(busyDelta) / Double(totalDelta) * 100.0)
        }
        return out
    }

    /// Pure count of cores whose busy% is at/above `threshold`. Convenience
    /// over `perCoreBusyPercent`'s result — "how many cores are pinned".
    public static func coresPinned(busyPercents: [Double], threshold: Double) -> Int {
        busyPercents.filter { $0 >= threshold }.count
    }

    /// Live per-core cumulative tick snapshot. Returns `nil` (abstain) if
    /// `host_processor_info` fails. The kernel-allocated array is released
    /// before returning.
    public static func readCPUSnapshot(now: Date = Date()) -> CPUSnapshot? {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount
        )
        guard kr == KERN_SUCCESS, let info = infoArray else {
            log.debug("host_processor_info(PROCESSOR_CPU_LOAD_INFO) failed: kr=\(kr)")
            return nil
        }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            )
        }
        let stride = Int(CPU_STATE_MAX)
        var cores: [CoreTicks] = []
        cores.reserveCapacity(Int(cpuCount))
        for c in 0..<Int(cpuCount) {
            let base = c * stride
            cores.append(CoreTicks(
                user:   UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])),
                system: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])),
                nice:   UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])),
                idle:   UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            ))
        }
        return CPUSnapshot(cores: cores, sampledAt: now)
    }
}
