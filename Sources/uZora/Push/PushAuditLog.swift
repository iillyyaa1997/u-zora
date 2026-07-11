import Foundation
import os

/// The terminal outcome of a single push through the pipeline. Every event that
/// enters `ProactivePush.process(_:)` produces at least one audited outcome
/// (report 09 §1c). `sent` / `failed` are PER-BACKEND (one event with two
/// enabled backends audits two lines).
public enum PushOutcome: Sendable, Equatable {
    /// A backend accepted the push (exec exit 0 / outbox line written).
    case sent(backend: String)
    /// A backend failed (exec non-zero / not launched, outbox I/O error).
    case failed(backend: String)
    /// Suppressed as a repeat of the same subject+kind inside the cool-down.
    case coalesced
    /// Filtered out (below floor, wrong kind, cleared-off, rate-limited, or no
    /// backend enabled). `reason` is the short token.
    case dropped(reason: String)
    /// Refused by the circuit breaker (push auto-disabled after too many
    /// consecutive backend failures).
    case denied(reason: String)

    public var label: String {
        switch self {
        case .sent:      return "sent"
        case .failed:    return "failed"
        case .coalesced: return "coalesced"
        case .dropped:   return "dropped"
        case .denied:    return "denied"
        }
    }

    public var backend: String? {
        switch self {
        case .sent(let b), .failed(let b): return b
        default: return nil
        }
    }

    public var reason: String? {
        switch self {
        case .dropped(let r), .denied(let r): return r
        default: return nil
        }
    }
}

/// Append-only, daily-rotated JSONL audit for the proactive-push pipeline.
/// **Always-on** (like `AuditLog`): one line per push OUTCOME — the durable
/// record of what pushed, what was suppressed, and why.
///
/// File: `~/Library/Application Support/uZora/push-audit-YYYY-MM-DD.jsonl`
/// (override the directory with `UZORA_PUSH_AUDIT_PATH` for E2E isolation).
/// Reuses the shared `RotatingJSONLWriter` — the SAME proven rotation +
/// retention mechanics as `AuditLog` / `JSONLEventSink` (plan B3: reuse the
/// rotating-writer pattern; do NOT duplicate it).
public actor PushAuditLog {

    /// One audit record (one push outcome).
    public struct Entry: Sendable, Codable, Equatable {
        public let ts: Date
        public let kind: String
        public let subject: String
        public let severity: String
        public let cleared: Bool
        /// `sent` / `failed` / `coalesced` / `dropped` / `denied`.
        public let outcome: String
        /// `exec` / `outbox` for `sent`/`failed`; nil otherwise.
        public let backend: String?
        /// The drop/deny reason token; nil for sent/failed/coalesced.
        public let reason: String?
        public let summary: String

        public init(
            ts: Date, kind: String, subject: String, severity: String,
            cleared: Bool, outcome: String, backend: String?, reason: String?,
            summary: String
        ) {
            self.ts = ts
            self.kind = kind
            self.subject = subject
            self.severity = severity
            self.cleared = cleared
            self.outcome = outcome
            self.backend = backend
            self.reason = reason
            self.summary = summary
        }

        public enum CodingKeys: String, CodingKey {
            case ts, kind, subject, severity, cleared, outcome, backend, reason, summary
        }
    }

    private let writer: RotatingJSONLWriter
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var recentEntries: [Entry]
    private let recentCap: Int
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "push-audit")

    public init(baseDir: URL? = nil, retentionDays: Int = 30, recentCap: Int = 200) throws {
        let resolved = baseDir ?? PushAuditLog.defaultDirectory()
        self.writer = try RotatingJSONLWriter(baseDir: resolved, prefix: "push-audit", retentionDays: retentionDays)
        self.recentCap = recentCap
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
        self.recentEntries = []
    }

    /// Default audit directory: `~/Library/Application Support/uZora/`.
    /// Override with `UZORA_PUSH_AUDIT_PATH` (a directory).
    public static func defaultDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["UZORA_PUSH_AUDIT_PATH"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport.appendingPathComponent("uZora", isDirectory: true)
    }

    /// Audit one push outcome for `event`.
    public func record(event: PushEvent, outcome: PushOutcome, at ts: Date? = nil) async {
        let entry = Entry(
            ts: ts ?? event.ts,
            kind: event.kind.rawValue,
            subject: event.subject,
            severity: event.severity.rawValue,
            cleared: event.cleared,
            outcome: outcome.label,
            backend: outcome.backend,
            reason: outcome.reason,
            summary: event.summary
        )
        do {
            let data = try encoder.encode(entry)
            await writer.append(data, at: entry.ts)
        } catch {
            log.error("push-audit encode failed: \(String(describing: error), privacy: .public)")
        }
        recentEntries.append(entry)
        if recentEntries.count > recentCap {
            recentEntries.removeFirst(recentEntries.count - recentCap)
        }
    }

    /// The most recent N entries (newest last), from the in-memory tail.
    public func recent(_ limit: Int = 50) -> [Entry] {
        let n = max(0, min(limit, recentEntries.count))
        if n == 0 { return [] }
        return Array(recentEntries.suffix(n))
    }

    /// Total in-memory tail count (test affordance).
    public var recordedCount: Int { recentEntries.count }

    public func flush() async throws { try await writer.flush() }
    public func close() async { await writer.close() }
    public func startRotationLoop() async { await writer.startRotationLoop() }

    /// Today's audit file URL (test affordance).
    public func todayFileURL(at ts: Date = Date()) async -> URL {
        await writer.fileURL(forDay: RotatingJSONLWriter.dayKey(for: ts))
    }
}
