import Foundation
import Testing
@testable import uZora

@Suite("Watchdog state persistence across instances")
struct WatchdogPersistenceTests {

    private static func tempStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-watchdog-tests")
            .appendingPathComponent("\(UUID().uuidString).json")
    }

    private static func alert(_ probe: String, _ key: String, _ sev: Severity) -> Alert {
        Alert(probe: probe, key: key, severity: sev, message: "\(probe):\(key)", details: nil, firstSeen: Date(), lastUpdated: Date())
    }

    @Test func freshURL_loadsEmpty() async {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd = Watchdog(stateURL: url)
        let snap = await wd.snapshot()
        #expect(snap.isEmpty)
    }

    @Test func step_persistsToFile() async {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd = Watchdog(stateURL: url)
        let a = Self.alert("disk", "/", .warn)
        let events = await wd.step(currentAlerts: [a])
        #expect(events.count == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func newInstance_loadsPersistedState_suppressesAppearedEvent() async {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // First instance: alert appears.
        let wd1 = Watchdog(stateURL: url)
        let a = Self.alert("disk", "/", .warn)
        let firstEvents = await wd1.step(currentAlerts: [a])
        #expect(firstEvents == [.appeared(a)])
        // Second instance (simulating restart) with same URL.
        let wd2 = Watchdog(stateURL: url)
        let secondEvents = await wd2.step(currentAlerts: [a])
        // Idempotent — same alert at same severity must NOT re-emit `appeared`.
        #expect(secondEvents.isEmpty, "Watchdog must not re-emit appeared for a persisted alert after restart")
    }

    @Test func newInstance_detectsEscalation_acrossRestart() async {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd1 = Watchdog(stateURL: url)
        _ = await wd1.step(currentAlerts: [Self.alert("disk", "/", .warn)])
        let wd2 = Watchdog(stateURL: url)
        let bumped = Self.alert("disk", "/", .critical)
        let events = await wd2.step(currentAlerts: [bumped])
        // Severity escalation across restart still emits.
        if case .escalated(let alert, let prev) = events.first {
            #expect(alert.severity == .critical)
            #expect(prev == .warn)
        } else {
            Issue.record("Expected .escalated event after severity bump across restart; got \(events)")
        }
    }

    @Test func newInstance_detectsClear_acrossRestart() async {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd1 = Watchdog(stateURL: url)
        _ = await wd1.step(currentAlerts: [Self.alert("disk", "/", .warn)])
        let wd2 = Watchdog(stateURL: url)
        let events = await wd2.step(currentAlerts: [])
        if case .cleared(let id) = events.first {
            #expect(id == "disk:/")
        } else {
            Issue.record("Expected .cleared event when alert disappears across restart; got \(events)")
        }
    }

    @Test func reset_wipesPersistedFile() async {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd = Watchdog(stateURL: url)
        _ = await wd.step(currentAlerts: [Self.alert("disk", "/", .warn)])
        #expect(FileManager.default.fileExists(atPath: url.path))
        await wd.reset()
        #expect(!FileManager.default.fileExists(atPath: url.path), "reset() must also delete the persisted state file")
    }

    @Test func idempotentTick_doesNotWriteFile() async throws {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd = Watchdog(stateURL: url)
        _ = await wd.step(currentAlerts: [Self.alert("disk", "/", .warn)])
        let mtime1 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(50))
        // Same alert, same severity — no events expected, file should not be rewritten.
        let events = await wd.step(currentAlerts: [Self.alert("disk", "/", .warn)])
        #expect(events.isEmpty)
        let mtime2 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(mtime1 == mtime2, "Watchdog must not rewrite state file when no events fired")
    }
}
