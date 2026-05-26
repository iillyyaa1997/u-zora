import Foundation
import os

/// Append-only daily-rotated JSONL writer for `WatchdogEvent`s.
///
/// Files live under `baseDir/events-YYYY-MM-DD.jsonl` (UTC day boundary).
/// Each event becomes one line of UTF-8 JSON terminated by `\n`. Old
/// files are purged on a daily rotation tick when their date is more than
/// `retentionDays` behind today.
///
/// Concurrency: this is an `actor`. Callers `await sink.emit(event)`;
/// internally the actor opens / rotates / appends serially so there is no
/// interleaving of partial lines.
///
/// Schema (one line per event):
/// ```json
/// {"ts":"2026-05-26T01:42:33.123Z","kind":"appeared","alert":{...}}
/// {"ts":"...","kind":"escalated","alert":{...},"previous_severity":"warn"}
/// {"ts":"...","kind":"cleared","alert_id":"disk:/"}
/// ```
public actor JSONLEventSink {

    public enum Error: Swift.Error, Equatable {
        case ioFailure(String)
    }

    /// One JSONL line as written to disk. The `event` payload is the
    /// `WatchdogEvent` Codable representation; `ts` is prepended.
    public struct Line: Codable, Equatable, Sendable {
        public let ts: Date

        // Flattened `kind` + payload keys (no nested "event" object) so
        // consumers (jq, Python, Monitor tool) don't need to walk into a
        // sub-document. Matches DESIGN §3 cross-channel parity rule.
        public let kind: Kind
        public let alert: Alert?
        public let previousSeverity: Severity?
        public let alertID: String?

        public enum Kind: String, Codable, Sendable {
            case appeared, escalated, cleared
        }

        public enum CodingKeys: String, CodingKey {
            case ts
            case kind
            case alert
            case previousSeverity = "previous_severity"
            case alertID = "alert_id"
        }

        public init(timestamp: Date, event: WatchdogEvent) {
            self.ts = timestamp
            switch event {
            case .appeared(let a):
                self.kind = .appeared
                self.alert = a
                self.previousSeverity = nil
                self.alertID = nil
            case .escalated(let a, let prev):
                self.kind = .escalated
                self.alert = a
                self.previousSeverity = prev
                self.alertID = nil
            case .cleared(let id):
                self.kind = .cleared
                self.alert = nil
                self.previousSeverity = nil
                self.alertID = id
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(ts, forKey: .ts)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(alert, forKey: .alert)
            try c.encodeIfPresent(previousSeverity, forKey: .previousSeverity)
            try c.encodeIfPresent(alertID, forKey: .alertID)
        }
    }

    public let baseDir: URL
    public let retentionDays: Int

    private var currentDay: String?       // "YYYY-MM-DD" of opened handle
    private var currentHandle: FileHandle?

    private let encoder: JSONEncoder
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "jsonl")

    private var rotationTask: Task<Void, Never>?

    public init(baseDir: URL? = nil, retentionDays: Int = 30) throws {
        let resolved = baseDir ?? JSONLEventSink.defaultDirectory()
        try JSONLEventSink.ensureDirectory(resolved)
        self.baseDir = resolved
        self.retentionDays = retentionDays
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Match the REST/SSE channel key style. ADR-0002 confirmation #2
        // requires cross-channel payload parity.
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    /// Default JSONL directory:
    ///   `~/Library/Application Support/uZora/events/`
    /// Override with `UZORA_EVENTS_DIR` env var (used for tests too).
    public static func defaultDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["UZORA_EVENTS_DIR"],
           !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport.appendingPathComponent("uZora", isDirectory: true)
            .appendingPathComponent("events", isDirectory: true)
    }

    private static func ensureDirectory(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Write a single event to today's file. Rolls the file boundary if
    /// the previous line landed on a prior UTC day.
    public func emit(_ event: WatchdogEvent, at timestamp: Date = Date()) async {
        let line = Line(timestamp: timestamp, event: event)
        let dayKey = JSONLEventSink.dayKey(for: timestamp)
        do {
            try ensureOpenHandle(forDay: dayKey)
            guard let handle = currentHandle else { return }
            let payload = try encoder.encode(line)
            try handle.write(contentsOf: payload)
            try handle.write(contentsOf: Data([0x0A])) // "\n"
        } catch {
            log.error("JSONL emit failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Begin a background loop that runs `purgeOldFiles()` once an hour
    /// and rotates the day boundary even if `emit` hasn't been called.
    /// Idempotent.
    public func startRotationLoop(interval: Duration = .seconds(3600)) {
        guard rotationTask == nil else { return }
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runRotationTick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Stop the rotation loop. Idempotent.
    public func stopRotationLoop() {
        rotationTask?.cancel()
        rotationTask = nil
    }

    /// Synchronously perform a rotation tick: close yesterday's handle if
    /// the day rolled, then purge expired files. Exposed for tests.
    public func runRotationTick(at timestamp: Date = Date()) {
        let dayKey = JSONLEventSink.dayKey(for: timestamp)
        if let current = currentDay, current != dayKey {
            try? currentHandle?.close()
            currentHandle = nil
            currentDay = nil
        }
        purgeOldFiles(reference: timestamp)
    }

    /// Path of the file for a given UTC day key.
    public func fileURL(forDay day: String) -> URL {
        baseDir.appendingPathComponent("events-\(day).jsonl", isDirectory: false)
    }

    /// List currently present JSONL files in the base directory.
    public func currentFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil))
            .map { $0.filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" } } ?? []
    }

    /// Test affordance: synchronously close the open handle (e.g. before
    /// asserting file contents).
    public func flush() throws {
        try currentHandle?.synchronize()
    }

    public func close() {
        try? currentHandle?.close()
        currentHandle = nil
        currentDay = nil
        rotationTask?.cancel()
        rotationTask = nil
    }

    // MARK: - Internals

    private func ensureOpenHandle(forDay dayKey: String) throws {
        if currentDay == dayKey, currentHandle != nil {
            return
        }
        if let handle = currentHandle {
            try? handle.close()
            currentHandle = nil
        }
        let url = fileURL(forDay: dayKey)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw Error.ioFailure("open(\(url.path)) failed: \(error)")
        }
        try handle.seekToEnd()
        currentHandle = handle
        currentDay = dayKey
    }

    private func purgeOldFiles(reference: Date) {
        let files = currentFiles()
        for url in files {
            guard let day = JSONLEventSink.dayKey(fromFilename: url.lastPathComponent) else { continue }
            guard let fileDate = JSONLEventSink.date(fromDayKey: day) else { continue }
            let cutoff = Calendar.utc.date(byAdding: .day, value: -retentionDays, to: reference) ?? reference
            // Use start-of-day for fair comparison.
            let fileStart = Calendar.utc.startOfDay(for: fileDate)
            let cutoffStart = Calendar.utc.startOfDay(for: cutoff)
            if fileStart < cutoffStart {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Day key helpers

    public static func dayKey(for date: Date) -> String {
        formatter.string(from: date)
    }

    public static func date(fromDayKey day: String) -> Date? {
        formatter.date(from: day)
    }

    public static func dayKey(fromFilename name: String) -> String? {
        // expects "events-YYYY-MM-DD.jsonl"
        guard name.hasPrefix("events-"),
              name.hasSuffix(".jsonl") else { return nil }
        let stripped = name.dropFirst("events-".count).dropLast(".jsonl".count)
        return String(stripped)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

private extension Calendar {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }()
}
