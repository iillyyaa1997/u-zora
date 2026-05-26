import Foundation
import os

/// Tracks the top-N CPU-consuming processes and emits an alert when the
/// topmost crosses a sustained threshold.
///
/// - top-process >50% sustained 60s → warn
/// - top-process >80% sustained 30s → critical
///
/// Internally keeps the latest snapshot per-PID so CPU% can be computed
/// as a delta on each poll. Top-5 are tracked but only the *topmost*
/// triggers an alert (matching the Phase 3 spec; the others surface via
/// the menu UI in Phase 4+).
public final class TopCPUProcessProbe: Probe, @unchecked Sendable {

    public let name = "top_cpu"
    public let pollInterval: Duration = .seconds(10)

    public struct Thresholds: Sendable {
        public let warnPct: Double
        public let warnSustainedSeconds: TimeInterval
        public let criticalPct: Double
        public let criticalSustainedSeconds: TimeInterval
        public let topN: Int

        public init(
            warnPct: Double = 50,
            warnSustainedSeconds: TimeInterval = 60,
            criticalPct: Double = 80,
            criticalSustainedSeconds: TimeInterval = 30,
            topN: Int = 5
        ) {
            self.warnPct = warnPct
            self.warnSustainedSeconds = warnSustainedSeconds
            self.criticalPct = criticalPct
            self.criticalSustainedSeconds = criticalSustainedSeconds
            self.topN = topN
        }

        public static let `default` = Thresholds()
    }

    public struct ProcessEntry: Sendable, Hashable {
        public let pid: Int32
        public let command: String
        public let cpuPct: Double
        public let rssMB: Double
        public let startedAt: Date

        public init(pid: Int32, command: String, cpuPct: Double, rssMB: Double, startedAt: Date) {
            self.pid = pid
            self.command = command
            self.cpuPct = cpuPct
            self.rssMB = rssMB
            self.startedAt = startedAt
        }
    }

    private let thresholds: Thresholds
    private let clock: @Sendable () -> Date
    private let sampler: @Sendable () -> [ProcessSampler.Snapshot]

    private var prevByPID: [Int32: ProcessSampler.Snapshot] = [:]
    /// Per-PID "first entered" timestamps for warn/critical bands; cleared
    /// when the PID drops below or disappears.
    private var warnEnteredAt: [Int32: Date] = [:]
    private var criticalEnteredAt: [Int32: Date] = [:]
    private var firstSeenAt: [String: Date] = [:]

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "top_cpu")

    public convenience init(thresholds: Thresholds = .default) {
        self.init(
            thresholds: thresholds,
            clock: { Date() },
            sampler: { ProcessSampler.snapshotAll() }
        )
    }

    public init(
        thresholds: Thresholds,
        clock: @escaping @Sendable () -> Date,
        sampler: @escaping @Sendable () -> [ProcessSampler.Snapshot]
    ) {
        self.thresholds = thresholds
        self.clock = clock
        self.sampler = sampler
    }

    public func run() async throws -> [Alert] {
        let now = clock()
        let current = sampler()

        // Compute deltas for every PID we've seen before; ignore brand-new
        // PIDs on this poll (their first delta arrives next time).
        var ranking: [ProcessEntry] = []
        ranking.reserveCapacity(current.count)
        for snap in current {
            guard let prior = prevByPID[snap.pid] else { continue }
            guard let pct = ProcessSampler.cpuPercent(previous: prior, current: snap) else { continue }
            let entry = ProcessEntry(
                pid: snap.pid,
                command: snap.name,
                cpuPct: pct,
                rssMB: Double(snap.residentSizeBytes) / 1_048_576.0,
                startedAt: snap.startTime
            )
            ranking.append(entry)
        }

        // Refresh prior snapshots after delta computation.
        prevByPID = Dictionary(uniqueKeysWithValues: current.map { ($0.pid, $0) })

        // Sort descending by cpuPct.
        ranking.sort { $0.cpuPct > $1.cpuPct }
        let topN = Array(ranking.prefix(thresholds.topN))

        // Maintain band timestamps for *all* current top-N candidates so
        // we follow whichever PID stays elevated longest.
        var alertsToEmit: [Alert] = []
        let currentPIDs = Set(topN.map { $0.pid })
        // Clean up bands for PIDs no longer in top-N.
        warnEnteredAt = warnEnteredAt.filter { currentPIDs.contains($0.key) }
        criticalEnteredAt = criticalEnteredAt.filter { currentPIDs.contains($0.key) }

        // Evaluate only the topmost (per spec).
        guard let top = topN.first else { return [] }
        let outcome = Self.evaluate(
            entry: top,
            now: now,
            warnEnteredAt: &warnEnteredAt,
            criticalEnteredAt: &criticalEnteredAt,
            thresholds: thresholds
        )

        if let severity = outcome {
            let key = "\(top.command):\(top.pid)"
            let alertID = "top_cpu:\(key)"
            if firstSeenAt[alertID] == nil { firstSeenAt[alertID] = now }
            alertsToEmit.append(Alert(
                probe: name,
                key: key,
                severity: severity,
                message: String(format: "Process %@ (pid %d) is using %.1f%% CPU",
                                top.command, top.pid, top.cpuPct),
                details: [
                    "pid":        String(top.pid),
                    "command":    top.command,
                    "cpu_pct":    String(format: "%.2f", top.cpuPct),
                    "rss_mb":     String(format: "%.2f", top.rssMB),
                    "started_at": ISO8601DateFormatter().string(from: top.startedAt),
                ],
                firstSeen: firstSeenAt[alertID] ?? now,
                lastUpdated: now
            ))
        } else {
            // No firing alert for the topmost — clear its first-seen marker
            // so a re-occurrence emits as a new appearance.
            for key in firstSeenAt.keys where key.hasPrefix("top_cpu:") {
                firstSeenAt[key] = nil
            }
        }

        return alertsToEmit
    }

    // MARK: - Pure evaluation (testable)

    /// Update band timestamps for the given top entry and return the
    /// severity if its sustained-window threshold has elapsed.
    public static func evaluate(
        entry: ProcessEntry,
        now: Date,
        warnEnteredAt: inout [Int32: Date],
        criticalEnteredAt: inout [Int32: Date],
        thresholds: Thresholds
    ) -> Severity? {
        let pid = entry.pid

        if entry.cpuPct >= thresholds.criticalPct {
            if criticalEnteredAt[pid] == nil { criticalEnteredAt[pid] = now }
            if warnEnteredAt[pid] == nil { warnEnteredAt[pid] = now }
        } else if entry.cpuPct >= thresholds.warnPct {
            criticalEnteredAt[pid] = nil
            if warnEnteredAt[pid] == nil { warnEnteredAt[pid] = now }
        } else {
            warnEnteredAt[pid] = nil
            criticalEnteredAt[pid] = nil
            return nil
        }

        if let critAt = criticalEnteredAt[pid] {
            let sustained = now.timeIntervalSince(critAt)
            if sustained >= thresholds.criticalSustainedSeconds {
                return .critical
            }
        }
        if let warnAt = warnEnteredAt[pid] {
            let sustained = now.timeIntervalSince(warnAt)
            if sustained >= thresholds.warnSustainedSeconds {
                return .warn
            }
        }
        return nil
    }
}
