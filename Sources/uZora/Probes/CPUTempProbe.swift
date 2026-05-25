import Foundation
import IOKit
import os

/// Samples CPU package temperature on Apple Silicon.
///
/// **Approach taken in Phase 2**: probe a list of known SMC thermal keys
/// (`Tp01`, `Tp09`, `Tg0D`, `Tc0P`, `TC0P`, ...) and take the max reading
/// as a coarse "package" temperature. These keys are exposed by the
/// AppleSMC user client without root or special entitlements on real
/// hardware. On systems where none of these keys answer (early M1, VMs,
/// future hardware revisions) the probe degrades to a graceful no-op
/// and logs a one-shot `os_log` warning.
///
/// **NOT used in Phase 2**: the IOReport `Thermal` channel group, which
/// would give richer per-cluster (`pcluster`, `ecluster`) data, lives in
/// the private `IOReport.framework` and dyld-loading it from a sandboxed
/// app needs `com.apple.private.iokit.IOReport` (private entitlement). We
/// keep that as a Phase 6 follow-up — see `TODO Phase 6` below.
///
/// **NOT used in Phase 2**: `powermetrics --samplers smc`, which requires
/// `sudo` and prompts an authorization dialog every poll — unacceptable
/// for a 10-second polled probe. Powermetrics integration is reserved
/// for the on-demand "deep diagnostics" view (Phase 8+).
public final class CPUTempProbe: Probe, @unchecked Sendable {

    public let name = "cpu_temp"
    public let pollInterval: Duration = .seconds(10)

    public struct Thresholds: Sendable {
        public let warnC: Double
        public let criticalC: Double

        public init(warnC: Double = 90, criticalC: Double = 100) {
            self.warnC = warnC
            self.criticalC = criticalC
        }

        public static let `default` = Thresholds()
    }

    public struct Sample: Sendable {
        public let tempC: Double
        public let sourceKey: String

        public init(tempC: Double, sourceKey: String) {
            self.tempC = tempC
            self.sourceKey = sourceKey
        }
    }

    private let thresholds: Thresholds
    private let sampler: @Sendable () -> Sample?
    private let clock: @Sendable () -> Date
    private var firstSeenAt: Date?
    private var unavailableLogged: Bool = false

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "cpu_temp")

    public convenience init(thresholds: Thresholds = .default) {
        self.init(
            thresholds: thresholds,
            sampler: { Self.sampleViaSMC() },
            clock: { Date() }
        )
    }

    public init(
        thresholds: Thresholds,
        sampler: @escaping @Sendable () -> Sample?,
        clock: @escaping @Sendable () -> Date
    ) {
        self.thresholds = thresholds
        self.sampler = sampler
        self.clock = clock
    }

    public func run() async throws -> [Alert] {
        guard let sample = sampler() else {
            if !unavailableLogged {
                log.warning("CPU temperature probe unavailable on this build — no SMC thermal keys responded. See TODO Phase 6 (IOReport).")
                unavailableLogged = true
            }
            return []
        }

        guard let severity = Self.severity(for: sample.tempC, thresholds: thresholds) else {
            firstSeenAt = nil
            return []
        }

        let now = clock()
        if firstSeenAt == nil { firstSeenAt = now }

        return [Alert(
            probe: name,
            key: "package",
            severity: severity,
            message: String(format: "CPU package %.1f°C (source: %@)", sample.tempC, sample.sourceKey),
            details: [
                "temp_c":     String(format: "%.2f", sample.tempC),
                "source_key": sample.sourceKey,
            ],
            firstSeen: firstSeenAt ?? now,
            lastUpdated: now
        )]
    }

    // MARK: - Pure threshold (testable)

    public static func severity(for tempC: Double, thresholds: Thresholds) -> Severity? {
        if tempC >= thresholds.criticalC { return .critical }
        if tempC >= thresholds.warnC { return .warn }
        return nil
    }

    // MARK: - SMC sampling

    /// Candidate SMC keys for "CPU package temperature", in priority order.
    /// Apple Silicon firmware tends to ship a subset of these depending on
    /// generation; we read all and take the max valid reading.
    ///
    /// TODO Phase 6: replace this heuristic with `IOReportCopyChannelsInGroup("Thermal", nil)`
    /// once the private-FW dyld + entitlement story is settled.
    private static let candidateKeys: [String] = [
        // Apple-Silicon-style die / cluster temps observed on M1/M2/M3.
        "Tp01", "Tp05", "Tp09", "Tp0D",
        "Tg05", "Tg0D",
        // Intel-era legacy keys, kept for older hardware that might run
        // a debug build under Rosetta.
        "TC0P", "TC0D", "TC0E", "TC0F",
        "Tc0P", "Tc0D",
    ]

    public static func sampleViaSMC() -> Sample? {
        guard let conn = IOKitBridge.openSMC() else { return nil }
        defer { IOKitBridge.closeSMC(conn) }

        var best: Sample?
        for key in candidateKeys {
            guard let val = IOKitBridge.readSMCKey(key, conn: conn) else { continue }

            var tempC: Double?
            switch val.type {
            case "flt ":
                if let f = val.asFloat, f.isFinite, f > 0, f < 130 {
                    tempC = Double(f)
                }
            case "sp78":
                if let s = val.asSP78, s > 0, s < 130 {
                    tempC = s
                }
            case "ui16", "ui8 ":
                if let u = val.asUInt, u > 0, u < 130 {
                    tempC = Double(u)
                }
            default:
                // Unknown type — skip rather than misinterpret.
                continue
            }

            if let t = tempC {
                if best == nil || t > best!.tempC {
                    best = Sample(tempC: t, sourceKey: key)
                }
            }
        }
        return best
    }
}
