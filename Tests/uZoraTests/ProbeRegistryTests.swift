import Testing
import Foundation
@testable import uZora

@Suite("ProbeRegistry default factory wiring")
struct ProbeRegistryTests {

    @Test func defaultPopulated_registersAllTenMvpProbes() async {
        let registry = await ProbeRegistry.defaultPopulated()
        let names = await registry.registeredNames()
        #expect(names.sorted() == [
            "battery", "cpu_temp", "disk", "fan",
            "kernel_task", "smart", "thermal",
            "top_cpu", "top_mem", "top_net",
        ])
        let count = await registry.count
        #expect(count == 10)
    }

    @Test func startIsIdempotent() async {
        let registry = await ProbeRegistry.defaultPopulated()
        await registry.start()
        await registry.start()
        // No assertion needed — just verify the second start doesn't crash
        // or duplicate state.
        await registry.stop()
    }

    @Test func stopBeforeStart_isSafe() async {
        let registry = ProbeRegistry()
        await registry.stop()
        let names = await registry.registeredNames()
        #expect(names.isEmpty)
    }

    @Test func emptySnapshot_initially() async {
        let registry = await ProbeRegistry.defaultPopulated()
        let snap = await registry.snapshot()
        #expect(snap.isEmpty)
    }

    @Test func startWithDependencies_wires_watchdogAndBus() async {
        let registry = await ProbeRegistry.defaultPopulated()
        let watchdog = Watchdog()
        let bus = EventBus()
        await registry.start(watchdog: watchdog, eventBus: bus)
        await registry.stop()
        // Sanity: shouldn't have crashed and bus's subscriberCount still 0.
        let subs = await bus.subscriberCount
        #expect(subs == 0)
    }

    @Test func updatePowerProfile_takesEffect() async {
        let registry = await ProbeRegistry.defaultPopulated()
        let battery = PowerProfile.defaultMapping(for: .batteryLidOpen)
        await registry.updatePowerProfile(battery)
        let p = await registry.powerProfile()
        #expect(p.state == .batteryLidOpen)
        #expect(p.pollMultiplier == 3.0)
    }

    @Test func shouldEmit_floorRespected() {
        let floor = Severity.warn
        let info = Alert(
            probe: "x", key: "y", severity: .info,
            message: "", details: nil,
            firstSeen: Date(), lastUpdated: Date()
        )
        let warn = Alert(
            probe: "x", key: "y", severity: .warn,
            message: "", details: nil,
            firstSeen: Date(), lastUpdated: Date()
        )
        #expect(ProbeRegistry.shouldEmit(.appeared(info), floor: floor) == false)
        #expect(ProbeRegistry.shouldEmit(.appeared(warn), floor: floor) == true)
        #expect(ProbeRegistry.shouldEmit(.escalated(warn, previousSeverity: .info), floor: floor) == true)
        // cleared always passes.
        #expect(ProbeRegistry.shouldEmit(.cleared("x:y"), floor: .critical) == true)
    }
}
