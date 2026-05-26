import Foundation
import os

/// Tracks the top-N RSS consumers and alerts when the topmost exceeds
/// fixed-size thresholds.
///
/// Phase 3 thresholds (intentionally simple — Phase 4 will pair them with
/// macOS' `vm.memory_pressure` for context-aware tightening):
///
/// - top-process RSS > 8 GB  → warn
/// - top-process RSS > 16 GB → critical
///
/// On a 16 GB Mac, 8 GB is half of host memory; on a 32 GB Mac it's still
/// the practical "this process is hogging RAM" line for non-pro workloads.
/// The `host_total_mb` and `rss_pct_of_total` details give the UI enough
/// context to render a useful warning.
public final class TopMemoryProcessProbe: Probe, @unchecked Sendable {

    public let name = "top_mem"
    public let pollInterval: Duration = .seconds(30)

    public struct Thresholds: Sendable {
        public let warnRssBytes: UInt64
        public let criticalRssBytes: UInt64
        public let topN: Int

        public init(
            warnRssBytes: UInt64 = 8 * 1024 * 1024 * 1024,
            criticalRssBytes: UInt64 = 16 * 1024 * 1024 * 1024,
            topN: Int = 5
        ) {
            self.warnRssBytes = warnRssBytes
            self.criticalRssBytes = criticalRssBytes
            self.topN = topN
        }

        public static let `default` = Thresholds()
    }

    public struct ProcessEntry: Sendable, Hashable {
        public let pid: Int32
        public let command: String
        public let rssBytes: UInt64

        public init(pid: Int32, command: String, rssBytes: UInt64) {
            self.pid = pid
            self.command = command
            self.rssBytes = rssBytes
        }
    }

    private let thresholds: Thresholds
    private let clock: @Sendable () -> Date
    private let sampler: @Sendable () -> [ProcessSampler.Snapshot]
    private let hostMemoryProvider: @Sendable () -> UInt64

    private var firstSeenAt: [String: Date] = [:]

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "top_mem")

    public convenience init(thresholds: Thresholds = .default) {
        self.init(
            thresholds: thresholds,
            clock: { Date() },
            sampler: { ProcessSampler.snapshotAll() },
            hostMemoryProvider: { ProcessSampler.hostTotalMemoryBytes() }
        )
    }

    public init(
        thresholds: Thresholds,
        clock: @escaping @Sendable () -> Date,
        sampler: @escaping @Sendable () -> [ProcessSampler.Snapshot],
        hostMemoryProvider: @escaping @Sendable () -> UInt64
    ) {
        self.thresholds = thresholds
        self.clock = clock
        self.sampler = sampler
        self.hostMemoryProvider = hostMemoryProvider
    }

    public func run() async throws -> [Alert] {
        let now = clock()
        let hostTotalBytes = hostMemoryProvider()

        var entries: [ProcessEntry] = []
        for snap in sampler() {
            entries.append(ProcessEntry(
                pid: snap.pid,
                command: snap.name,
                rssBytes: snap.residentSizeBytes
            ))
        }
        entries.sort { $0.rssBytes > $1.rssBytes }
        let topN = Array(entries.prefix(thresholds.topN))

        guard let top = topN.first else { return [] }

        guard let severity = Self.severity(rssBytes: top.rssBytes, thresholds: thresholds) else {
            // Top dropped below threshold — clear any prior first-seen.
            for key in firstSeenAt.keys where key.hasPrefix("top_mem:") {
                firstSeenAt[key] = nil
            }
            return []
        }

        let key = "\(top.command):\(top.pid)"
        let alertID = "top_mem:\(key)"
        if firstSeenAt[alertID] == nil { firstSeenAt[alertID] = now }

        let rssMB = Double(top.rssBytes) / 1_048_576.0
        let hostTotalMB = Double(hostTotalBytes) / 1_048_576.0
        let rssPctOfTotal = hostTotalBytes > 0
            ? Double(top.rssBytes) / Double(hostTotalBytes) * 100.0
            : 0

        let alert = Alert(
            probe: name,
            key: key,
            severity: severity,
            message: String(format: "Process %@ (pid %d) holds %.1f MB resident (%.1f%% of host)",
                            top.command, top.pid, rssMB, rssPctOfTotal),
            details: [
                "pid":              String(top.pid),
                "command":          top.command,
                "rss_mb":           String(format: "%.2f", rssMB),
                "host_total_mb":    String(format: "%.0f", hostTotalMB),
                "rss_pct_of_total": String(format: "%.2f", rssPctOfTotal),
            ],
            firstSeen: firstSeenAt[alertID] ?? now,
            lastUpdated: now
        )
        return [alert]
    }

    // MARK: - Pure threshold (testable)

    public static func severity(rssBytes: UInt64, thresholds: Thresholds) -> Severity? {
        if rssBytes > thresholds.criticalRssBytes { return .critical }
        if rssBytes > thresholds.warnRssBytes { return .warn }
        return nil
    }
}
