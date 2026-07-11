import Foundation
import os

/// The **watched-file outbox** push backend (plan B3, backend #2 — near-free,
/// zero egress). Appends one JSON line per pushed `PushEvent` to an append-only,
/// daily-rotated JSONL file a LOCAL agent tails. Reuses the shared
/// `RotatingJSONLWriter` (same rotation + retention as the audit log).
///
/// `outbox_path` names a DIRECTORY (empty ⇒ a default under Application
/// Support/uZora); the files are `push-outbox-YYYY-MM-DD.jsonl` inside it. A
/// consumer tails the newest `push-outbox-*.jsonl`. (The rotating writer owns
/// the `-YYYY-MM-DD` suffix, so the outbox is a rotated file set rather than one
/// fixed filename — this buys retention pruning for free and matches how every
/// other JSONL surface in uZora is laid out.)
public actor PushOutbox {

    /// One outbox line — the `PushEvent` fields flattened + a schema tag so a
    /// consumer can version-gate. snake_case keys (idiomatic for jq / Python /
    /// shell), mirroring the `DiagnosisEventLine` flat shape.
    public struct Line: Sendable, Codable, Equatable {
        public let schema: String
        public let ts: Date
        public let kind: String
        public let severity: String
        public let subject: String
        public let cleared: Bool
        public let summary: String

        public enum CodingKeys: String, CodingKey {
            case schema, ts, kind, severity, subject, cleared, summary
        }

        public init(event: PushEvent) {
            self.schema = PushOutbox.schemaTag
            self.ts = event.ts
            self.kind = event.kind.rawValue
            self.severity = event.severity.rawValue
            self.subject = event.subject
            self.cleared = event.cleared
            self.summary = event.summary
        }
    }

    /// The outbox line schema tag (versioned so a consumer can gate on it).
    public static let schemaTag = "uzora.push.v1"

    private let writer: RotatingJSONLWriter
    private let encoder: JSONEncoder
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "push-outbox")

    public init(baseDir: URL? = nil, retentionDays: Int = 30) throws {
        let resolved = baseDir ?? PushOutbox.defaultDirectory()
        self.writer = try RotatingJSONLWriter(baseDir: resolved, prefix: "push-outbox", retentionDays: retentionDays)
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    /// Resolve the outbox directory from the config `outbox_path`. Empty ⇒ the
    /// default under Application Support/uZora; otherwise the given path
    /// (tilde-expanded), treated as a directory.
    public static func resolveDirectory(from outboxPath: String) -> URL {
        let trimmed = outboxPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultDirectory() }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Default outbox directory: `~/Library/Application Support/uZora/`.
    public static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport.appendingPathComponent("uZora", isDirectory: true)
    }

    /// Append one JSON line for `event`. Returns `true` on success, `false` if
    /// encoding failed (an I/O failure inside the writer is logged there and
    /// still returns `true` here — the writer swallows it; encode is the only
    /// failure this backend surfaces to the circuit breaker).
    public func append(_ event: PushEvent) async -> Bool {
        do {
            let data = try encoder.encode(Line(event: event))
            await writer.append(data, at: event.ts)
            return true
        } catch {
            log.error("push-outbox encode failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    public func flush() async throws { try await writer.flush() }
    public func close() async { await writer.close() }
    public func startRotationLoop() async { await writer.startRotationLoop() }

    /// Today's outbox file URL (test affordance).
    public func todayFileURL(at ts: Date = Date()) async -> URL {
        await writer.fileURL(forDay: RotatingJSONLWriter.dayKey(for: ts))
    }
}
