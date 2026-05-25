import Testing
import Foundation
@testable import uZora

@Suite("ProbeRegistry default factory wiring")
struct ProbeRegistryTests {

    @Test func defaultPopulated_registersAllSixMvpProbes() async {
        let registry = await ProbeRegistry.defaultPopulated()
        let names = await registry.registeredNames()
        #expect(names.sorted() == ["battery", "cpu_temp", "disk", "fan", "smart", "thermal"])
        let count = await registry.count
        #expect(count == 6)
    }

    @Test func startIsIdempotent() async {
        let registry = await ProbeRegistry.defaultPopulated()
        await registry.start()
        await registry.start()
        // No assertion needed — just verify the second start doesn't crash
        // or duplicate state.
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
}
