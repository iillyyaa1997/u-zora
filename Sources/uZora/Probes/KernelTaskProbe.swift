import Foundation
import Darwin
import os

/// Watches `kernel_task` CPU%. On Apple Silicon, sustained high
/// `kernel_task` usage is the canonical *user-visible* thermal-throttling
/// indicator: macOS rate-limits user processes by handing CPU time to
/// `kernel_task` (PID 0 on modern macOS), so its apparent percentage rises
/// as the SoC heats up.
///
/// Severity (with sustained windows):
/// - >25% sustained 30s  → warn (thermal_implication = true)
/// - >50% sustained 60s  → critical (aggressive throttling)
///
/// "Sustained" means: the *current* poll AND the prior poll(s) that fall
/// inside the window must both have observed the elevated rate. We don't
/// store a full history — only the timestamp at which the elevated rate
/// was first observed. The window walks naturally as long as subsequent
/// polls keep the rate above the threshold.
public final class KernelTaskProbe: Probe, @unchecked Sendable {

    public let name = "kernel_task"
    public let pollInterval: Duration = .seconds(15)

    public struct Thresholds: Sendable {
        public let warnCpuPct: Double
        public let warnSustainedSeconds: TimeInterval
        public let criticalCpuPct: Double
        public let criticalSustainedSeconds: TimeInterval

        public init(
            warnCpuPct: Double = 25,
            warnSustainedSeconds: TimeInterval = 30,
            criticalCpuPct: Double = 50,
            criticalSustainedSeconds: TimeInterval = 60
        ) {
            self.warnCpuPct = warnCpuPct
            self.warnSustainedSeconds = warnSustainedSeconds
            self.criticalCpuPct = criticalCpuPct
            self.criticalSustainedSeconds = criticalSustainedSeconds
        }

        public static let `default` = Thresholds()
    }

    private let thresholds: Thresholds
    private let clock: @Sendable () -> Date
    private let pidFinder: @Sendable () -> Int32?
    private let snapshotter: @Sendable (Int32) -> ProcessSampler.Snapshot?

    /// State carried between polls: the prior snapshot (for CPU% delta)
    /// and the times at which warn/critical bands were *first entered*.
    private var prevSnapshot: ProcessSampler.Snapshot?
    private var warnEnteredAt: Date?
    private var criticalEnteredAt: Date?
    private var firstSeenAt: Date?
    private var unavailableLogged = false

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "kernel_task")

    public convenience init(thresholds: Thresholds = .default) {
        self.init(
            thresholds: thresholds,
            clock: { Date() },
            pidFinder: { ProcessSampler.findPID(named: "kernel_task") ?? 0 },
            snapshotter: { ProcessSampler.snapshot(pid: $0) }
        )
    }

    /// Designated init — clock, PID lookup, and snapshot reader injectable
    /// for unit tests so the threshold ladder can be exercised
    /// deterministically.
    public init(
        thresholds: Thresholds,
        clock: @escaping @Sendable () -> Date,
        pidFinder: @escaping @Sendable () -> Int32?,
        snapshotter: @escaping @Sendable (Int32) -> ProcessSampler.Snapshot?
    ) {
        self.thresholds = thresholds
        self.clock = clock
        self.pidFinder = pidFinder
        self.snapshotter = snapshotter
    }

    public func run() async throws -> [Alert] {
        let now = clock()

        guard let pid = pidFinder() else {
            if !unavailableLogged {
                log.warning("kernel_task PID not discoverable; probe disabled")
                unavailableLogged = true
            }
            return []
        }

        guard let current = snapshotter(pid) else {
            // Snapshot failed — likely sandboxed read denial. Skip silently.
            return []
        }

        guard let prior = prevSnapshot else {
            // First poll: store baseline, no alert can be computed yet.
            prevSnapshot = current
            return []
        }

        defer { prevSnapshot = current }

        guard let cpuPct = ProcessSampler.cpuPercent(previous: prior, current: current) else {
            return []
        }

        let decision = Self.evaluate(
            cpuPct: cpuPct,
            now: now,
            warnEnteredAt: &warnEnteredAt,
            criticalEnteredAt: &criticalEnteredAt,
            thresholds: thresholds
        )

        guard let outcome = decision else {
            firstSeenAt = nil
            return []
        }

        if firstSeenAt == nil { firstSeenAt = now }

        let alert = Alert(
            probe: name,
            key: "kernel_task",
            severity: outcome.severity,
            message: String(format: "kernel_task CPU %.1f%% sustained %ds — thermal throttling likely",
                            cpuPct, Int(outcome.sustainedSeconds)),
            details: [
                "cpu_pct":              String(format: "%.2f", cpuPct),
                "sustained_window_sec": String(format: "%.0f", outcome.sustainedSeconds),
                "thermal_implication":  "true",
            ],
            firstSeen: firstSeenAt ?? now,
            lastUpdated: now
        )
        return [alert]
    }

    // MARK: - Pure evaluation (testable)

    public struct Outcome: Equatable, Sendable {
        public let severity: Severity
        public let sustainedSeconds: TimeInterval
    }

    /// Pure decision function.
    ///
    /// Updates the warn/critical "first entered" timestamps as a side
    /// effect (`inout`) so the caller persists them across polls; returns
    /// the outcome if the sustained window for either band has elapsed.
    public static func evaluate(
        cpuPct: Double,
        now: Date,
        warnEnteredAt: inout Date?,
        criticalEnteredAt: inout Date?,
        thresholds: Thresholds
    ) -> Outcome? {
        // Update band-entry timestamps.
        if cpuPct >= thresholds.criticalCpuPct {
            if criticalEnteredAt == nil { criticalEnteredAt = now }
            if warnEnteredAt == nil { warnEnteredAt = now }
        } else if cpuPct >= thresholds.warnCpuPct {
            criticalEnteredAt = nil
            if warnEnteredAt == nil { warnEnteredAt = now }
        } else {
            warnEnteredAt = nil
            criticalEnteredAt = nil
            return nil
        }

        // Check critical band first (highest severity wins).
        if let critAt = criticalEnteredAt {
            let sustained = now.timeIntervalSince(critAt)
            if sustained >= thresholds.criticalSustainedSeconds {
                return Outcome(severity: .critical, sustainedSeconds: sustained)
            }
        }

        if let warnAt = warnEnteredAt {
            let sustained = now.timeIntervalSince(warnAt)
            if sustained >= thresholds.warnSustainedSeconds {
                return Outcome(severity: .warn, sustainedSeconds: sustained)
            }
        }

        return nil
    }
}
