import Testing
import Foundation
@testable import uZora

@Suite("AuditLog — append, rotation, always-on")
struct AuditLogTests {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-audit-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func entry(
        _ id: String = "prune_apfs_snapshots",
        trigger: ActionTrigger = .auto,
        decision: String = "allow",
        freed: UInt64 = 1_048_576,
        error: String? = nil,
        at ts: Date = Date(timeIntervalSince1970: 1_715_000_000)
    ) -> AuditLog.Entry {
        AuditLog.Entry(
            ts: ts, actionID: id, trigger: trigger, policyDecision: decision,
            freedBytes: freed, beforeFreeBytes: 100, afterFreeBytes: 100 + freed,
            skipped: false, error: error
        )
    }

    @Test func record_writesOneJSONLLine() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try AuditLog(baseDir: dir, retentionDays: 30)
        let ts = Date(timeIntervalSince1970: 1_715_000_000)
        await audit.record(entry(at: ts))
        try await audit.flush()

        let url = await audit.todayFileURL(at: ts)
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1)
        #expect(content.contains("\"action_id\":\"prune_apfs_snapshots\""))
        #expect(content.contains("\"trigger\":\"auto\""))
        #expect(content.contains("\"policy_decision\":\"allow\""))
        #expect(content.contains("\"freed_bytes\":1048576"))
        await audit.close()
    }

    @Test func record_appendsMultiple_andTailReadable() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try AuditLog(baseDir: dir, retentionDays: 30)
        let ts = Date(timeIntervalSince1970: 1_715_000_000)
        await audit.record(entry("a", at: ts))
        await audit.record(entry("b", trigger: .confirmed, at: ts.addingTimeInterval(1)))
        await audit.record(entry("c", trigger: .dryRun, decision: "dry_run", at: ts.addingTimeInterval(2)))
        try await audit.flush()

        let url = await audit.todayFileURL(at: ts)
        let lines = (try String(contentsOf: url, encoding: .utf8))
            .split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 3)
        // Each line is valid JSON decodable back to an Entry.
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        for line in lines {
            #expect((try? dec.decode(AuditLog.Entry.self, from: Data(line.utf8))) != nil)
        }
        let recent = await audit.recent(10)
        #expect(recent.count == 3)
        #expect(recent.map(\.actionID) == ["a", "b", "c"])
        await audit.close()
    }

    @Test func recordResult_andDenied_helpers() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try AuditLog(baseDir: dir, retentionDays: 30)
        let result = ActionResult(
            actionID: "brew_cleanup", succeeded: true, skipped: false,
            freedBytes: 2048, beforeFreeBytes: 10, afterFreeBytes: 2058
        )
        await audit.record(result: result, trigger: .confirmed, policyDecision: "allow")
        await audit.recordDenied(actionID: "clear_user_caches", trigger: .auto, reason: "cool_down")
        let recent = await audit.recent(10)
        #expect(recent.count == 2)
        #expect(recent[0].actionID == "brew_cleanup")
        #expect(recent[0].freedBytes == 2048)
        #expect(recent[1].policyDecision == "deny:cool_down")
        #expect(recent[1].skipped == true)
        await audit.close()
    }

    @Test func rotation_opensNewFileNextDay() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try AuditLog(baseDir: dir, retentionDays: 30)
        let day1 = Date(timeIntervalSince1970: 1_715_000_000)
        let day2 = day1.addingTimeInterval(86_400 * 2)
        await audit.record(entry("a", at: day1))
        await audit.record(entry("b", at: day2))
        try await audit.flush()
        // Two day-keyed files exist.
        let f1 = dir.appendingPathComponent("actions-audit-\(RotatingJSONLWriter.dayKey(for: day1)).jsonl")
        let f2 = dir.appendingPathComponent("actions-audit-\(RotatingJSONLWriter.dayKey(for: day2)).jsonl")
        #expect(FileManager.default.fileExists(atPath: f1.path))
        #expect(FileManager.default.fileExists(atPath: f2.path))
        await audit.close()
    }

    @Test func retention_purgesOldFiles() async throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Stub a 60-day-old + a today file, both with the audit prefix.
        let now = Date()
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let old = utc.date(byAdding: .day, value: -60, to: now)!
        for date in [old, now] {
            let day = RotatingJSONLWriter.dayKey(for: date)
            try Data("{}\n".utf8).write(to: dir.appendingPathComponent("actions-audit-\(day).jsonl"))
        }
        let audit = try AuditLog(baseDir: dir, retentionDays: 30)
        // Force a rotation tick (the actor holds its own writer; drive the
        // purge through a fresh writer pointed at the same dir).
        let writer = try RotatingJSONLWriter(baseDir: dir, prefix: "actions-audit", retentionDays: 30)
        await writer.runRotationTick(at: now)
        let names = (try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .map { $0.lastPathComponent }
        let oldName = "actions-audit-\(RotatingJSONLWriter.dayKey(for: old)).jsonl"
        #expect(!names.contains(oldName), "60-day-old audit file should be purged")
        await audit.close()
        await writer.close()
    }

    @Test func alwaysOn_noToggleHidesEntries() async throws {
        // There is no enable gate: every record() lands. (Always-on, Q4.)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try AuditLog(baseDir: dir, retentionDays: 30)
        for i in 0..<5 {
            await audit.record(entry("a\(i)"))
        }
        #expect(await audit.recordedCount == 5)
        await audit.close()
    }

    @Test func envOverride_directory() {
        // The audit dir honours UZORA_ACTIONS_AUDIT_PATH like the other
        // env-overrides (set in this process for the assertion only if present;
        // otherwise verify the default is under Application Support/uZora).
        let def = AuditLog.defaultDirectory()
        if let env = ProcessInfo.processInfo.environment["UZORA_ACTIONS_AUDIT_PATH"], !env.isEmpty {
            #expect(def.path == (env as NSString).expandingTildeInPath)
        } else {
            #expect(def.path.hasSuffix("uZora"))
        }
    }
}
