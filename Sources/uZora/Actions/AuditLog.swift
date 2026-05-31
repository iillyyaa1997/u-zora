import Foundation
import os

/// Append-only, daily-rotated JSONL audit log for Q10 actions. **Always-on**
/// — there is no toggle to disable it (Q4: the audit log is a security
/// mechanism). Every action run — auto, confirmed, or dry-run — writes
/// exactly one line.
///
/// File: `~/Library/Application Support/uZora/actions-audit-YYYY-MM-DD.jsonl`
/// Override the directory with `UZORA_ACTIONS_AUDIT_PATH` (a directory) for
/// E2E isolation, mirroring the other env-overrides (`UZORA_EVENTS_DIR`,
/// `UZORA_METRICS_PATH`, `UZORA_CONFIG_PATH`, `UZORA_WATCHDOG_STATE_PATH`).
///
/// Rotation + retention reuse the shared `RotatingJSONLWriter` (same proven
/// mechanics as `JSONLEventSink`), so this type only owns the audit record
/// schema + an in-memory tail for the popover / MCP / REST "recent actions"
/// surfaces.
///
/// Schema (one line per run):
/// ```json
/// {"ts":"2026-06-01T12:00:00.000Z","action_id":"prune_apfs_snapshots",
///  "trigger":"auto","policy_decision":"allow","freed_bytes":1048576,
///  "before_free_bytes":...,"after_free_bytes":...,"skipped":false,"error":null}
/// ```
public actor AuditLog {

    /// One audit record. `Codable`/`Sendable` so it round-trips JSONL and
    /// powers the REST/MCP "recent" view.
    public struct Entry: Sendable, Codable, Equatable {
        public let ts: Date
        public let actionID: String
        public let trigger: ActionTrigger
        /// `"allow"`, `"dry_run"`, or `"deny:<reason>"` — the PolicyEngine
        /// verdict that gated this run (a confirmed run that bypassed the
        /// enabled gate still records `allow`).
        public let policyDecision: String
        public let freedBytes: UInt64
        public let beforeFreeBytes: UInt64
        public let afterFreeBytes: UInt64
        public let skipped: Bool
        public let error: String?

        public init(
            ts: Date,
            actionID: String,
            trigger: ActionTrigger,
            policyDecision: String,
            freedBytes: UInt64,
            beforeFreeBytes: UInt64,
            afterFreeBytes: UInt64,
            skipped: Bool,
            error: String?
        ) {
            self.ts = ts
            self.actionID = actionID
            self.trigger = trigger
            self.policyDecision = policyDecision
            self.freedBytes = freedBytes
            self.beforeFreeBytes = beforeFreeBytes
            self.afterFreeBytes = afterFreeBytes
            self.skipped = skipped
            self.error = error
        }

        public enum CodingKeys: String, CodingKey {
            case ts
            case actionID = "action_id"
            case trigger
            case policyDecision = "policy_decision"
            case freedBytes = "freed_bytes"
            case beforeFreeBytes = "before_free_bytes"
            case afterFreeBytes = "after_free_bytes"
            case skipped
            case error
        }
    }

    private let writer: RotatingJSONLWriter
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// In-memory tail of the most recent entries (for the popover / MCP /
    /// REST "recent actions"). Capped — the durable record is the JSONL file.
    private var recentEntries: [Entry]
    private let recentCap: Int
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "audit")

    public init(baseDir: URL? = nil, retentionDays: Int = 30, recentCap: Int = 200) throws {
        let resolved = baseDir ?? AuditLog.defaultDirectory()
        self.writer = try RotatingJSONLWriter(baseDir: resolved, prefix: "actions-audit", retentionDays: retentionDays)
        self.recentCap = recentCap
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
        // Hydrate the in-memory tail from today's file so a restart shows
        // recent actions immediately (best-effort). Done via a `static`
        // helper so the actor's `init` (synchronous, nonisolated) doesn't
        // call an isolated instance method.
        self.recentEntries = AuditLog.loadRecentFromDisk(
            baseDir: resolved, decoder: dec, recentCap: recentCap
        )
    }

    /// Default audit directory: `~/Library/Application Support/uZora/`.
    /// Override with `UZORA_ACTIONS_AUDIT_PATH` (a directory).
    public static func defaultDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["UZORA_ACTIONS_AUDIT_PATH"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport.appendingPathComponent("uZora", isDirectory: true)
    }

    /// Append one audit entry. Always writes — no enable gate.
    public func record(_ entry: Entry) async {
        do {
            let data = try encoder.encode(entry)
            await writer.append(data, at: entry.ts)
        } catch {
            log.error("audit encode failed: \(String(describing: error), privacy: .public)")
        }
        recentEntries.append(entry)
        if recentEntries.count > recentCap {
            recentEntries.removeFirst(recentEntries.count - recentCap)
        }
    }

    /// Convenience: build + record an entry from an `ActionResult` + the
    /// trigger + the PolicyEngine decision string.
    public func record(
        result: ActionResult,
        trigger: ActionTrigger,
        policyDecision: String,
        at ts: Date = Date()
    ) async {
        await record(Entry(
            ts: ts,
            actionID: result.actionID,
            trigger: trigger,
            policyDecision: policyDecision,
            freedBytes: result.freedBytes,
            beforeFreeBytes: result.beforeFreeBytes,
            afterFreeBytes: result.afterFreeBytes,
            skipped: result.skipped,
            error: result.error
        ))
    }

    /// Record a DENY — an action that was blocked by a gate before it could
    /// run. No bytes change; the decision string carries the reason.
    public func recordDenied(
        actionID: String,
        trigger: ActionTrigger,
        reason: String,
        at ts: Date = Date()
    ) async {
        await record(Entry(
            ts: ts,
            actionID: actionID,
            trigger: trigger,
            policyDecision: "deny:\(reason)",
            freedBytes: 0,
            beforeFreeBytes: 0,
            afterFreeBytes: 0,
            skipped: true,
            error: nil
        ))
    }

    /// The most recent N entries (newest last), from the in-memory tail.
    public func recent(_ limit: Int = 50) -> [Entry] {
        let n = max(0, min(limit, recentEntries.count))
        if n == 0 { return [] }
        return Array(recentEntries.suffix(n))
    }

    /// Total in-memory tail count (test affordance).
    public var recordedCount: Int { recentEntries.count }

    /// Flush the underlying writer (test affordance — call before asserting
    /// file contents).
    public func flush() async throws {
        try await writer.flush()
    }

    public func close() async {
        await writer.close()
    }

    public func startRotationLoop() async {
        await writer.startRotationLoop()
    }

    /// Today's audit file URL (test affordance / Settings "open folder").
    public func todayFileURL(at ts: Date = Date()) async -> URL {
        await writer.fileURL(forDay: RotatingJSONLWriter.dayKey(for: ts))
    }

    // MARK: - Internals

    /// Static (nonisolated) loader for the in-memory tail — callable from the
    /// actor's `init` without touching isolated instance state.
    private static func loadRecentFromDisk(baseDir: URL, decoder: JSONDecoder, recentCap: Int) -> [Entry] {
        let url = baseDir.appendingPathComponent(
            "actions-audit-\(RotatingJSONLWriter.dayKey(for: Date())).jsonl",
            isDirectory: false
        )
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var loaded: [Entry] = []
        for line in text.split(separator: "\n") where !line.isEmpty {
            if let data = line.data(using: .utf8),
               let entry = try? decoder.decode(Entry.self, from: data) {
                loaded.append(entry)
            }
        }
        if loaded.count > recentCap {
            loaded.removeFirst(loaded.count - recentCap)
        }
        return loaded
    }
}
