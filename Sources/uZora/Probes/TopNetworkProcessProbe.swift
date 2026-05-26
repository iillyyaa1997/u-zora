import Foundation
import os

/// Tracks per-process network throughput and alerts when the topmost
/// process sustains heavy use.
///
/// **macOS doesn't expose per-process network bytes/sec in a public,
/// unprivileged API.** The realistic options surveyed in Phase 3 planning:
///
/// 1. `nettop -P -L 1 -J bytes_in,bytes_out -x` subprocess. User-space,
///    unprivileged, but slow (~1 s per invocation) and the output format
///    can shift between macOS releases.
/// 2. `NetworkExtension` / NEFilterDataProvider — requires entitlements +
///    user "Approve" dialog. Out of scope for a personal MVP.
/// 3. Graceful stub: register the probe so the scheduler shape is correct
///    but always return empty alerts.
///
/// **Phase 3 stance**: try option 1 with a tight parse + ample fallback.
/// If `nettop` is unavailable on a host (very rare — ships with macOS) or
/// its output cannot be parsed, fall back to option 3 and log once.
public final class TopNetworkProcessProbe: Probe, @unchecked Sendable {

    public let name = "top_net"
    public let pollInterval: Duration = .seconds(60)

    public struct Thresholds: Sendable {
        public let warnBytesPerSec: UInt64
        public let warnSustainedSeconds: TimeInterval
        public let criticalBytesPerSec: UInt64
        public let criticalSustainedSeconds: TimeInterval

        public init(
            warnBytesPerSec: UInt64 = 50 * 1024 * 1024,        // 50 MB/s
            warnSustainedSeconds: TimeInterval = 60,
            criticalBytesPerSec: UInt64 = 200 * 1024 * 1024,   // 200 MB/s
            criticalSustainedSeconds: TimeInterval = 60
        ) {
            self.warnBytesPerSec = warnBytesPerSec
            self.warnSustainedSeconds = warnSustainedSeconds
            self.criticalBytesPerSec = criticalBytesPerSec
            self.criticalSustainedSeconds = criticalSustainedSeconds
        }

        public static let `default` = Thresholds()
    }

    public struct ProcessEntry: Sendable, Hashable {
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

        public var totalBytesPerSec: UInt64 { bytesInPerSec + bytesOutPerSec }
    }

    private let thresholds: Thresholds
    private let clock: @Sendable () -> Date
    private let sampler: @Sendable () async -> [ProcessEntry]

