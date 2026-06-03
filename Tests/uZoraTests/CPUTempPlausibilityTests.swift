import Testing
import Foundation
@testable import uZora

/// Coverage for the IOHID die-sensor selection that replaced the unreliable
/// SMC `Tp*` path (which produced 20–99 °C swings on an idle, cool Apple
/// Silicon machine). The live read is `IOHIDThermal.readSensors()`; the pure,
/// hardware-free selection logic under test is `selectCPUTemp(from:)`.
@Suite("CPU-temp IOHID die-sensor selection")
struct CPUTempSelectionTests {

    private func r(_ name: String, _ t: Double) -> (name: String, tempC: Double) {
        (name: name, tempC: t)
    }

    @Test func selects_and_averages_die_sensors() {
        let s = CPUTempProbe.selectCPUTemp(from: [
            r("PMU tdie0", 50), r("PMU tdie1", 52), r("PMU tdie2", 48),
        ])
        #expect(s != nil)
        #expect(abs((s?.tempC ?? 0) - 50.0) < 0.0001)
        #expect(s?.sourceKey.contains("3 sensors") == true)
    }

    @Test func excludes_non_cpu_sensors() {
        // Battery / NAND / GPU sensors must not pull the average.
        let s = CPUTempProbe.selectCPUTemp(from: [
            r("PMU tdie0", 50),
            r("gas gauge battery", 34),
            r("NAND CH0 temp", 36),
            r("GPU tdie", 70),
        ])
        #expect(s != nil)
        #expect(abs((s?.tempC ?? 0) - 50.0) < 0.0001)   // only the CPU tdie counts
    }

    @Test func abstains_when_no_cpu_sensors() {
        #expect(CPUTempProbe.selectCPUTemp(from: [
            r("gas gauge battery", 34), r("NAND CH0 temp", 36),
        ]) == nil)
    }

    @Test func abstains_on_empty() {
        #expect(CPUTempProbe.selectCPUTemp(from: []) == nil)
    }

    /// Regression: a genuine critical-range die reading must survive selection
    /// (window ceiling > criticalC) so a critical alert can actually fire.
    @Test func critical_range_reading_selected_and_fires() {
        let s = CPUTempProbe.selectCPUTemp(from: [r("PMU tdie0", 102)])
        #expect(s?.tempC == 102.0)
        #expect(CPUTempProbe.severity(for: s?.tempC ?? -1, thresholds: .default) == .critical)
    }

    @Test func drops_implausible_values() {
        // 0 °C parked sensor and a 200 °C glitch are both dropped; the good
        // reading remains.
        let s = CPUTempProbe.selectCPUTemp(from: [
            r("PMU tdie0", 0), r("PMU tdie1", 49), r("PMU tdie2", 200),
        ])
        #expect(s?.tempC == 49.0)
        #expect(s?.sourceKey.contains("1 sensors") == true)
    }

    @Test func ceiling_excludes_120_plus() {
        #expect(CPUTempProbe.selectCPUTemp(from: [r("cpu", 120.0)]) == nil)
        #expect(CPUTempProbe.selectCPUTemp(from: [r("cpu", 119.9)]) != nil)
    }

    @Test func floor_excludes_below_5() {
        #expect(CPUTempProbe.selectCPUTemp(from: [r("cpu", 4.9)]) == nil)
        #expect(CPUTempProbe.selectCPUTemp(from: [r("cpu", 5.0)]) != nil)
    }

    @Test func sensor_name_classification() {
        #expect(CPUTempProbe.isCPUDieSensor("PMU tdie3"))
        #expect(CPUTempProbe.isCPUDieSensor("pACC MTR Temp Sensor"))
        #expect(CPUTempProbe.isCPUDieSensor("eACC"))
        #expect(CPUTempProbe.isCPUDieSensor("CPU Performance Core"))
        #expect(!CPUTempProbe.isCPUDieSensor("gas gauge battery"))
        #expect(!CPUTempProbe.isCPUDieSensor("NAND CH0 temp"))
        #expect(!CPUTempProbe.isCPUDieSensor("GPU tdie"))   // GPU excluded despite "tdie"
    }

    // MARK: - severity mapping (retained)

    @Test func severity_warn_critical_ok() {
        #expect(CPUTempProbe.severity(for: 95, thresholds: .default) == .warn)
        #expect(CPUTempProbe.severity(for: 105, thresholds: .default) == .critical)
        #expect(CPUTempProbe.severity(for: 70, thresholds: .default) == nil)
    }
}
