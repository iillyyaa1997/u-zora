import Foundation
import os

/// Shared append-only, daily-rotated, retention-pruned JSONL file writer.
///
/// Factored out of the `JSONLEventSink` pattern so the Q10 `AuditLog` reuses
/// the exact same proven rotation + retention mechanics (UTC day boundary,
/// `<prefix>-YYYY-MM-DD.jsonl`, purge files older than `retentionDays`)
/// instead of duplicating them. `JSONLEventSink` keeps its own bespoke
/// `Line`/`Codable` schema; this writer is payload-agnostic — callers hand
/// it pre-encoded `Data` (one JSON object, no trailing newline) and it
/// appends the newline.
///
/// Concurrency: an `actor`. Callers `await writer.append(data)`; the actor
/// opens / rotates / appends serially so partial lines never interleave.
public actor RotatingJSONLWriter {

    public enum Error: Swift.Error, Equatable {
        case ioFailure(String)
    }

    /// Directory holding the `<prefix>-*.jsonl` files.
    public let baseDir: URL
    /// Filename prefix, e.g. `"events"` or `"actions-audit"`.
    public let prefix: String
    /// Files whose UTC day is more than this many days behind today are
    /// purged on a rotation tick.
    public let retentionDays: Int

    private var currentDay: String?
    private var currentHandle: FileHandle?
    private var rotationTask: Task<Void, Never>?
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "jsonl-writer")

    public init(baseDir: URL, prefix: String, retentionDays: Int) throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        self.baseDir = baseDir
        self.prefix = prefix
        self.retentionDays = retentionDays
    }

    /// Append one pre-encoded JSON line (the writer adds the `\n`). Rolls the
    /// file boundary if the previous line landed on a prior UTC day.
    public func append(_ jsonLine: Data, at timestamp: Date = Date()) {
        let dayKey = Self.dayKey(for: timestamp)
        do {
            try ensureOpenHandle(forDay: dayKey)
            guard let handle = currentHandle else { return }
            try handle.write(contentsOf: jsonLine)
            try handle.write(contentsOf: Data([0x0A])) // "\n"
        } catch {
            log.error("JSONL append failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Begin a background loop that runs a rotation tick once per `interval`.
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

    public func stopRotationLoop() {
        rotationTask?.cancel()
        rotationTask = nil
    }

    /// Close yesterday's handle if the day rolled, then purge expired files.
    /// Exposed for tests.
    public func runRotationTick(at timestamp: Date = Date()) {
        let dayKey = Self.dayKey(for: timestamp)
        if let current = currentDay, current != dayKey {
            try? currentHandle?.close()
            currentHandle = nil
            currentDay = nil
        }
        purgeOldFiles(reference: timestamp)
    }

    public func fileURL(forDay day: String) -> URL {
        baseDir.appendingPathComponent("\(prefix)-\(day).jsonl", isDirectory: false)
    }

    /// All `<prefix>-*.jsonl` files currently present.
    public func currentFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil))
            .map { $0.filter { $0.lastPathComponent.hasPrefix("\(prefix)-") && $0.pathExtension == "jsonl" } } ?? []
    }

    /// Synchronously flush the open handle (test affordance).
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
        if currentDay == dayKey, currentHandle != nil { return }
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
        for url in currentFiles() {
            guard let day = Self.dayKey(fromFilename: url.lastPathComponent, prefix: prefix),
                  let fileDate = Self.date(fromDayKey: day) else { continue }
            let cutoff = Calendar.utcRotating.date(byAdding: .day, value: -retentionDays, to: reference) ?? reference
            let fileStart = Calendar.utcRotating.startOfDay(for: fileDate)
            let cutoffStart = Calendar.utcRotating.startOfDay(for: cutoff)
            if fileStart < cutoffStart {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Day-key helpers

    public static func dayKey(for date: Date) -> String { formatter.string(from: date) }
    public static func date(fromDayKey day: String) -> Date? { formatter.date(from: day) }

    public static func dayKey(fromFilename name: String, prefix: String) -> String? {
        let lead = "\(prefix)-"
        guard name.hasPrefix(lead), name.hasSuffix(".jsonl") else { return nil }
        let stripped = name.dropFirst(lead.count).dropLast(".jsonl".count)
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
    static let utcRotating: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }()
}
