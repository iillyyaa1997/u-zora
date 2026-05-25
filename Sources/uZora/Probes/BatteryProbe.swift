import Foundation
import IOKit
import IOKit.ps
import os

/// Reads internal battery state via `IOPSCopyPowerSourcesInfo` /
/// `IOPSCopyPowerSourcesList` (`IOKit.ps`) and emits alerts on:
///
/// - low charge while on battery,
/// - high cycle count,
/// - non-"Normal" battery condition string.
///
/// Devices without a built-in battery (Mac mini, Mac Studio, iMac, Mac Pro)
/// return zero internal sources and the probe silently emits no alerts.
public final class BatteryProbe: Probe, @unchecked Sendable {

    public let name = "battery"
    public let pollInterval: Duration = .seconds(30)

    public struct Thresholds: Sendable {
        public let lowChargeWarnPct: Int
        public let lowChargeCriticalPct: Int
        public let cyclesWarn: Int
        public let cyclesCritical: Int

        public init(
            lowChargeWarnPct: Int = 20,
            lowChargeCriticalPct: Int = 10,
            cyclesWarn: Int = 900,
            cyclesCritical: Int = 1000
        ) {
            self.lowChargeWarnPct = lowChargeWarnPct
            self.lowChargeCriticalPct = lowChargeCriticalPct
            self.cyclesWarn = cyclesWarn
            self.cyclesCritical = cyclesCritical
        }

        public static let `default` = Thresholds()
    }

    /// Battery snapshot used by both the live IOPS sampler and unit tests.
    public struct Sample: Sendable {
        public let chargePct: Int           // 0...100
        public let cycles: Int?             // nil if unknown
        public let condition: String        // "Normal", "Replace Soon", "Service Battery", ...
        public let isCharging: Bool
        public let wattageIn: Double?       // adapter input wattage if known
        public let wattageOut: Double?      // discharge wattage if known

        public init(
            chargePct: Int,
            cycles: Int?,
            condition: String,
            isCharging: Bool,
            wattageIn: Double?,
            wattageOut: Double?
        ) {
            self.chargePct = chargePct
            self.cycles = cycles
            self.condition = condition
            self.isCharging = isCharging
            self.wattageIn = wattageIn
            self.wattageOut = wattageOut
        }
    }

