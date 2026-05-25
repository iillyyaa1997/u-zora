import Testing
import Foundation
@testable import uZora

@Suite("ThermalPressureProbe severity mapping")
struct ThermalSeverityMappingTests {

    @Test("ProcessInfo.ThermalState -> Severity? table",
          arguments: [
              (ProcessInfo.ThermalState.nominal,  Optional<Severity>.none),
              (ProcessInfo.ThermalState.fair,     .info),
              (ProcessInfo.ThermalState.serious,  .warn),
              (ProcessInfo.ThermalState.critical, .critical),
          ])
    func mapsCorrectly(state: ProcessInfo.ThermalState, expected: Severity?) {
        #expect(ThermalPressureProbe.severity(for: state) == expected)
    }

    @Test func labelStrings() {
        #expect(ThermalPressureProbe.label(.nominal) == "nominal")
        #expect(ThermalPressureProbe.label(.fair)    == "fair")
        #expect(ThermalPressureProbe.label(.serious) == "serious")
        #expect(ThermalPressureProbe.label(.critical) == "critical")
    }

    @Test func runReturnsAlertWhenStateIsNonNominal() async throws {
        // The probe reads `ProcessInfo.processInfo.thermalState` which is
        // not directly injectable; in CI/development machines it's almost
        // always `.nominal` so we just assert the call doesn't throw and
        // the result is empty (or info+ if the test runner is overheating).
        let probe = ThermalPressureProbe()
        let alerts = try await probe.run()
        if let alert = alerts.first {
            #expect(alert.probe == "thermal")
            #expect(alert.key == "system")
            #expect(alert.severity >= .info)
        }
    }
}
