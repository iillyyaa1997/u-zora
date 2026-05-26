import Foundation
import Darwin
import os

/// User-space `libproc` wrapper for sampling all PIDs on the system.
///
/// On Apple Silicon the `libproc.h` header is present in the SDK and the
/// symbols (`proc_listallpids`, `proc_pidinfo`, `proc_name`) are publicly
/// linkable without root. This module wraps them in a Swift-friendly API
/// shared by `KernelTaskProbe`, `TopCPUProcessProbe`, and
/// `TopMemoryProcessProbe`.
///
/// **CPU%** is computed as a delta between two snapshots — a single
/// reading cannot produce a percentage, only the cumulative ticks since
/// process start. Callers are expected to keep prior snapshots between
/// polls.
public enum ProcessSampler {

    static let log = Logger(subsystem: "place.unicorns.uzora", category: "process-sampler")

    /// A single process snapshot at one point in time.
    public struct Snapshot: Sendable, Hashable {
        public let pid: Int32
        public let name: String
        public let cpuTimeNanos: UInt64      // cumulative user+system CPU time
        public let residentSizeBytes: UInt64 // RSS at snapshot time
        public let virtualSizeBytes: UInt64
        public let startTime: Date
        public let sampledAt: Date

        public init(
            pid: Int32,
            name: String,
            cpuTimeNanos: UInt64,
            residentSizeBytes: UInt64,
            virtualSizeBytes: UInt64,
            startTime: Date,
            sampledAt: Date
        ) {
            self.pid = pid
            self.name = name
            self.cpuTimeNanos = cpuTimeNanos
            self.residentSizeBytes = residentSizeBytes
            self.virtualSizeBytes = virtualSizeBytes
            self.startTime = startTime
            self.sampledAt = sampledAt
        }
    }

    /// CPU percentage computed from two snapshots of the same PID.
    /// Returns `nil` if the time delta is zero or the snapshots are not
    /// for the same process.
    public static func cpuPercent(previous: Snapshot, current: Snapshot) -> Double? {
        guard previous.pid == current.pid else { return nil }
        let wallNanos = current.sampledAt.timeIntervalSince(previous.sampledAt) * 1_000_000_000
        guard wallNanos > 0 else { return nil }
        // Apple's `proc_pid_rusage` reports cumulative CPU nanoseconds
        // for the process (sum across threads). On a single-CPU box, a
        // fully-pinned process would gain 1 ns of CPU per 1 ns of wall;
        // on N cores it can gain up to N×. We report the raw single-CPU
        // percentage so callers can decide whether to normalise by core
        // count.
        let cpuDelta = Int64(current.cpuTimeNanos) - Int64(previous.cpuTimeNanos)
        guard cpuDelta >= 0 else { return nil } // clock reset / pid reuse
        return Double(cpuDelta) / wallNanos * 100.0
    }

    /// Read a snapshot of every PID we can see. Errors per-PID are
    /// silently skipped (the process may have exited between
    /// `proc_listallpids` and `proc_pidinfo`).
    public static func snapshotAll(now: Date = Date()) -> [Snapshot] {
        let pids = listAllPIDs()
        var snapshots: [Snapshot] = []
        snapshots.reserveCapacity(pids.count)
        for pid in pids {
            if let snap = snapshot(pid: pid, now: now) {
                snapshots.append(snap)
            }
        }
        return snapshots
    }

    /// Snapshot a single PID. Returns `nil` if the PID is gone or the
    /// kernel refuses to answer (sandboxed processes, kernel_task on
    /// some macOS revisions, etc.).
    public static func snapshot(pid: Int32, now: Date = Date()) -> Snapshot? {
        guard let usage = readRusage(pid: pid) else { return nil }
        let name = readProcessName(pid: pid)
        let bsdInfo = readBSDInfo(pid: pid)
        let start: Date
        if let bsd = bsdInfo {
            // pbi_start_tvsec is BSD-style epoch seconds.
            start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)
                                                + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
        } else {
            start = now
        }
        return Snapshot(
            pid: pid,
            name: name,
            cpuTimeNanos: usage.ri_user_time + usage.ri_system_time,
            residentSizeBytes: usage.ri_resident_size,
            virtualSizeBytes: 0,
            startTime: start,
            sampledAt: now
        )
    }

    /// Find the PID of a process by exact name. Returns the first match
    /// or `nil`. Used by `KernelTaskProbe` to locate `kernel_task`.
    public static func findPID(named target: String) -> Int32? {
        for pid in listAllPIDs() {
            let name = readProcessName(pid: pid)
            if name == target {
                return pid
            }
        }
        return nil
    }

    // MARK: - libproc bridging

    /// Read the kernel's list of every PID currently alive on the system.
    public static func listAllPIDs() -> [Int32] {
        // First call with NULL to get the size needed.
        let sizeNeeded = proc_listallpids(nil, 0)
        guard sizeNeeded > 0 else { return [] }

        // Add slack for processes that spawn between the two calls.
        let capacity = Int(sizeNeeded) + 64
        var buf = [Int32](repeating: 0, count: capacity)
        let writtenBytes = proc_listallpids(&buf, Int32(capacity * MemoryLayout<Int32>.size))
        guard writtenBytes > 0 else { return [] }
        let count = Int(writtenBytes) / MemoryLayout<Int32>.size
        return Array(buf.prefix(count)).filter { $0 > 0 }
    }

    private static func readProcessName(pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let written = proc_name(pid, &buf, UInt32(buf.count))
        if written > 0 {
            return cStringToSwift(buf)
        }
        // Fallback to PROC_PIDPATHINFO + basename if proc_name fails.
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN; spelled out because
        // the macro is gated out of the Swift overlay.
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathWritten = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        if pathWritten > 0 {
            let full = cStringToSwift(pathBuf)
            return (full as NSString).lastPathComponent
        }
        return ""
    }

    private static func cStringToSwift(_ buf: [CChar]) -> String {
        // Strip the NUL terminator if present, decode UTF-8.
        let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func readRusage(pid: Int32) -> rusage_info_v2? {
        var info = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rusagePtr)
            }
        }
        guard rc == 0 else { return nil }
        return info
    }

    private static func readBSDInfo(pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, size)
        }
        guard rc == size else { return nil }
        return info
    }

    // MARK: - Host total memory

    /// Total physical memory of the host, in bytes. Used by
    /// `TopMemoryProcessProbe` for percentage computations.
    public static func hostTotalMemoryBytes() -> UInt64 {
        var mem: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let rc = sysctlbyname("hw.memsize", &mem, &size, nil, 0)
        if rc == 0 { return mem }
        return 0
    }
}
