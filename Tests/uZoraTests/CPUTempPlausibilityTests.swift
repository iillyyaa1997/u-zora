import Testing
import Foundation
@testable import uZora

/// Regression coverage for the CPU-temp critical-threshold-unreachable bug
/// (P0 #1). The old sampler plausibility window was `>= 20, < 100`, but the
/// default critical threshold is 100 °C and `severity(for:)` fires critical
/// only at `tempC >= criticalC` — so any genuine ≥100 °C reading was discarded
/// as "junk" and a critical CPU-temp alert could NEVER fire with default
/// config. Root cause: GPU sensor keys (`Tg05`/`Tg0D`) returning 107-123 °C
/// crosstalk forced the tight ceiling.
///
/// Fix: drop the GPU keys (a CPU *package* probe must not read GPU sensors)
/// and raise the ceiling to a realistic Apple-Silicon Tjmax bound (`< 115`).
@Suite("CPU-temp plausibility window (critical reachable)")
struct CPUTempPlausibilityTests {

    // MARK: - Candidate keys no longer include GPU sensors

    @Test func candidateKeys_excludeGPUSensors() {
        // The Tg* GPU-die keys were the source of the 107-123 °C crosstalk
        // that forced the old < 100 ceiling. A CPU package probe must not
        // read them.
        #expect(!CPUTempProbe.candidateKeys.contains("Tg05"))
        #expect(!CPUTempProbe.candidateKeys.contains("Tg0D"))
        // CPU performance-core keys are retained.
        #expect(CPUTempProbe.candidateKeys.contains("Tp01"))
        #expect(CPUTempProbe.candidateKeys.contains("Tp0D"))
    }

    // MARK: - The plausibility window now spans the critical range

    /// THE regression: a 102 °C `flt`-typed reading must be ACCEPTED so a
    /// critical alert (default criticalC = 100) can actually fire. Under the
    /// old `< 100` ceiling this returned nil and critical was unreachable.
    @Test func plausibleTemp_accepts102C_soCriticalCanFire() {
        let accepted = CPUTempProbe.plausibleTemp(
            type: "flt ",
            asFloat: Float(102.0),
            asSP78: nil,
            asUInt: nil
        )
        #expect(accepted == 102.0)
        // And that accepted value maps to .critical under default thresholds —
        // proving the end-to-end critical path is now reachable.
        let sev = CPUTempProbe.severity(for: accepted ?? -1, thresholds: .default)
        #expect(sev == .critical)
    }

    /// A 130 °C reading is still rejected as junk (above the 115 °C ceiling).
    @Test func plausibleTemp_rejects130C() {
        let rejected = CPUTempProbe.plausibleTemp(
            type: "flt ",
            asFloat: Float(130.0),
            asSP78: nil,
            asUInt: nil
        )
        #expect(rejected == nil)
    }

    /// The ceiling sits at exactly 115 °C (exclusive). 114.9 accepted, 115 not.
    @Test func plausibleTemp_ceilingBoundary() {
        #expect(CPUTempProbe.plausibleTemp(type: "flt ", asFloat: Float(114.9), asSP78: nil, asUInt: nil) != nil)
        #expect(CPUTempProbe.plausibleTemp(type: "flt ", asFloat: Float(115.0), asSP78: nil, asUInt: nil) == nil)
    }

    // MARK: - Floor still rejects denormal / parked-core noise

    /// The denormal float (2.3e-11) some firmware returns for parked cores is
    /// still rejected (below the 20 °C floor).
    @Test func plausibleTemp_rejectsDenormal() {
        let rejected = CPUTempProbe.plausibleTemp(
            type: "flt ",
            asFloat: Float(2.3e-11),
            asSP78: nil,
            asUInt: nil
        )
        #expect(rejected == nil)
    }

    /// The floor sits at exactly 20 °C (inclusive). 19.9 rejected, 20 accepted.
    @Test func plausibleTemp_floorBoundary() {
        #expect(CPUTempProbe.plausibleTemp(type: "flt ", asFloat: Float(19.9), asSP78: nil, asUInt: nil) == nil)
        #expect(CPUTempProbe.plausibleTemp(type: "flt ", asFloat: Float(20.0), asSP78: nil, asUInt: nil) == 20.0)
    }

    /// Non-finite floats (NaN/∞) are rejected outright.
    @Test func plausibleTemp_rejectsNonFinite() {
        #expect(CPUTempProbe.plausibleTemp(type: "flt ", asFloat: Float.nan, asSP78: nil, asUInt: nil) == nil)
        #expect(CPUTempProbe.plausibleTemp(type: "flt ", asFloat: Float.infinity, asSP78: nil, asUInt: nil) == nil)
    }

    // MARK: - Same window applies across SMC value types

    @Test func plausibleTemp_sp78_acceptsCriticalRange() {
        // sp78 reading at 101 °C is accepted (was rejected under < 100).
        #expect(CPUTempProbe.plausibleTemp(type: "sp78", asFloat: nil, asSP78: 101.0, asUInt: nil) == 101.0)
        #expect(CPUTempProbe.plausibleTemp(type: "sp78", asFloat: nil, asSP78: 120.0, asUInt: nil) == nil)
    }

    @Test func plausibleTemp_uint_acceptsCriticalRange() {
        #expect(CPUTempProbe.plausibleTemp(type: "ui16", asFloat: nil, asSP78: nil, asUInt: UInt32(105)) == 105.0)
        #expect(CPUTempProbe.plausibleTemp(type: "ui16", asFloat: nil, asSP78: nil, asUInt: UInt32(200)) == nil)
    }

    @Test func plausibleTemp_unknownType_skipped() {
        #expect(CPUTempProbe.plausibleTemp(type: "ch8s", asFloat: Float(50), asSP78: 50, asUInt: 50) == nil)
    }
}
