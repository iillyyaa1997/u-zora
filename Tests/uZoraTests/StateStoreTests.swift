import Testing
import Foundation
@testable import uZora

@Suite("StateStore in-memory snapshot logic")
struct StateStoreTests {

    private func alert(_ key: String, severity: Severity = .warn) -> Alert {
        Alert(
            probe: "disk",
            key: key,
            severity: severity,
            message: "m",
            details: nil,
            firstSeen: Date(),
            lastUpdated: Date()
        )
    }

    @Test func appeared_addsAlert() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("/")))
        let active = await store.activeAlerts()
        #expect(active.count == 1)
        #expect(active.first?.key == "/")
    }

    @Test func escalated_updatesSeverity() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("/", severity: .warn)))
        await store.ingest(.escalated(alert("/", severity: .critical), previousSeverity: .warn))
        let active = await store.activeAlerts()
        #expect(active.count == 1)
        #expect(active.first?.severity == .critical)
    }

    @Test func cleared_removesAlert() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("/")))
        await store.ingest(.cleared("disk:/"))
        let active = await store.activeAlerts()
        #expect(active.isEmpty)
    }

    @Test func severityFilter() async {
        let store = StateStore()
        await store.ingest(.appeared(alert("/", severity: .info)))
        await store.ingest(.appeared(alert("/Volumes/X", severity: .warn)))
        await store.ingest(.appeared(alert("/Volumes/Y", severity: .critical)))
        let warnOrAbove = await store.activeAlerts(minSeverity: .warn)
        #expect(warnOrAbove.count == 2)
        let critOnly = await store.activeAlerts(minSeverity: .critical)
        #expect(critOnly.count == 1)
    }

    @Test func ringBuffer_capsRecentEvents() async {
        let store = StateStore(ringBufferLimit: 5)
        for i in 0..<10 {
            await store.ingest(.appeared(alert("/\(i)")))
        }
        let count = await store.recordedCount
        #expect(count == 5)
        let recent = await store.recent(100)
        #expect(recent.count == 5)
    }

    @Test func uptime_isMonotonic() async {
        let store = StateStore()
        let u1 = await store.uptime()
        try? await Task.sleep(for: .milliseconds(20))
        let u2 = await store.uptime()
        #expect(u2 >= u1)
    }

    @Test func probesInventory_isStable() async {
        let store = StateStore()
        await store.setProbes([
            StateStore.ProbeInfo(name: "disk", pollIntervalSeconds: 60, lastRunAt: nil),
            StateStore.ProbeInfo(name: "battery", pollIntervalSeconds: 30, lastRunAt: nil),
        ])
        let probes = await store.probeInventory()
        #expect(probes.map(\.name) == ["battery", "disk"])
    }

    @Test func snapshot_aggregates() async {
        let store = StateStore()
        await store.setProbes([
            StateStore.ProbeInfo(name: "disk", pollIntervalSeconds: 60, lastRunAt: nil),
        ])
        await store.updatePowerState("acConnectedLidOpen")
        await store.ingest(.appeared(alert("/", severity: .warn)))
        let snap = await store.snapshot()
        #expect(snap.activeAlerts.count == 1)
        #expect(snap.probes.count == 1)
        #expect(snap.powerState == "acConnectedLidOpen")
        #expect(snap.uptimeSeconds >= 0)
    }
}
