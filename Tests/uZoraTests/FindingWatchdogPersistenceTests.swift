import Foundation
import Testing
@testable import uZora

@Suite("FindingWatchdog state persistence across instances")
struct FindingWatchdogPersistenceTests {

    private static func tempStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-finding-watchdog-tests")
            .appendingPathComponent("\(UUID().uuidString).json")
    }

    private static func finding(
        _ detector: String,
        _ subject: String,
        _ sev: Severity,
        _ conf: Confidence
    ) -> Finding {
        Finding(
            detector: detector,
            subject: subject,
            severity: sev,
            confidence: conf,
            title: "\(detector):\(subject)",
            explanation: "test",
            evidence: nil,
            suggestedAction: nil,
            firstSeen: Date(),
            lastUpdated: Date()
        )
    }

    @Test func freshURL_loadsEmpty() async {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd = FindingWatchdog(stateURL: url)
        let snap = await wd.snapshot()
        #expect(snap.isEmpty)
    }

    @Test func step_persistsToFile() async {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd = FindingWatchdog(stateURL: url)
        let f = Self.finding("runaway_daemon", "ecosystemd", .warn, .low)
        let events = await wd.step(currentFindings: [f])
        #expect(events.count == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func newInstance_loadsPersistedState_suppressesDiagnosedEvent() async {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // First instance: finding appears.
        let wd1 = FindingWatchdog(stateURL: url)
        let f = Self.finding("runaway_daemon", "ecosystemd", .warn, .low)
        let firstEvents = await wd1.step(currentFindings: [f])
        #expect(firstEvents == [.diagnosed(f)])
        // Second instance (simulating restart) with same URL.
        let wd2 = FindingWatchdog(stateURL: url)
        let secondEvents = await wd2.step(currentFindings: [f])
        // Idempotent — same finding at same severity+confidence must NOT
        // re-emit `diagnosed`.
        #expect(secondEvents.isEmpty, "FindingWatchdog must not re-emit diagnosed for a persisted finding after restart")
    }

    @Test func newInstance_detectsSeverityRise_acrossRestart() async {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd1 = FindingWatchdog(stateURL: url)
        _ = await wd1.step(currentFindings: [Self.finding("runaway_daemon", "ecosystemd", .warn, .low)])
        let wd2 = FindingWatchdog(stateURL: url)
        let bumped = Self.finding("runaway_daemon", "ecosystemd", .critical, .low)
        let events = await wd2.step(currentFindings: [bumped])
        // Severity rise across restart still emits rediagnosed.
        if case .rediagnosed(let f, let prevSev, let prevConf) = events.first {
            #expect(f.severity == .critical)
            #expect(prevSev == .warn)
            #expect(prevConf == .low)
        } else {
            Issue.record("Expected .rediagnosed event after severity bump across restart; got \(events)")
        }
    }

    @Test func newInstance_detectsResolved_acrossRestart() async {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd1 = FindingWatchdog(stateURL: url)
        _ = await wd1.step(currentFindings: [Self.finding("runaway_daemon", "ecosystemd", .warn, .low)])
        let wd2 = FindingWatchdog(stateURL: url)
        let events = await wd2.step(currentFindings: [])
        if case .resolved(let id) = events.first {
            #expect(id == "runaway_daemon:ecosystemd")
        } else {
            Issue.record("Expected .resolved event when finding disappears across restart; got \(events)")
        }
    }

    @Test func reset_wipesPersistedFile() async {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd = FindingWatchdog(stateURL: url)
        _ = await wd.step(currentFindings: [Self.finding("runaway_daemon", "ecosystemd", .warn, .low)])
        #expect(FileManager.default.fileExists(atPath: url.path))
        await wd.reset()
        #expect(!FileManager.default.fileExists(atPath: url.path), "reset() must also delete the persisted state file")
    }

    @Test func idempotentTick_doesNotWriteFile() async throws {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd = FindingWatchdog(stateURL: url)
        _ = await wd.step(currentFindings: [Self.finding("runaway_daemon", "ecosystemd", .warn, .low)])
        let mtime1 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(50))
        // Same finding, same severity+confidence — no events, no rewrite.
        let events = await wd.step(currentFindings: [Self.finding("runaway_daemon", "ecosystemd", .warn, .low)])
        #expect(events.isEmpty)
        let mtime2 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(mtime1 == mtime2, "FindingWatchdog must not rewrite state file when nothing changed")
    }

    @Test func silentDeWorsening_stillHitsDisk() async throws {
        // A de-worsening emits NO event but changes the persisted state, so it
        // must hit disk (mirrors Watchdog's de-escalation rationale).
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd = FindingWatchdog(stateURL: url)
        _ = await wd.step(currentFindings: [Self.finding("runaway_daemon", "ecosystemd", .critical, .high)])
        let mtime1 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(50))
        // Downgrade severity+confidence — no event, but state changed → rewrite.
        let events = await wd.step(currentFindings: [Self.finding("runaway_daemon", "ecosystemd", .warn, .low)])
        #expect(events.isEmpty)
        let mtime2 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(mtime1 != mtime2, "silent de-worsening must still rewrite the state file")
        // And a fresh instance must reload the LOWER level (no stale higher).
        let wd2 = FindingWatchdog(stateURL: url)
        let snap = await wd2.snapshot()
        #expect(snap["runaway_daemon:ecosystemd"]?.severity == .warn)
        #expect(snap["runaway_daemon:ecosystemd"]?.confidence == .low)
    }
}
