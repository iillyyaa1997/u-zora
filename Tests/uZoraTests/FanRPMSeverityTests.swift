import Testing
import Foundation
@testable import uZora

@Suite("FanRPMProbe severity decisions")
struct FanRPMSeverityTests {

    private func fan(_ rpm: Double, idx: Int = 0) -> FanRPMProbe.FanSample {
        FanRPMProbe.FanSample(index: idx, rpm: rpm)
    }

    @Test func normalRPM_idleSystem_ok() {
        let d = FanRPMProbe.severity(
            fan: fan(1500),
            cpuLoadFraction: 0.1,
            packageTempC: 45,
            thresholds: .default
        )
        #expect(d == .ok)
        #expect(d.severity == nil)
    }

    @Test func lowRPM_idleSystem_ok() {
        // Stopped fan on idle system is normal — passive cooling.
        let d = FanRPMProbe.severity(
            fan: fan(0),
            cpuLoadFraction: 0.05,
            packageTempC: 40,
            thresholds: .default
        )
        #expect(d == .ok)
    }

    @Test func lowRPM_hotCPU_stuckLow_warn() {
        let d = FanRPMProbe.severity(
            fan: fan(100),
            cpuLoadFraction: 0.1,
            packageTempC: 95,
            thresholds: .default
        )
        if case .stuckLow(let reason) = d {
            #expect(reason == "low_rpm_hot")
        } else {
            Issue.record("expected stuckLow, got \(d)")
        }
        #expect(d.severity == .warn)
    }

    @Test func lowRPM_busyCPU_stuckLow_warn() {
        let d = FanRPMProbe.severity(
            fan: fan(100),
            cpuLoadFraction: 0.85,
            packageTempC: 60,
            thresholds: .default
        )
        if case .stuckLow(let reason) = d {
            #expect(reason == "low_rpm_busy")
        } else {
            Issue.record("expected stuckLow")
        }
    }

    @Test func lowRPM_hotAndBusy_stuckLow_warn() {
        let d = FanRPMProbe.severity(
            fan: fan(50),
            cpuLoadFraction: 0.9,
            packageTempC: 92,
            thresholds: .default
        )
        if case .stuckLow(let reason) = d {
            #expect(reason == "low_rpm_hot_and_busy")
        } else {
            Issue.record("expected stuckLow")
        }
    }

    @Test func highRPM_noisyHigh_info() {
        let d = FanRPMProbe.severity(
            fan: fan(7000),
            cpuLoadFraction: nil,
            packageTempC: nil,
            thresholds: .default
        )
        #expect(d == .noisyHigh)
        #expect(d.severity == .info)
    }

    @Test func highRPM_atThreshold_noisyHigh() {
        // 6000 is *>=* the threshold; should fire as noisyHigh.
        let d = FanRPMProbe.severity(
            fan: fan(6000),
            cpuLoadFraction: nil,
            packageTempC: nil,
            thresholds: .default
        )
        #expect(d == .noisyHigh)
    }

    @Test func customThresholds() {
        let strict = FanRPMProbe.Thresholds(lowRPM: 500, highRPM: 4000)
        let d = FanRPMProbe.severity(
            fan: fan(4500),
            cpuLoadFraction: nil,
            packageTempC: nil,
            thresholds: strict
        )
        #expect(d == .noisyHigh)
    }

    @Test func fanlessDevice_emptySample_emitsNoAlerts() async throws {
        let probe = FanRPMProbe(
            thresholds: .default,
            sampler: { FanRPMProbe.CompositeSample(fans: []) },
            clock: { Date() }
        )
        let alerts = try await probe.run()
        #expect(alerts.isEmpty)
    }

    @Test func twoFansOneStuck_perFanAlerts() async throws {
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let probe = FanRPMProbe(
            thresholds: .default,
            sampler: {
                FanRPMProbe.CompositeSample(
                    fans: [
                        FanRPMProbe.FanSample(index: 0, rpm: 100),     // stuck (low + hot)
                        FanRPMProbe.FanSample(index: 1, rpm: 3000),    // normal
                    ],
                    cpuLoadFraction: 0.4,
                    packageTempC: 90
                )
            },
            clock: { fixedDate }
        )
        let alerts = try await probe.run()
        #expect(alerts.count == 1) // only fan_0 alerts
        let alert = try #require(alerts.first)
        #expect(alert.key == "fan_0")
        #expect(alert.severity == .warn)
        #expect(alert.details?["fan_index"] == "0")
    }

    @Test func samplerReturnsNil_silentNoOp() async throws {
        let probe = FanRPMProbe(
            thresholds: .default,
            sampler: { nil },
            clock: { Date() }
        )
        let alerts = try await probe.run()
        #expect(alerts.isEmpty)
    }
}
