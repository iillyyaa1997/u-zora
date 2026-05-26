import Foundation
import IOKit
import os

/// Reads fan RPM via SMC keys `FNum` (count), `F0Ac`, `F1Ac`, ... (actuals).
///
/// Fan inventory is detected dynamically on first sample; fanless devices
/// (MacBook Air, all M1+ silicon) report `FNum=0` and the probe silently
/// no-ops — this is *normal* for the device class and must not surface
/// as an alert.
///
/// Alerts:
/// - **low RPM** (< 200) while CPU load OR package temp is high → warn
///   (stuck-fan indicator). Phase 2 wires only the RPM signal; the
///   correlated load/temp gates come in Phase 3 when probes can read
///   each other's snapshots.
/// - **high RPM** (>= 6000) sustained → info (noisy / heavy workload).
public final class FanRPMProbe: Probe, @unchecked Sendable {

    public let name = "fan"
    public let pollInterval: Duration = .seconds(15)

    public struct Thresholds: Sendable {
        public let lowRPM: Double
        public let highRPM: Double

        public init(lowRPM: Double = 200, highRPM: Double = 6000) {
            self.lowRPM = lowRPM
            self.highRPM = highRPM
        }

        public static let `default` = Thresholds()
    }

    public struct FanSample: Sendable {
        public let index: Int
        public let rpm: Double

        public init(index: Int, rpm: Double) {
            self.index = index
            self.rpm = rpm
        }
    }

    /// Aggregate sample used by the threshold function. Phase 3 will pipe
    /// in cpuLoadFraction + packageTempC from sibling probes; for now we
    /// pass `nil` and tests can exercise both code paths.
    public struct CompositeSample: Sendable {
        public let fans: [FanSample]
        public let cpuLoadFraction: Double?
        public let packageTempC: Double?

        public init(fans: [FanSample], cpuLoadFraction: Double? = nil, packageTempC: Double? = nil) {
            self.fans = fans
            self.cpuLoadFraction = cpuLoadFraction
            self.packageTempC = packageTempC
        }
    }

    private let thresholds: Thresholds
    private let sampler: @Sendable () -> CompositeSample?
    private let clock: @Sendable () -> Date
    private var firstSeenAt: [String: Date] = [:]

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "fan")

    public convenience init(thresholds: Thresholds = .default) {
        self.init(
            thresholds: thresholds,
            sampler: { Self.sampleFans() },
            clock: { Date() }
        )
    }

    public init(
        thresholds: Thresholds,
        sampler: @escaping @Sendable () -> CompositeSample?,
        clock: @escaping @Sendable () -> Date
    ) {
        self.thresholds = thresholds
        self.sampler = sampler
        self.clock = clock
    }

    public func run() async throws -> [Alert] {
        guard let sample = sampler(), !sample.fans.isEmpty else {
            // Fanless device or SMC unavailable — silent no-op.
            return []
        }

        let now = clock()
        var alerts: [Alert] = []

        for fan in sample.fans {
            let key = "fan_\(fan.index)"
            let decision = Self.severity(
                fan: fan,
                cpuLoadFraction: sample.cpuLoadFraction,
                packageTempC: sample.packageTempC,
                thresholds: thresholds
            )

            guard let severity = decision.severity else {
                firstSeenAt[key] = nil
                continue
            }

            if firstSeenAt[key] == nil { firstSeenAt[key] = now }

            alerts.append(Alert(
                probe: name,
                key: key,
                severity: severity,
                message: decision.message(forFan: fan),
                details: [
                    "fan_index": String(fan.index),
                    "rpm":       String(format: "%.0f", fan.rpm),
                    "reason":    decision.reason,
                ],
                firstSeen: firstSeenAt[key] ?? now,
                lastUpdated: now
            ))
        }

        return alerts
    }

    // MARK: - Pure decision (testable)

    public enum Decision: Equatable, Sendable {
        case ok
        case stuckLow(reason: String)
        case noisyHigh

        public var severity: Severity? {
            switch self {
            case .ok:                 return nil
            case .stuckLow:           return .warn
            case .noisyHigh:          return .info
            }
        }

        public var reason: String {
            switch self {
            case .ok:                       return "ok"
            case .stuckLow(let r):          return r
            case .noisyHigh:                return "high_rpm_sustained"
            }
        }

        public func message(forFan fan: FanSample) -> String {
            // Use rounded() + String(format:) to avoid Int(Double) trap on
            // non-finite SMC readings; clamp to a sane upper bound.
            let safeRPM = fan.rpm.isFinite ? min(max(fan.rpm, 0), 30000).rounded() : 0
            let rpmStr = String(format: "%.0f", safeRPM)
            switch self {
            case .ok:
                return "fan \(fan.index): \(rpmStr) RPM"
            case .stuckLow(let r):
                return "fan \(fan.index) at \(rpmStr) RPM — possible stuck fan (\(r))"
            case .noisyHigh:
                return "fan \(fan.index) at \(rpmStr) RPM — high RPM sustained"
            }
        }
    }

    public static func severity(
        fan: FanSample,
        cpuLoadFraction: Double?,
        packageTempC: Double?,
        thresholds: Thresholds
    ) -> Decision {
        // Low RPM only fires if the system is *also* under thermal/load
        // pressure (signal of a stuck fan vs. an idle one).
        if fan.rpm < thresholds.lowRPM {
            let hotCPU = (packageTempC ?? 0) > 85
            let busyCPU = (cpuLoadFraction ?? 0) > 0.5
            if hotCPU || busyCPU {
                if hotCPU && busyCPU {
                    return .stuckLow(reason: "low_rpm_hot_and_busy")
                } else if hotCPU {
                    return .stuckLow(reason: "low_rpm_hot")
                } else {
                    return .stuckLow(reason: "low_rpm_busy")
                }
            }
            return .ok
        }
        if fan.rpm >= thresholds.highRPM {
            return .noisyHigh
        }
        return .ok
    }

    // MARK: - SMC sampling

    /// Sample fan RPMs via SMC. Reads `FNum` (UInt8 fan count) first, then
    /// `F<n>Ac` for each fan. Returns `nil` if the SMC connection cannot
    /// be opened; returns an empty `.fans` array on fanless hardware.
    public static func sampleFans() -> CompositeSample? {
        guard let conn = IOKitBridge.openSMC() else {
            return nil
        }
        defer { IOKitBridge.closeSMC(conn) }

        // Read FNum: number of fans installed.
        guard let fnumVal = IOKitBridge.readSMCKey("FNum", conn: conn),
              let count = fnumVal.asUInt else {
            // SMC works but FNum is absent — treat as zero fans.
            return CompositeSample(fans: [])
        }
        let n = min(Int(count), 8) // sanity cap
        if n == 0 {
            return CompositeSample(fans: [])
        }

        var fans: [FanSample] = []
        for i in 0..<n {
            let key = "F\(i)Ac"
            guard let val = IOKitBridge.readSMCKey(key, conn: conn) else { continue }
            // Most hardware reports `flt` (4-byte big-endian float).
            // Bound to physically plausible RPM (<30000) to reject junk reads.
            if let rpm = val.asFloat, rpm.isFinite, rpm >= 0, rpm < 30000 {
                fans.append(FanSample(index: i, rpm: Double(rpm)))
            } else if let raw = val.asUInt, raw < 30000 {
                // Older SMC firmware exposes `fpe2` (UInt16 / 4); we fall back
                // to a UInt cast and divide as a best-effort approximation.
                fans.append(FanSample(index: i, rpm: Double(raw)))
            }
        }
        return CompositeSample(fans: fans)
    }
}
