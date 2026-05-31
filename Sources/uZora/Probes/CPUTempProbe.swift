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

    public var defaultMetricKey: String { "package" }

    /// Test affordance: the thresholds this instance was constructed with,
    /// so config-wiring tests can assert the °C mapping. Internal —
    /// `@testable import`.
    var configuredThresholds: Thresholds { thresholds }

    /// Phase 6: latest CPU package temperature, for sparkline history.
    public func currentMetrics() async -> [String: Double] {
        guard let s = sampler() else { return [:] }
        return ["temp_c": s.tempC]
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
    /// **CPU-package keys only.** The `Tg*` GPU-die keys were deliberately
    /// removed: a CPU *package* temp probe must not read GPU sensors, and the
    /// `Tg05`/`Tg0D` GPU sensors were the very source of the 107-123°C
    /// crosstalk junk that forced the old tight `< 100` ceiling — which in
    /// turn made the critical threshold (default 100°C) unreachable, since
    /// any genuine ≥100°C reading was discarded as "junk". With GPU keys gone
    /// the ceiling can sit at a realistic Apple-Silicon Tjmax bound (`< 115`).
    ///
    /// TODO Phase 6: replace this heuristic with `IOReportCopyChannelsInGroup("Thermal", nil)`
    /// once the private-FW dyld + entitlement story is settled.
    static let candidateKeys: [String] = [
        // Apple-Silicon-style CPU performance-core die / cluster temps
        // observed on M1/M2/M3.
        "Tp01", "Tp05", "Tp09", "Tp0D",
        // Intel-era legacy keys, kept for older hardware that might run
        // a debug build under Rosetta.
        "TC0P", "TC0D", "TC0E", "TC0F",
        "Tc0P", "Tc0D",
    ]

    /// Lower plausibility floor (°C). SMC firmware on Apple Silicon returns
    /// denormal floats (2.3e-11, 1.4e-18, …) for parked / un-initialised
    /// performance cores, AND occasionally crosstalk values in the 10-15°C
    /// range that aren't real package temps either. CPU under any load is
    /// ≥30°C; ambient room is ~22°C — anything below 20°C is non-physical
    /// for the silicon.
    static let plausibilityFloorC: Double = 20

    /// Upper plausibility ceiling (°C). Apple Silicon throttles in the
    /// ~100-110°C band; 115°C covers a genuine critical-range reading while
    /// still rejecting obvious junk (≥115°C, e.g. the old GPU-sensor
    /// crosstalk in the 120s). This must sit ABOVE the default critical
    /// threshold (100°C) so a critical CPU-temp alert can actually fire.
    static let plausibilityCeilingC: Double = 115

    /// Pure plausibility filter for a single decoded SMC reading. Returns the
    /// accepted temperature in °C, or nil if the value is non-physical
    /// (denormal/parked-core noise below the floor, or junk at/above the
    /// ceiling). Factored out of `sampleViaSMC()` so the window can be
    /// unit-tested without live hardware.
    static func plausibleTemp(type: String, asFloat: Float?, asSP78: Double?, asUInt: UInt32?) -> Double? {
        let candidate: Double?
        switch type {
        case "flt ":
            if let f = asFloat, f.isFinite {
                candidate = Double(f)
            } else {
                candidate = nil
            }
        case "sp78":
            candidate = asSP78
        case "ui16", "ui8 ":
            candidate = asUInt.map(Double.init)
        default:
            // Unknown type — skip rather than misinterpret.
            return nil
        }
        guard let t = candidate, t.isFinite,
              t >= plausibilityFloorC, t < plausibilityCeilingC
        else { return nil }
        return t
    }

    public static func sampleViaSMC() -> Sample? {
        guard let conn = IOKitBridge.openSMC() else { return nil }
        defer { IOKitBridge.closeSMC(conn) }

        var best: Sample?
        for key in candidateKeys {
            guard let val = IOKitBridge.readSMCKey(key, conn: conn) else { continue }

            guard let t = plausibleTemp(
                type: val.type,
                asFloat: val.asFloat,
                asSP78: val.asSP78,
                asUInt: val.asUInt
            ) else { continue }

            if best == nil || t > best!.tempC {
                best = Sample(tempC: t, sourceKey: key)
            }
        }
        return best
    }
}
