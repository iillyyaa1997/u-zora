import Testing
@testable import uZora

/// Placeholder suite for hardware-dependent probes whose unit tests need
/// recorded fixtures rather than synthetic inputs.
///
/// TODO Phase 7: SMART/CPUTemp tests need recorded fixtures
/// - CPUTemp: capture a known-good SMC dump on an M1/M2/M3 device and
///   replay through `CPUTempProbe.sampleViaSMC` with the IOConnect call
///   mocked at the bridge level.
/// - SMART: capture `IONVMeBlockStorageDevice` property dumps via
///   `ioreg -ric IONVMeBlockStorageDevice` on multiple hardware revisions,
///   write a fixture-replay sampler, then exercise the threshold matrix.
///
/// The threshold logic (the *pure* part) is already exercised through
/// `SMARTProbe.evaluate(sample:thresholds:)` and `CPUTempProbe.severity(for:thresholds:)`
/// below — what's missing is the *sampler* path, which lives in IOKit territory.
@Suite("Hardware-probe fixture placeholder")
struct HardwareProbeFixturesPlaceholder {

    @Test func cpuTempPureThreshold_warn() {
        #expect(CPUTempProbe.severity(for: 95, thresholds: .default) == .warn)
    }

    @Test func cpuTempPureThreshold_critical() {
        #expect(CPUTempProbe.severity(for: 105, thresholds: .default) == .critical)
    }

    @Test func cpuTempPureThreshold_ok() {
        #expect(CPUTempProbe.severity(for: 70, thresholds: .default) == nil)
    }

    @Test func smartPureEvaluation_criticalWarningBit() {
        let s = SMARTProbe.Sample(
            criticalWarning: 0b0000_0001,
            availableSparePct: 80,
            percentageUsed: 20,
            mediaErrors: 0,
            model: "FixtureSSD"
        )
        let e = SMARTProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == .critical)
        #expect(e.reasons.contains(where: { $0.hasPrefix("critical_warning=") }))
    }

    @Test func smartPureEvaluation_lowSpare_warn() {
        let s = SMARTProbe.Sample(
            criticalWarning: 0,
            availableSparePct: 8,
            percentageUsed: 20,
            mediaErrors: 0,
            model: "FixtureSSD"
        )
        let e = SMARTProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == .warn)
        #expect(e.reasons.contains("spare_warn"))
    }

    @Test func smartPureEvaluation_lowSpare_critical() {
        let s = SMARTProbe.Sample(
            criticalWarning: 0,
            availableSparePct: 3,
            percentageUsed: 20,
            mediaErrors: 0,
            model: "FixtureSSD"
        )
        let e = SMARTProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == .critical)
        #expect(e.reasons.contains("spare_critical"))
    }

    @Test func smartPureEvaluation_percentUsedHigh_warn() {
        let s = SMARTProbe.Sample(
            criticalWarning: 0,
            availableSparePct: 50,
            percentageUsed: 85,
            mediaErrors: 0,
            model: "FixtureSSD"
        )
        let e = SMARTProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == .warn)
        #expect(e.reasons.contains("used_warn"))
    }

    @Test func smartPureEvaluation_percentUsedOverflow_critical() {
        let s = SMARTProbe.Sample(
            criticalWarning: 0,
            availableSparePct: 50,
            percentageUsed: 120,
            mediaErrors: 0,
            model: "FixtureSSD"
        )
        let e = SMARTProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == .critical)
        #expect(e.reasons.contains("used_critical"))
    }

    @Test func smartPureEvaluation_mediaErrors_warn() {
        let s = SMARTProbe.Sample(
            criticalWarning: 0,
            availableSparePct: 50,
            percentageUsed: 20,
            mediaErrors: 7,
            model: "FixtureSSD"
        )
        let e = SMARTProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == .warn)
        #expect(e.reasons.contains(where: { $0.hasPrefix("media_errors=") }))
    }

    @Test func smartPureEvaluation_allGood_noAlert() {
        let s = SMARTProbe.Sample(
            criticalWarning: 0,
            availableSparePct: 95,
            percentageUsed: 5,
            mediaErrors: 0,
            model: "FixtureSSD"
        )
        let e = SMARTProbe.evaluate(sample: s, thresholds: .default)
        #expect(e.severity == nil)
        #expect(e.reasons.isEmpty)
    }
}
