import Testing
import Foundation
@testable import uZora

/// Coverage:
/// - In-memory db open + schema migration idempotency
/// - Single + batched insert
/// - Query with probe / name / time-range filters
/// - Retention purge
/// - Closed-store error
/// - Live durability against a temp-file backed store
@Suite("MetricsStore SQLite persistence")
struct MetricsStoreTests {

    // MARK: - Schema + open

    @Test func opensInMemory_andMigrationIsIdempotent() async throws {
        let store = try MetricsStore(inMemory: true)
        let count = try await store.rowCount()
        #expect(count == 0)

        // Closing + reopening on the same in-memory handle isn't
        // meaningful (a fresh `:memory:` is a fresh DB) — but we can
        // open two stores and confirm both succeed without conflicting
        // on schema creation.
        let second = try MetricsStore(inMemory: true)
        #expect(try await second.rowCount() == 0)

        await store.close()
        await second.close()
    }

    @Test func opensOnTempFile_andPersistsAcrossReopen() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-metrics-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("metrics.sqlite")

        let store = try MetricsStore(path: dbURL)
        try await store.recordSample(probe: "disk", key: "/", name: "free_pct", value: 75.0)
        let initial = try await store.rowCount()
        #expect(initial == 1)
        await store.close()

        // Reopen and confirm the row survives.
        let store2 = try MetricsStore(path: dbURL)
        let after = try await store2.rowCount()
        #expect(after == 1)
        await store2.close()
    }

    // MARK: - Insert

    @Test func recordSample_singleRow_isQueryable() async throws {
        let store = try MetricsStore(inMemory: true)
        defer { Task { await store.close() } }

        let now = Date()
        try await store.recordSample(
            probe: "cpu_temp", key: "package", name: "temp_c",
            value: 65.5, at: now
        )

        let samples = try await store.query(
            probe: "cpu_temp",
            from: now.addingTimeInterval(-1),
            to: now.addingTimeInterval(1)
        )
        #expect(samples.count == 1)
        #expect(samples.first?.value == 65.5)
        #expect(samples.first?.probe == "cpu_temp")
        #expect(samples.first?.key == "package")
        #expect(samples.first?.name == "temp_c")
    }

    @Test func recordSamples_batchTransaction() async throws {
        let store = try MetricsStore(inMemory: true)
        defer { Task { await store.close() } }

        let now = Date()
        let rows: [MetricsStore.Sample] = (0..<20).map { i in
            MetricsStore.Sample(
                probe: "disk", key: "/",
                name: "free_pct", value: Double(50 + i),
                at: now.addingTimeInterval(Double(i))
            )
        }
        try await store.recordSamples(rows)
        let count = try await store.rowCount()
        #expect(count == 20)
    }

    @Test func recordSamples_emptyBatchIsNoOp() async throws {
        let store = try MetricsStore(inMemory: true)
        defer { Task { await store.close() } }
        try await store.recordSamples([])
        let count = try await store.rowCount()
        #expect(count == 0)
    }

    // MARK: - Query

    @Test func query_filtersByProbe() async throws {
        let store = try MetricsStore(inMemory: true)
        defer { Task { await store.close() } }

        let now = Date()
        try await store.recordSample(probe: "disk", key: "/", name: "free_pct", value: 70, at: now)
        try await store.recordSample(probe: "cpu_temp", key: "package", name: "temp_c", value: 50, at: now)

        let disk = try await store.query(probe: "disk", from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        #expect(disk.count == 1)
        #expect(disk.first?.probe == "disk")

        let cpu = try await store.query(probe: "cpu_temp", from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        #expect(cpu.count == 1)
        #expect(cpu.first?.probe == "cpu_temp")
    }

    @Test func query_filtersByTimeRange() async throws {
        let store = try MetricsStore(inMemory: true)
        defer { Task { await store.close() } }

        let base = Date()
        // Insert at t-5, t, t+5 minutes
        try await store.recordSample(probe: "x", key: "k", name: "v", value: 1, at: base.addingTimeInterval(-300))
        try await store.recordSample(probe: "x", key: "k", name: "v", value: 2, at: base)
        try await store.recordSample(probe: "x", key: "k", name: "v", value: 3, at: base.addingTimeInterval(300))

        // Tight window: only the middle row.
        let mid = try await store.query(
            probe: "x",
            from: base.addingTimeInterval(-60),
            to: base.addingTimeInterval(60)
        )
        #expect(mid.count == 1)
        #expect(mid.first?.value == 2)

        // Wide window: all three.
        let all = try await store.query(
            probe: "x",
            from: base.addingTimeInterval(-3600),
            to: base.addingTimeInterval(3600)
        )
        #expect(all.count == 3)
        // Ascending order.
        #expect(all.map { $0.value } == [1, 2, 3])
    }

    @Test func query_filtersByMetricName() async throws {
        let store = try MetricsStore(inMemory: true)
        defer { Task { await store.close() } }

        let now = Date()
        try await store.recordSample(probe: "battery", key: "internal", name: "charge_pct", value: 75, at: now)
        try await store.recordSample(probe: "battery", key: "internal", name: "cycles", value: 300, at: now)
        try await store.recordSample(probe: "battery", key: "internal", name: "wattage_in", value: 65, at: now)

        let charge = try await store.query(
            probe: "battery",
            from: now.addingTimeInterval(-1),
            to: now.addingTimeInterval(1),
            name: "charge_pct"
        )
        #expect(charge.count == 1)
        #expect(charge.first?.value == 75)
        #expect(charge.first?.name == "charge_pct")

        let cycles = try await store.query(
            probe: "battery",
            from: now.addingTimeInterval(-1),
            to: now.addingTimeInterval(1),
            name: "cycles"
        )
        #expect(cycles.count == 1)
        #expect(cycles.first?.value == 300)

        // No filter — all three.
        let all = try await store.query(
            probe: "battery",
            from: now.addingTimeInterval(-1),
            to: now.addingTimeInterval(1)
        )
        #expect(all.count == 3)
    }

    @Test func query_emptyResultWhenNothingMatches() async throws {
        let store = try MetricsStore(inMemory: true)
        defer { Task { await store.close() } }

        let samples = try await store.query(
            probe: "missing",
            from: Date.distantPast,
            to: Date.distantFuture
        )
        #expect(samples.isEmpty)
    }

    // MARK: - Retention

    @Test func purge_removesOldRows_andLeavesNewer() async throws {
        let store = try MetricsStore(inMemory: true)
        defer { Task { await store.close() } }

        let now = Date()
        // Seven samples spaced one day apart, oldest first.
        for d in 0..<7 {
            try await store.recordSample(
                probe: "x", key: "k", name: "v",
                value: Double(d),
                at: now.addingTimeInterval(Double(d) * -86_400) // negative = older
            )
        }
        let initial = try await store.rowCount()
        #expect(initial == 7)

        // Cutoff: 3 days ago. The row at d=3 is exactly *at* the cutoff
        // (not strictly older), so it survives along with d=0..2. Only
        // d=4..6 — three rows — are strictly older and get purged.
        let cutoff = now.addingTimeInterval(-3 * 86_400)
        let removed = try await store.purge(olderThan: cutoff)
        #expect(removed == 3)

        let after = try await store.rowCount()
        #expect(after == 4)
    }

    @Test func purge_keepsEverythingWhenCutoffIsAncient() async throws {
        let store = try MetricsStore(inMemory: true)
        defer { Task { await store.close() } }

        let now = Date()
        try await store.recordSample(probe: "x", key: "k", name: "v", value: 1, at: now)
        let removed = try await store.purge(olderThan: Date.distantPast)
        #expect(removed == 0)
        #expect(try await store.rowCount() == 1)
    }

    @Test func purge_removesAllWhenCutoffIsFuture() async throws {
        let store = try MetricsStore(inMemory: true)
        defer { Task { await store.close() } }

        let now = Date()
        for _ in 0..<5 {
            try await store.recordSample(probe: "x", key: "k", name: "v", value: 1, at: now)
        }
        let removed = try await store.purge(olderThan: Date.distantFuture)
        #expect(removed == 5)
        #expect(try await store.rowCount() == 0)
    }

    // MARK: - Close semantics

    @Test func closedStore_throwsErrors() async throws {
        let store = try MetricsStore(inMemory: true)
        await store.close()
        await #expect(throws: MetricsStore.Error.self) {
            try await store.recordSample(probe: "x", key: "k", name: "v", value: 1)
        }
        await #expect(throws: MetricsStore.Error.self) {
            _ = try await store.query(probe: "x", from: Date(), to: Date())
        }
    }

    @Test func closeIsIdempotent() async throws {
        let store = try MetricsStore(inMemory: true)
        await store.close()
        await store.close() // No crash.
    }

    // MARK: - Default path resolution

    @Test func defaultPath_respectsEnvOverride() {
        let original = ProcessInfo.processInfo.environment["UZORA_METRICS_PATH"]
        let path = "/tmp/uzora-metrics-override.sqlite"
        setenv("UZORA_METRICS_PATH", path, 1)
        defer {
            if let original {
                setenv("UZORA_METRICS_PATH", original, 1)
            } else {
                unsetenv("UZORA_METRICS_PATH")
            }
        }
        let resolved = MetricsStore.defaultPath()
        #expect(resolved.path == path)
    }

    @Test func defaultPath_appSupportFallback() {
        unsetenv("UZORA_METRICS_PATH")
        let resolved = MetricsStore.defaultPath()
        #expect(resolved.path.contains("uZora"))
        #expect(resolved.lastPathComponent == "metrics.sqlite")
    }

    // MARK: - End-to-end through the scheduler

    @Test func registryHarvest_persistsProbeMetrics() async throws {
        let store = try MetricsStore(inMemory: true)
        defer { Task { await store.close() } }

        let registry = ProbeRegistry()
        // A throwaway probe that always emits a single fixed metric.
        await registry.register(StaticMetricProbe())
        await registry.attachMetricsStore(store)
        await registry.start()
        // Allow the scheduler a few ticks to fire run() + harvest.
        try? await Task.sleep(for: .milliseconds(800))
        await registry.stop()

        let now = Date()
        let samples = try await store.query(
            probe: "static_test",
            from: now.addingTimeInterval(-10),
            to: now.addingTimeInterval(1)
        )
        #expect(samples.count >= 1)
        #expect(samples.first?.name == "fake_metric")
        #expect(samples.first?.value == 42.0)
    }
}

/// Tiny in-test probe — fires no alerts but always emits one metric.
private struct StaticMetricProbe: Probe {
    let name = "static_test"
    let pollInterval: Duration = .milliseconds(100)
    func run() async throws -> [Alert] { [] }
    func currentMetrics() async -> [String: Double] {
        ["fake_metric": 42.0]
    }
}
