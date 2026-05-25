import Testing
import Foundation
@testable import uZora

/// "Smoke" integration suite that exercises the *real* IOKit/SMC samplers
/// on the host running the test. Purposefully tolerant — these tests must
/// pass on every Apple-Silicon Mac (MacBook Air with no fans, mini with
/// no battery, Pro/Studio with full hardware) without bespoke fixtures.
///
/// They assert *shape* and *non-crash*, not concrete values. Real fixture
/// tests land in Phase 7 alongside recorded ioreg dumps.
@Suite("Live IOKit/SMC smoke tests (Phase 2)")
struct SmokeIntegration {

    @Test func diskSample_live() async throws {
        let probe = DiskFreeProbe()
        // Should not throw; alerts may be empty on a healthy host.
        let alerts = try await probe.run()
        // Either empty (healthy) or one alert keyed at "/".
        #expect(alerts.allSatisfy { $0.key == "/" })

        // sampleRoot must return *something* on a real OS.
        let s = try #require(DiskFreeProbe.sampleRoot())
        #expect(s.totalBytes > 0)
        #expect(s.mount == "/")
    }

    @Test func batterySample_live_doesNotCrash() async throws {
        // Returns nil on mini/Studio/iMac/Pro; returns Sample on laptops.
        let probe = BatteryProbe()
        _ = try await probe.run() // shape only
        let s = BatteryProbe.sampleInternalBattery()
        if let s {
            #expect((0...100).contains(s.chargePct))
        }
    }

    @Test func thermalSample_live() async throws {
        let probe = ThermalPressureProbe()
        let alerts = try await probe.run()
        // Either 0 (nominal) or 1 alert with key=system.
        #expect(alerts.count <= 1)
        #expect(alerts.allSatisfy { $0.key == "system" })
    }

    @Test func fanSample_live_doesNotCrash() async throws {
        let probe = FanRPMProbe()
        _ = try await probe.run()
        // sampleFans returns nil only if SMC is unavailable; otherwise a
        // (possibly empty) CompositeSample.
    }

    @Test func cpuTempSample_live_doesNotCrash() async throws {
        let probe = CPUTempProbe()
        _ = try await probe.run()
        // Sample may be nil on hardware where none of the candidate SMC
        // keys answer — that is the documented graceful-degrade path.
    }

    @Test func smartSample_live_doesNotCrash() async throws {
        let probe = SMARTProbe()
        _ = try await probe.run()
    }

    @Test func registryFullPipeline() async throws {
        let registry = await ProbeRegistry.defaultPopulated()
        await registry.start()
        let names = await registry.registeredNames()
        #expect(names.count == 6)
        await registry.stop()
    }
}
