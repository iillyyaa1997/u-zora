import Foundation
import Testing
@testable import uZora

@Suite("SyntheticAlertProbe (E2E test seam)")
struct SyntheticAlertProbeTests {

    @Test func warnMode_emitsSingleWarnAlert() async throws {
        let probe = SyntheticAlertProbe(mode: "warn")
        let alerts = try await probe.run()
        #expect(alerts.count == 1)
        #expect(alerts.first?.severity == .warn)
        #expect(alerts.first?.probe == "synthetic")
        #expect(alerts.first?.key == "e2e")
    }

    @Test func criticalMode_emitsCriticalAlert() async throws {
        let probe = SyntheticAlertProbe(mode: "critical")
        let alerts = try await probe.run()
        #expect(alerts.first?.severity == .critical)
    }

    @Test func clearMode_emitsNothing() async throws {
        let probe = SyntheticAlertProbe(mode: "clear")
        let alerts = try await probe.run()
        #expect(alerts.isEmpty)
    }

    @Test func currentMetrics_alwaysReports() async {
        let warn = await SyntheticAlertProbe(mode: "warn").currentMetrics()
        #expect(warn["synthetic_value"] == 1.0)
        let crit = await SyntheticAlertProbe(mode: "critical").currentMetrics()
        #expect(crit["synthetic_value"] == 2.0)
    }

    @Test func fromEnvironment_nilWhenUnset() {
        // The test process does not set UZORA_E2E_SYNTHETIC_ALERT, so the
        // factory must return nil — guaranteeing the probe never registers
        // in a normal run.
        if ProcessInfo.processInfo.environment["UZORA_E2E_SYNTHETIC_ALERT"] == nil {
            #expect(SyntheticAlertProbe.fromEnvironment() == nil)
        }
    }

    @Test func defaultRegistry_excludesSynthetic_withoutEnv() async {
        // Default registry must hold exactly the 10 production probes when
        // the E2E env var is absent.
        if ProcessInfo.processInfo.environment["UZORA_E2E_SYNTHETIC_ALERT"] == nil {
            let registry = await ProbeRegistry.defaultPopulated()
            let names = await registry.registeredNames()
            #expect(names.count == 10)
            #expect(!names.contains("synthetic"))
        }
    }
}
