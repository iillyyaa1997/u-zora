import Foundation
import Darwin
import os

/// Reads free space on the boot drive via `statfs("/")` and emits
/// `warn`/`critical` alerts based on the free-percentage thresholds.
///
/// Phase 2 scope: boot drive only (`/`). Multi-volume support comes in a
/// later phase when the menu UI is ready to display per-volume rows.
public final class DiskFreeProbe: Probe, @unchecked Sendable {

    public let name = "disk"
    public let pollInterval: Duration = .seconds(60)

    /// Thresholds, expressed as the *free* fraction (0.0..<1.0).
    public struct Thresholds: Sendable {
        public let warnFreeFraction: Double
        public let criticalFreeFraction: Double

        public init(warnFreeFraction: Double = 0.15, criticalFreeFraction: Double = 0.05) {
            self.warnFreeFraction = warnFreeFraction
            self.criticalFreeFraction = criticalFreeFraction
        }

        public static let `default` = Thresholds()
    }

    /// Result of a `statfs()` sample, exposed so threshold logic is unit-testable
    /// without needing to actually mount a disk.
    public struct Sample: Sendable {
        public let freeBytes: UInt64
        public let totalBytes: UInt64
        public let mount: String

        public init(freeBytes: UInt64, totalBytes: UInt64, mount: String) {
            self.freeBytes = freeBytes
            self.totalBytes = totalBytes
            self.mount = mount
        }

        public var freeFraction: Double {
            guard totalBytes > 0 else { return 1.0 }
            return Double(freeBytes) / Double(totalBytes)
        }
    }

    private let thresholds: Thresholds
    private let sampler: @Sendable () -> Sample?
    private let clock: @Sendable () -> Date
    private var firstSeenAt: Date?

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "disk")

    public convenience init(thresholds: Thresholds = .default) {
        self.init(
            thresholds: thresholds,
            sampler: { Self.sampleRoot() },
            clock: { Date() }
        )
    }

    /// Designated initializer — sampler / clock injectable for tests.
    public init(
        thresholds: Thresholds,
        sampler: @escaping @Sendable () -> Sample?,
        clock: @escaping @Sendable () -> Date
    ) {
        self.thresholds = thresholds
        self.sampler = sampler
        self.clock = clock
    }

    public var defaultMetricKey: String { "/" }

    /// Phase 6: latest disk-free numbers. Available regardless of alert
    /// state — the popover graph shows a flat-OK line on a healthy disk.
    public func currentMetrics() async -> [String: Double] {
        guard let s = sampler() else { return [:] }
        return [
            "free_pct":    s.freeFraction * 100.0,
            "free_bytes":  Double(s.freeBytes),
            "total_bytes": Double(s.totalBytes),
        ]
    }

    public func run() async throws -> [Alert] {
        guard let sample = sampler() else {
            log.error("statfs() failed; skipping disk probe sample")
            return []
        }

        guard let severity = Self.severity(for: sample, thresholds: thresholds) else {
            firstSeenAt = nil
            return []
        }

        let now = clock()
        if firstSeenAt == nil { firstSeenAt = now }

        let pct = sample.freeFraction * 100.0
        let msg = String(format: "Boot drive %.1f%% free (%@ of %@)",
                         pct,
                         Self.humanBytes(sample.freeBytes),
                         Self.humanBytes(sample.totalBytes))

        let alert = Alert(
            probe: name,
            key: sample.mount,
            severity: severity,
            message: msg,
            details: [
                "mount":       sample.mount,
                "free_bytes":  String(sample.freeBytes),
                "total_bytes": String(sample.totalBytes),
                "free_pct":    String(format: "%.2f", pct),
            ],
            firstSeen: firstSeenAt ?? now,
            lastUpdated: now
        )
        return [alert]
    }

    // MARK: - Severity (pure, testable)

    /// Pure threshold function, factored out so tests don't need a real disk.
    public static func severity(for sample: Sample, thresholds: Thresholds) -> Severity? {
        let frac = sample.freeFraction
        if frac < thresholds.criticalFreeFraction { return .critical }
        if frac < thresholds.warnFreeFraction { return .warn }
        return nil
    }

    // MARK: - Darwin `statfs("/")`

    /// Sample boot-volume usage via `statfs("/")`.
    /// Returns `nil` on syscall failure (extremely unlikely on a running OS).
    public static func sampleRoot() -> Sample? {
        var buf = statfs()
        let rc = "/".withCString { statfs($0, &buf) }
        guard rc == 0 else { return nil }
        let blockSize = UInt64(buf.f_bsize)
        let total = UInt64(buf.f_blocks) * blockSize
        let free  = UInt64(buf.f_bavail) * blockSize
        return Sample(freeBytes: free, totalBytes: total, mount: "/")
    }

    private static func humanBytes(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useTB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}
