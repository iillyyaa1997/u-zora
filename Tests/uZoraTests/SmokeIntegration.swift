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
        #expect(names.count == 10)
        await registry.stop()
    }

    // MARK: - Phase 3 process-based probes — live smoke

    @Test func processSampler_live_doesNotCrash() async throws {
        // listAllPIDs ought to return *something* on every running Mac.
        let pids = ProcessSampler.listAllPIDs()
        #expect(!pids.isEmpty)
        // hostTotalMemoryBytes returns 0 only when sysctl misbehaves.
        let mem = ProcessSampler.hostTotalMemoryBytes()
        #expect(mem > 0)
    }

    @Test func kernelTask_live_baselineCall() async throws {
        let probe = KernelTaskProbe()
        // First call primes the prior snapshot; should not throw and
        // should not emit (no delta available yet).
        let alerts = try await probe.run()
        #expect(alerts.isEmpty)
    }

    @Test func topCPU_live_doesNotCrash() async throws {
        let probe = TopCPUProcessProbe()
        _ = try await probe.run()
    }

    @Test func topMem_live_emitsShapeOrEmpty() async throws {
        let probe = TopMemoryProcessProbe()
        let alerts = try await probe.run()
        // Either no alert (top process under 8 GB) or 1 alert keyed on top
        // process. Never more.
        #expect(alerts.count <= 1)
        if let alert = alerts.first {
            #expect(alert.probe == "top_mem")
            #expect(alert.details?["host_total_mb"] != nil)
        }
    }

    @Test func topNet_live_unavailableOrEmpty() async throws {
        // nettop may take ~1 s; test should still succeed in <5s.
        let probe = TopNetworkProcessProbe()
        let alerts = try await probe.run()
        // Either empty (no traffic / nettop unparsable) or one alert.
        #expect(alerts.count <= 1)
    }

    @Test func powerProfileMonitor_live_currentReturnsState() async {
        let monitor = PowerProfileMonitor()
        let profile = await monitor.current()
        #expect(PowerState.allCases.contains(profile.state))
    }
}