    private var warnEnteredAt: [String: Date] = [:]
    private var criticalEnteredAt: [String: Date] = [:]
    private var firstSeenAt: [String: Date] = [:]
    private var unavailableLogged = false

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "top_net")

    public convenience init(thresholds: Thresholds = .default) {
        self.init(
            thresholds: thresholds,
            clock: { Date() },
            sampler: { await Self.liveSample() }
        )
    }

    public init(
        thresholds: Thresholds,
        clock: @escaping @Sendable () -> Date,
        sampler: @escaping @Sendable () async -> [ProcessEntry]
    ) {
        self.thresholds = thresholds
        self.clock = clock
        self.sampler = sampler
    }

    public func run() async throws -> [Alert] {
        let now = clock()
        let entries = await sampler()

        guard !entries.isEmpty else {
            if !unavailableLogged {
                log.warning("TopNetworkProcessProbe got no nettop samples; probe degrades to no-op. See TODO Phase 5 (NetworkExtension).")
                unavailableLogged = true
            }
            // Clean any prior bands — there's no data to compare.
            warnEnteredAt = [:]
            criticalEnteredAt = [:]
            return []
        }

        let ranked = entries.sorted { $0.totalBytesPerSec > $1.totalBytesPerSec }
        guard let top = ranked.first else { return [] }

        // Keep band timestamps keyed by command (PID isn't always stable
        // — nettop sometimes reports rolled-up "Google Chrome:*" entries).
        let bandKey = top.command
        let activeKeys: Set<String> = [bandKey]
        warnEnteredAt = warnEnteredAt.filter { activeKeys.contains($0.key) }
        criticalEnteredAt = criticalEnteredAt.filter { activeKeys.contains($0.key) }

        let severity = Self.evaluate(
            entry: top,
            now: now,
            warnEnteredAt: &warnEnteredAt,
            criticalEnteredAt: &criticalEnteredAt,
            thresholds: thresholds
        )

        guard let sev = severity else {
            for key in firstSeenAt.keys where key.hasPrefix("top_net:") {
                firstSeenAt[key] = nil
            }
            return []
        }

        let alertKey = top.command
        let alertID = "top_net:\(alertKey)"
        if firstSeenAt[alertID] == nil { firstSeenAt[alertID] = now }

        let alert = Alert(
            probe: name,
            key: alertKey,
            severity: sev,
            message: String(format: "Process %@ (pid %d) network %.1f MB/s in + %.1f MB/s out",
                            top.command, top.pid,
                            Double(top.bytesInPerSec) / 1_048_576.0,
                            Double(top.bytesOutPerSec) / 1_048_576.0),
            details: [
                "pid":               String(top.pid),
                "command":           top.command,
                "bytes_in_per_sec":  String(top.bytesInPerSec),
                "bytes_out_per_sec": String(top.bytesOutPerSec),
            ],
            firstSeen: firstSeenAt[alertID] ?? now,
            lastUpdated: now
        )
        return [alert]
    }

    // MARK: - Pure evaluation (testable)

    public static func evaluate(
        entry: ProcessEntry,
        now: Date,
        warnEnteredAt: inout [String: Date],
        criticalEnteredAt: inout [String: Date],
        thresholds: Thresholds
    ) -> Severity? {
        let key = entry.command
        let bps = entry.totalBytesPerSec

        if bps >= thresholds.criticalBytesPerSec {
            if criticalEnteredAt[key] == nil { criticalEnteredAt[key] = now }
            if warnEnteredAt[key] == nil { warnEnteredAt[key] = now }
        } else if bps >= thresholds.warnBytesPerSec {
            criticalEnteredAt[key] = nil
            if warnEnteredAt[key] == nil { warnEnteredAt[key] = now }
        } else {
            warnEnteredAt[key] = nil
            criticalEnteredAt[key] = nil
            return nil
        }

        if let critAt = criticalEnteredAt[key] {
            if now.timeIntervalSince(critAt) >= thresholds.criticalSustainedSeconds {
                return .critical
            }
        }
        if let warnAt = warnEnteredAt[key] {
            if now.timeIntervalSince(warnAt) >= thresholds.warnSustainedSeconds {
                return .warn
            }
        }
        return nil
    }

    // MARK: - nettop subprocess

    /// Run `nettop` once and parse per-process aggregated bytes/sec.
    ///
    /// Returns an empty array if `nettop` is missing, refuses to run, or
    /// produces unparsable output. Callers treat empty-array as "probe
    /// unavailable this turn" rather than "no traffic" — at the topN
    /// level that's the same outcome.
    public static func liveSample() async -> [ProcessEntry] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runNettop())
            }
        }
    }

    private static func runNettop() -> [ProcessEntry] {
        let nettopPath = "/usr/bin/nettop"
        guard FileManager.default.isExecutableFile(atPath: nettopPath) else {
            return []
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nettopPath)
        // -P = process mode; -L 1 = one sample; -J bytes_in,bytes_out = columns;
        // -x = no header decoration; -k state,interface,... = trim columns we
        // don't need. We pick a minimal set; the `-J` ordering is what survives.
        proc.arguments = [
            "-P",
            "-L", "1",
            "-J", "bytes_in,bytes_out",
            "-x",
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return []
        }

        // Hard timeout — `nettop -L 1` ought to return in ~1 s; if it
        // hangs we kill it and return empty.
        let timeout = DispatchTime.now() + .seconds(3)
        let waitQueue = DispatchQueue.global(qos: .utility)
        let waitGroup = DispatchGroup()
        waitGroup.enter()
        waitQueue.async {
            proc.waitUntilExit()
            waitGroup.leave()
        }
        if waitGroup.wait(timeout: timeout) == .timedOut {
            proc.terminate()
            _ = waitGroup.wait(timeout: .now() + .seconds(1))
            return []
        }

        guard proc.terminationStatus == 0 else { return [] }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parseNettopOutput(text)
    }

    /// Parse the CSV-style output `nettop -J bytes_in,bytes_out -x` emits.
    ///
    /// Each non-empty row looks like (versions vary slightly):
    /// `time,row_id,proc_name.pid,iface,state,bytes_in,bytes_out,...`
    ///
    /// We extract `proc_name.pid` (the canonical "process:pid" identifier
    /// nettop uses) and the two byte counters. `nettop -L 1` emits a
    /// single sample window of ~1 s so the counters approximate
    /// bytes-per-second directly.
    public static func parseNettopOutput(_ text: String) -> [ProcessEntry] {
        var entries: [String: ProcessEntry] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("time") || line.hasPrefix("Time") { continue }

            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            // Need at least: timestamp,row_id,proc_name.pid,interface,state,
            // bytes_in,bytes_out
            guard fields.count >= 7 else { continue }
            let procField = fields[2]
            let bytesIn = UInt64(fields[5]) ?? 0
            let bytesOut = UInt64(fields[6]) ?? 0
            if procField.isEmpty { continue }

            let (name, pid) = splitProcField(procField)
            let key = name

            if let existing = entries[key] {
                entries[key] = ProcessEntry(
                    pid: existing.pid,
                    command: name,
                    bytesInPerSec: existing.bytesInPerSec + bytesIn,
                    bytesOutPerSec: existing.bytesOutPerSec + bytesOut
                )
            } else {
                entries[key] = ProcessEntry(
                    pid: pid,
                    command: name,
                    bytesInPerSec: bytesIn,
                    bytesOutPerSec: bytesOut
                )
            }
        }
        return Array(entries.values)
    }

    /// nettop joins process name and PID with a dot: `Google Chrome.1234`.
    /// We split on the last dot to handle process names containing dots.
    private static func splitProcField(_ field: String) -> (name: String, pid: Int32) {
        guard let dotIdx = field.lastIndex(of: ".") else {
            return (field, 0)
        }
        let name = String(field[..<dotIdx])
        let pidStr = String(field[field.index(after: dotIdx)...])
        return (name, Int32(pidStr) ?? 0)
    }
}
