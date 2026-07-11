import Foundation
import SQLite3
import os

/// Persistent metric-sample store backed by SQLite via the native
/// `sqlite3` C API (Darwin ships the library; no SPM dependency).
///
/// The store accumulates one row per (probe, key, name) per poll so the
/// `/metrics` REST endpoint + popover sparklines can render historical
/// graphs (last 7 days at full poll resolution; Phase 7+ downsamples).
///
/// Schema (single table):
/// ```sql
/// CREATE TABLE IF NOT EXISTS samples (
///     probe TEXT NOT NULL,
///     key TEXT NOT NULL,
///     name TEXT NOT NULL,
///     value REAL NOT NULL,
///     at REAL NOT NULL  -- Unix epoch seconds
/// );
/// CREATE INDEX IF NOT EXISTS idx_samples_probe_at ON samples(probe, at);
/// CREATE INDEX IF NOT EXISTS idx_samples_at ON samples(at);
/// ```
///
/// Threading: this is an `actor`. The underlying `sqlite3*` handle is NOT
/// touched from any thread other than the actor's own — every call to a
/// `sqlite3_*` C function happens on whichever cooperative thread the actor
/// is currently running on, but never concurrently. The default journal
/// mode is `WAL` and synchronous is `NORMAL` — both fine for a single-
/// writer single-reader workload at human-scale poll rates.
public actor MetricsStore {

    public enum Error: Swift.Error, CustomStringConvertible {
        case openFailed(String)
        case prepareFailed(String)
        case stepFailed(String)
        case bindFailed(String)
        case closed

        public var description: String {
            switch self {
            case .openFailed(let s):    return "MetricsStore.openFailed: \(s)"
            case .prepareFailed(let s): return "MetricsStore.prepareFailed: \(s)"
            case .stepFailed(let s):    return "MetricsStore.stepFailed: \(s)"
            case .bindFailed(let s):    return "MetricsStore.bindFailed: \(s)"
            case .closed:               return "MetricsStore is closed"
            }
        }
    }

    /// One sample. `probe` + `key` + `name` form the logical "series"
    /// identity; `at` is Unix epoch seconds (UTC).
    public struct Sample: Sendable, Codable, Equatable {
        public let probe: String
        public let key: String
        public let name: String
        public let value: Double
        public let at: Date
        public init(probe: String, key: String, name: String, value: Double, at: Date) {
            self.probe = probe
            self.key = key
            self.name = name
            self.value = value
            self.at = at
        }
    }

    /// Whether this store points at a real file or `:memory:` (tests).
    public let path: URL
    public let inMemory: Bool

    private var db: OpaquePointer?
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "metrics-store")

    /// Open a store at the given URL. If `path` is `nil`, defaults to
    /// `~/Library/Application Support/uZora/metrics.sqlite`. Pass
    /// `inMemory: true` to ignore `path` and open a `:memory:` database
    /// (used by tests; not durable).
    public init(path: URL? = nil, inMemory: Bool = false) throws {
        self.inMemory = inMemory
        let resolved = path ?? MetricsStore.defaultPath()
        self.path = resolved

        if !inMemory {
            try MetricsStore.ensureParentDirectory(of: resolved)
        }

        var handle: OpaquePointer?
        let cPath: String = inMemory ? ":memory:" : resolved.path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(cPath, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let h = handle { sqlite3_close(h) }
            throw Error.openFailed("sqlite3_open_v2(\(cPath)) failed: \(msg)")
        }
        self.db = opened

        // Tuning. WAL is fine for a single-process writer; synchronous
        // NORMAL is safe for non-financial workloads. busy_timeout
        // smooths transient WAL contention with the SSE/UI readers if
        // they ever land on a non-actor thread.
        //
        // We can't call actor-isolated helpers from the synchronous init,
        // so we operate on the raw handle directly here.
        try MetricsStore.execRaw(opened, "PRAGMA journal_mode = WAL;")
        try MetricsStore.execRaw(opened, "PRAGMA synchronous = NORMAL;")
        try MetricsStore.execRaw(opened, "PRAGMA busy_timeout = 2000;")
        try MetricsStore.execRaw(opened, "PRAGMA temp_store = MEMORY;")
        try MetricsStore.migrateSchemaRaw(opened)
    }

    // MARK: - Public API

    /// Insert a single sample.
    public func recordSample(
        probe: String,
        key: String,
        name: String,
        value: Double,
        at: Date = Date()
    ) async throws {
        try recordSamplesSync([Sample(
            probe: probe, key: key, name: name, value: value, at: at
        )])
    }

    /// Insert many samples in one transaction. Empty input is a no-op.
    public func recordSamples(_ rows: [Sample]) async throws {
        try recordSamplesSync(rows)
    }

    /// Query a probe's history. All filters optional except `probe`.
    /// Rows returned in ascending `at` order.
    public func query(
        probe: String,
        from: Date,
        to: Date,
        name: String? = nil
    ) async throws -> [Sample] {
        guard let db else { throw Error.closed }

        var sql = "SELECT probe, key, name, value, at FROM samples "
            + "WHERE probe = ? AND at >= ? AND at <= ?"
        if name != nil { sql += " AND name = ?" }
        sql += " ORDER BY at ASC"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw Error.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }

        // SQLite needs explicit transient-string semantics because Swift
        // strings can move; SQLITE_TRANSIENT tells sqlite to make a copy.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(s, 1, probe, -1, transient) == SQLITE_OK else {
            throw Error.bindFailed("probe")
        }
        guard sqlite3_bind_double(s, 2, from.timeIntervalSince1970) == SQLITE_OK else {
            throw Error.bindFailed("from")
        }
        guard sqlite3_bind_double(s, 3, to.timeIntervalSince1970) == SQLITE_OK else {
            throw Error.bindFailed("to")
        }
        if let name {
            guard sqlite3_bind_text(s, 4, name, -1, transient) == SQLITE_OK else {
                throw Error.bindFailed("name")
            }
        }

        var out: [Sample] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let probeStr = String(cString: sqlite3_column_text(s, 0))
            let keyStr   = String(cString: sqlite3_column_text(s, 1))
            let nameStr  = String(cString: sqlite3_column_text(s, 2))
            let value    = sqlite3_column_double(s, 3)
            let at       = sqlite3_column_double(s, 4)
            out.append(Sample(
                probe: probeStr,
                key: keyStr,
                name: nameStr,
                value: value,
                at: Date(timeIntervalSince1970: at)
            ))
        }
        return out
    }

    /// Drop every row strictly older than `cutoff`.
    @discardableResult
    public func purge(olderThan cutoff: Date) async throws -> Int {
        guard let db else { throw Error.closed }
        let sql = "DELETE FROM samples WHERE at < ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw Error.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        guard sqlite3_bind_double(s, 1, cutoff.timeIntervalSince1970) == SQLITE_OK else {
            throw Error.bindFailed("cutoff")
        }
        guard sqlite3_step(s) == SQLITE_DONE else {
            throw Error.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_changes(db))
    }

    /// Row count — test affordance, also used by Settings UI.
    public func rowCount() async throws -> Int {
        guard let db else { throw Error.closed }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM samples", -1, &stmt, nil) == SQLITE_OK,
              let s = stmt else {
            throw Error.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(s, 0))
    }

    /// One catalog entry: a distinct `(probe, name)` metric series actually
    /// present in the store, plus its sample `count`, last value, and last
    /// timestamp. Powers `list_metrics` / `GET /metrics/catalog` so an LLM can
    /// enumerate the real series instead of guessing name strings.
    public struct Series: Sendable, Codable, Equatable {
        public let probe: String
        public let name: String
        public let count: Int
        public let lastValue: Double
        public let lastAt: Date
        public init(probe: String, name: String, count: Int, lastValue: Double, lastAt: Date) {
            self.probe = probe
            self.name = name
            self.count = count
            self.lastValue = lastValue
            self.lastAt = lastAt
        }
    }

    /// Enumerate the distinct `(probe, name)` series in the store, each with its
    /// row count + most-recent value/timestamp. Sorted by `(probe, name)` for a
    /// stable catalog. An empty store yields `[]`.
    ///
    /// The inner aggregate computes the per-series count + MAX(at); the outer
    /// join pulls the value at that latest timestamp (a tie on `at` collapses to
    /// one arbitrary row via the outer `GROUP BY` — acceptable for a "last
    /// value" hint).
    public func distinctSeries() async throws -> [Series] {
        guard let db else { throw Error.closed }
        let sql = """
            SELECT s.probe, s.name, m.cnt, s.value, s.at
            FROM samples s
            JOIN (
                SELECT probe, name, COUNT(*) AS cnt, MAX(at) AS max_at
                FROM samples
                GROUP BY probe, name
            ) m ON s.probe = m.probe AND s.name = m.name AND s.at = m.max_at
            GROUP BY s.probe, s.name
            ORDER BY s.probe, s.name
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw Error.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }

        var out: [Series] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let probeStr = String(cString: sqlite3_column_text(s, 0))
            let nameStr  = String(cString: sqlite3_column_text(s, 1))
            let count    = Int(sqlite3_column_int64(s, 2))
            let value    = sqlite3_column_double(s, 3)
            let at       = sqlite3_column_double(s, 4)
            out.append(Series(
                probe: probeStr,
                name: nameStr,
                count: count,
                lastValue: value,
                lastAt: Date(timeIntervalSince1970: at)
            ))
        }
        return out
    }

    /// Close the underlying database. Idempotent.
    public func close() {
        if let db {
            sqlite3_close(db)
        }
        db = nil
    }

    // MARK: - Internals

    private func recordSamplesSync(_ rows: [Sample]) throws {
        guard let db else { throw Error.closed }
        if rows.isEmpty { return }

        try exec("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let sql = "INSERT INTO samples(probe, key, name, value, at) VALUES (?, ?, ?, ?, ?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
                throw Error.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(s) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            for row in rows {
                sqlite3_reset(s)
                sqlite3_clear_bindings(s)
                guard sqlite3_bind_text(s, 1, row.probe, -1, transient) == SQLITE_OK,
                      sqlite3_bind_text(s, 2, row.key, -1, transient) == SQLITE_OK,
                      sqlite3_bind_text(s, 3, row.name, -1, transient) == SQLITE_OK,
                      sqlite3_bind_double(s, 4, row.value) == SQLITE_OK,
                      sqlite3_bind_double(s, 5, row.at.timeIntervalSince1970) == SQLITE_OK else {
                    throw Error.bindFailed(String(cString: sqlite3_errmsg(db)))
                }
                guard sqlite3_step(s) == SQLITE_DONE else {
                    throw Error.stepFailed(String(cString: sqlite3_errmsg(db)))
                }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw Error.closed }
        try MetricsStore.execRaw(db, sql)
    }

    /// Run a no-result SQL statement against a raw `sqlite3*` handle.
    /// Used both from `init` (which can't call actor-isolated helpers)
    /// and from the regular actor-isolated `exec()` wrapper.
    private static func execRaw(_ db: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.flatMap { String(cString: $0) } ?? "rc=\(rc)"
            sqlite3_free(errMsg)
            throw Error.prepareFailed("exec(\(sql)) failed: \(msg)")
        }
    }

    /// Create/migrate the `samples` schema on a raw handle. Idempotent.
    private static func migrateSchemaRaw(_ db: OpaquePointer) throws {
        try execRaw(db, """
            CREATE TABLE IF NOT EXISTS samples (
                probe TEXT NOT NULL,
                key TEXT NOT NULL,
                name TEXT NOT NULL,
                value REAL NOT NULL,
                at REAL NOT NULL
            );
        """)
        try execRaw(db, "CREATE INDEX IF NOT EXISTS idx_samples_probe_at ON samples(probe, at);")
        try execRaw(db, "CREATE INDEX IF NOT EXISTS idx_samples_at ON samples(at);")
    }

    // MARK: - Filesystem helpers

    /// Default location: `~/Library/Application Support/uZora/metrics.sqlite`.
    /// Override via `UZORA_METRICS_PATH` env var (used for the
    /// `MetricsStoreTests` integration test).
    public static func defaultPath() -> URL {
        if let env = ProcessInfo.processInfo.environment["UZORA_METRICS_PATH"],
           !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport.appendingPathComponent("uZora", isDirectory: true)
            .appendingPathComponent("metrics.sqlite", isDirectory: false)
    }

    private static func ensureParentDirectory(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
}
