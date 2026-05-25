import Testing
import Foundation
@testable import uZora

@Suite("BatteryProbe threshold evaluation")
struct BatteryThresholdTests {

    private func sample(
        charge: Int = 80,
        cycles: Int? = 100,
        condition: String = "Normal",
        isCharging: Bool = false
    ) -> BatteryProbe.Sample {
        BatteryProbe.Sample(
            chargePct: charge,
            cycles: cycles,
            condition: condition,
            isCharging: isCharging,
            wattageIn: nil,
            wattageOut: nil
        )
    }

    @Test func healthyBattery_noAlert() {
        let s = sample()
        let e = BatteryProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == nil)
        #expect(e.reasons.isEmpty)
    }

    @Test func lowChargeOnBattery_19pct_warn() {
        let s = sample(charge: 19, isCharging: false)
        let e = BatteryProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == .warn)
        #expect(e.reasons.contains("low_charge_warn"))
    }

    @Test func veryLowChargeOnBattery_9pct_critical() {
        let s = sample(charge: 9, isCharging: false)
        let e = BatteryProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == .critical)
        #expect(e.reasons.contains("low_charge_critical"))
    }

    @Test func lowChargeButCharging_suppressed() {
        // When plugged in we ignore the low-charge signal.
        let s = sample(charge: 5, isCharging: true)
        let e = BatteryProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == nil)
    }

    @Test func cycleCount_warn_950() {
        let s = sample(cycles: 950)
        let e = BatteryProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == .warn)
        #expect(e.reasons.contains("cycles_warn"))
    }

    @Test func cycleCount_critical_1100() {
        let s = sample(cycles: 1100)
        let e = BatteryProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == .critical)
        #expect(e.reasons.contains("cycles_critical"))
    }

    @Test func conditionReplaceSoon_warn() {
        let s = sample(condition: "Replace Soon")
        let e = BatteryProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == .warn)
        #expect(e.reasons.contains("condition_replace_soon"))
    }

    @Test func conditionServiceBattery_critical() {
        let s = sample(condition: "Service Battery")
        let e = BatteryProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == .critical)
        #expect(e.reasons.contains("condition_service"))
    }

    @Test func conditionUnknown_treatedAsWarn() {
        let s = sample(condition: "Mysterious Quantum State")
        let e = BatteryProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == .warn)
        #expect(e.reasons.contains(where: { $0.hasPrefix("condition_unknown:") }))
    }

    @Test func combinedSignals_maxSeverityWins() {
        // Low charge (warn) + high cycles (critical) → critical, but BOTH reasons listed.
        let s = sample(charge: 15, cycles: 1100, isCharging: false)
        let e = BatteryProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == .critical)
        #expect(e.reasons.contains("low_charge_warn"))
        #expect(e.reasons.contains("cycles_critical"))
    }

    @Test func nilCycles_skipped() {
        let s = sample(cycles: nil)
        let e = BatteryProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == nil)
    }

    @Test func endToEndWithInjectedSampler() async throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let probe = BatteryProbe(
            thresholds: .default,
            sampler: {
                BatteryProbe.Sample(
                    chargePct: 8,
                    cycles: 500,
                    condition: "Normal",
                    isCharging: false,
                    wattageIn: nil,
                    wattageOut: 15.0
                )
            },
            clock: { fixedDate }
        )
        let alerts = try await probe.run()
        let alert = try #require(alerts.first)
        #expect(alert.probe == "battery")
        #expect(alert.key == "internal")
        #expect(alert.severity == .critical)
        #expect(alert.details?["charge_pct"] == "8")
        #expect(alert.details?["wattage_out"] == "15.00")
    }

    @Test func nilSampler_silentNoOp() async throws {
        let probe = BatteryProbe(
            thresholds: .default,
            sampler: { nil },
            clock: { Date() }
        )
        let alerts = try await probe.run()
        #expect(alerts.isEmpty)
    }
}