    private let thresholds: Thresholds
    private let sampler: @Sendable () -> Sample?
    private let clock: @Sendable () -> Date
    private var firstSeenAt: [String: Date] = [:]

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "battery")

    public convenience init(thresholds: Thresholds = .default) {
        self.init(
            thresholds: thresholds,
            sampler: { Self.sampleInternalBattery() },
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
            // No internal battery — Mac mini / Studio / Pro / iMac all hit
            // this path, which is the correct silent no-op behaviour.
            return []
        }

        let evaluation = Self.evaluate(sample: sample, thresholds: thresholds)
        let now = clock()

        guard let highest = evaluation.severity else {
            firstSeenAt["internal"] = nil
            return []
        }

        if firstSeenAt["internal"] == nil { firstSeenAt["internal"] = now }

        let alert = Alert(
            probe: name,
            key: "internal",
            severity: highest,
            message: evaluation.message,
            details: [
                "charge_pct":  String(sample.chargePct),
                "cycles":      sample.cycles.map(String.init) ?? "unknown",
                "condition":   sample.condition,
                "is_charging": sample.isCharging ? "true" : "false",
                "wattage_in":  sample.wattageIn.map { String(format: "%.2f", $0) } ?? "unknown",
                "wattage_out": sample.wattageOut.map { String(format: "%.2f", $0) } ?? "unknown",
                "reasons":     evaluation.reasons.joined(separator: ","),
            ],
            firstSeen: firstSeenAt["internal"] ?? now,
            lastUpdated: now
        )
        return [alert]
    }

    // MARK: - Pure evaluation (testable)

    public struct Evaluation: Equatable, Sendable {
        public let severity: Severity?
        public let reasons: [String]
        public let message: String
    }

    public static func evaluate(sample: Sample, thresholds: Thresholds) -> Evaluation {
        var reasons: [String] = []
        var severity: Severity? = nil

        // Low charge — only when discharging.
        if !sample.isCharging {
            if sample.chargePct < thresholds.lowChargeCriticalPct {
                reasons.append("low_charge_critical")
                severity = max(severity, .critical)
            } else if sample.chargePct < thresholds.lowChargeWarnPct {
                reasons.append("low_charge_warn")
                severity = max(severity, .warn)
            }
        }

        // Cycle count.
        if let cycles = sample.cycles {
            if cycles > thresholds.cyclesCritical {
                reasons.append("cycles_critical")
                severity = max(severity, .critical)
            } else if cycles > thresholds.cyclesWarn {
                reasons.append("cycles_warn")
                severity = max(severity, .warn)
            }
        }

        // Condition string.
        switch sample.condition {
        case "Normal", "":
            break
        case "Replace Soon":
            reasons.append("condition_replace_soon")
            severity = max(severity, .warn)
        case "Replace Now":
            reasons.append("condition_replace_now")
            severity = max(severity, .warn)
        case "Service Battery", "Service Recommended":
            reasons.append("condition_service")
            severity = max(severity, .critical)
        default:
            // Unknown non-empty condition string → treat as warn rather
            // than ignore; user can investigate via the details payload.
            reasons.append("condition_unknown:\(sample.condition)")
            severity = max(severity, .warn)
        }

        let message: String
        if let sev = severity {
            message = "Battery alert (\(sev.rawValue)): \(reasons.joined(separator: ", "))"
        } else {
            message = "Battery OK"
        }
        return Evaluation(severity: severity, reasons: reasons, message: message)
    }

    // MARK: - IOPS sampling

    /// Read the internal battery snapshot via IOKit power-source APIs.
    /// Returns `nil` if no internal battery is present.
    public static func sampleInternalBattery() -> Sample? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return nil
        }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for src in sources {
            guard let dict = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let type = dict[kIOPSTypeKey] as? String ?? ""
            // We only care about the built-in battery, not UPSes.
            guard type == kIOPSInternalBatteryType else { continue }

            let chargePct = dict[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCap    = dict[kIOPSMaxCapacityKey] as? Int ?? 100
            let normalised: Int
            if maxCap > 0 && maxCap != 100 {
                normalised = Int((Double(chargePct) / Double(maxCap)) * 100.0)
            } else {
                normalised = chargePct
            }

            let isCharging = dict[kIOPSIsChargingKey] as? Bool ?? false
            let condition  = dict["BatteryHealthCondition"] as? String
                          ?? dict[kIOPSBatteryHealthConditionKey] as? String
                          ?? "Normal"

            // Cycle count + wattage live on the IOPMPowerSource (legacy) /
            // AppleSmartBattery service rather than the IOPS dictionary.
            let extras = readSmartBatteryExtras()

            return Sample(
                chargePct: normalised,
                cycles: extras.cycles,
                condition: condition,
                isCharging: isCharging,
                wattageIn: extras.adapterWattage,
                wattageOut: extras.dischargeWattage
            )
        }
        return nil
    }

    private struct BatteryExtras {
        var cycles: Int?
        var adapterWattage: Double?
        var dischargeWattage: Double?
    }

    /// Pull `CycleCount`, adapter input wattage, and instantaneous discharge
    /// wattage from the `AppleSmartBattery` IOService entry. All fields are
    /// optional — if a property is missing we leave the corresponding tuple
    /// field `nil` rather than fail the whole sample.
    private static func readSmartBatteryExtras() -> BatteryExtras {
        var extras = BatteryExtras()
        IOKitBridge.forEachMatchingService(className: "AppleSmartBattery") { svc in
            guard let props = IOKitBridge.copyProperties(svc) else { return }
            extras.cycles = props["CycleCount"] as? Int

            // AdapterDetails sub-dict carries Watts when on AC.
            if let adapter = props["AdapterDetails"] as? [String: Any],
               let watts = adapter["Watts"] as? Int {
                extras.adapterWattage = Double(watts)
            }

            // InstantAmperage * Voltage → instantaneous (dis)charge wattage.
            if let amperage = props["InstantAmperage"] as? Int,
               let voltage = props["Voltage"] as? Int {
                let watts = Double(amperage) * Double(voltage) / 1_000_000.0
                if watts < 0 {
                    extras.dischargeWattage = abs(watts)
                }
            }
        }
        return extras
    }
}

// MARK: - Small Severity convenience

private func max(_ lhs: Severity?, _ rhs: Severity) -> Severity {
    guard let lhs else { return rhs }
    return lhs >= rhs ? lhs : rhs
}
