import Testing
import Foundation
@testable import uZora

@Suite("JSONLEventSink writes and rotation")
struct JSONLEventSinkTests {

    private func tempBaseDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-jsonl-tests-\(UUID().uuidString)", isDirectory: true)
        return base
    }

    private func sampleAlert(_ probe: String = "disk", key: String = "/", severity: Severity = .warn) -> Alert {
        Alert(
            probe: probe,
            key: key,
            severity: severity,
            message: "test",
            details: ["pct": "12"],
            firstSeen: Date(timeIntervalSince1970: 1_700_000_000),
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_500)
        )
    }

    @Test func emit_writesOneLine() async throws {
        let dir = tempBaseDir()
        let sink = try JSONLEventSink(baseDir: dir, retentionDays: 30)
        let ts = Date(timeIntervalSince1970: 1_715_000_000) // mid-2024
        await sink.emit(.appeared(sampleAlert()), at: ts)
        try await sink.flush()

        let day = JSONLEventSink.dayKey(for: ts)
        let url = await sink.fileURL(forDay: day)
        let content = try String(contentsOf: url, encoding: .utf8)
        // Exactly one line.
        #expect(content.split(separator: "\n").count == 1)
        #expect(content.contains("\"kind\":\"appeared\""))
        #expect(content.contains("\"alert\""))
        #expect(content.contains("disk:/") == false) // alert.id not in alert JSON
        #expect(content.contains("\"ts\""))
        await sink.close()
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func emit_appendsConsecutiveEvents() async throws {
        let dir = tempBaseDir()
        let sink = try JSONLEventSink(baseDir: dir)
        let ts = Date(timeIntervalSince1970: 1_715_000_000)
        await sink.emit(.appeared(sampleAlert()), at: ts)
        await sink.emit(.escalated(sampleAlert(severity: .critical), previousSeverity: .warn), at: ts.addingTimeInterval(60))
        await sink.emit(.cleared("disk:/"), at: ts.addingTimeInterval(120))
        try await sink.flush()
        let day = JSONLEventSink.dayKey(for: ts)
        let url = await sink.fileURL(forDay: day)
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 3)
        #expect(lines[0].contains("\"kind\":\"appeared\""))
        #expect(lines[1].contains("\"kind\":\"escalated\""))
        #expect(lines[1].contains("\"previous_severity\":\"warn\""))
        #expect(lines[2].contains("\"kind\":\"cleared\""))
        #expect(lines[2].contains("\"alert_id\":\"disk:/\""))
        await sink.close()
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func rotation_opensNewFileNextDay() async throws {
        let dir = tempBaseDir()
        let sink = try JSONLEventSink(baseDir: dir)
        let day1 = Date(timeIntervalSince1970: 1_715_000_000)
        let day2 = day1.addingTimeInterval(86_400 * 2)
        await sink.emit(.appeared(sampleAlert()), at: day1)
        await sink.emit(.appeared(sampleAlert(key: "/Volumes/X")), at: day2)
        try await sink.flush()

        let urls = await sink.currentFiles()
        #expect(urls.count == 2)
        let names = urls.map { $0.lastPathComponent }.sorted()
        let expectedDay1 = "events-\(JSONLEventSink.dayKey(for: day1)).jsonl"
        let expectedDay2 = "events-\(JSONLEventSink.dayKey(for: day2)).jsonl"
        #expect(names.contains(expectedDay1))
        #expect(names.contains(expectedDay2))
        await sink.close()
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func rotationTick_purgesOldFiles() async throws {
        let dir = tempBaseDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Create three stub files: one 60 days old, one 25 days old, one today.
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC")!
        let old = utc.date(byAdding: .day, value: -60, to: now)!
        let recent = utc.date(byAdding: .day, value: -25, to: now)!
        let today = now

        for date in [old, recent, today] {
            let day = JSONLEventSink.dayKey(for: date)
            let url = dir.appendingPathComponent("events-\(day).jsonl")
            try Data("{}\n".utf8).write(to: url)
        }
        // Sanity check
        var pre = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        pre = pre.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(pre.count == 3)

        // 30-day retention should kill the 60-day-old file.
        let sink = try JSONLEventSink(baseDir: dir, retentionDays: 30)
        await sink.runRotationTick(at: now)

        let after = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let names = after.map { $0.lastPathComponent }.sorted()
        let oldName = "events-\(JSONLEventSink.dayKey(for: old)).jsonl"
        #expect(!names.contains(oldName))
        #expect(names.count == 2)
        await sink.close()
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func dayKeyParsing_roundtrips() {
        let now = Date()
        let key = JSONLEventSink.dayKey(for: now)
        // Format: YYYY-MM-DD
        #expect(key.count == 10)
        #expect(key.contains("-"))
        let parsed = JSONLEventSink.date(fromDayKey: key)
        #expect(parsed != nil)

        let parsedKey = JSONLEventSink.dayKey(fromFilename: "events-2026-05-26.jsonl")
        #expect(parsedKey == "2026-05-26")
        #expect(JSONLEventSink.dayKey(fromFilename: "not-uzora.txt") == nil)
    }
}
