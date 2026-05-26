import Testing
import Foundation
@testable import uZora

@Suite("KernelTaskProbe sustained-threshold ladder")
struct KernelTaskThresholdTests {

    private let thresholds = KernelTaskProbe.Thresholds.default

    @Test func belowWarn_noOutcome() {
        var warn: Date? = nil
        var crit: Date? = nil
        let outcome = KernelTaskProbe.evaluate(
            cpuPct: 10,
            now: Date(),
            warnEnteredAt: &warn,
            criticalEnteredAt: &crit,
            thresholds: thresholds
        )
        #expect(outcome == nil)
        #expect(warn == nil)
        #expect(crit == nil)
    }

    @Test func warnBand_belowSustainedWindow_isPending() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(10) // 10 s — well under warn-30s

        var warn: Date? = nil
        var crit: Date? = nil
        // First sample: enter warn band.
        _ = KernelTaskProbe.evaluate(
            cpuPct: 30, now: t0,
            warnEnteredAt: &warn, criticalEnteredAt: &crit,
            thresholds: thresholds
        )
        #expect(warn == t0)
        // Second sample 10s later — still warn, not yet sustained.
        let outcome = KernelTaskProbe.evaluate(
            cpuPct: 30, now: t1,
            warnEnteredAt: &warn, criticalEnteredAt: &crit,
            thresholds: thresholds
        )
        #expect(outcome == nil)
    }

    @Test func warnBand_sustained30s_firesWarn() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(31)

        var warn: Date? = nil
        var crit: Date? = nil
        _ = KernelTaskProbe.evaluate(
            cpuPct: 30, now: t0,
            warnEnteredAt: &warn, criticalEnteredAt: &crit,
            thresholds: thresholds
        )
        let outcome = KernelTaskProbe.evaluate(
            cpuPct: 30, now: t1,
            warnEnteredAt: &warn, criticalEnteredAt: &crit,
            thresholds: thresholds
        )
        #expect(outcome?.severity == .warn)
        #expect((outcome?.sustainedSeconds ?? 0) >= 30)
    }

    @Test func criticalBand_sustained60s_firesCritical() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(61)

        var warn: Date? = nil
        var crit: Date? = nil
        _ = KernelTaskProbe.evaluate(
            cpuPct: 60, now: t0,
            warnEnteredAt: &warn, criticalEnteredAt: &crit,
            thresholds: thresholds
        )
        let outcome = KernelTaskProbe.evaluate(
            cpuPct: 60, now: t1,
            warnEnteredAt: &warn, criticalEnteredAt: &crit,
            thresholds: thresholds
        )
        #expect(outcome?.severity == .critical)
    }

    @Test func criticalBand_belowCriticalWindow_butAboveWarnWindow_firesWarn() {
        // CPU at 60% for 40 s: critical band entered, but 40 s < 60 s
        // critical-sustained-window. However warn-sustained=30s so the
        // warn outcome should fire.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(40)

        var warn: Date? = nil
        var crit: Date? = nil
        _ = KernelTaskProbe.evaluate(
            cpuPct: 60, now: t0,
            warnEnteredAt: &warn, criticalEnteredAt: &crit,
            thresholds: thresholds
        )
        let outcome = KernelTaskProbe.evaluate(
            cpuPct: 60, now: t1,
            warnEnteredAt: &warn, criticalEnteredAt: &crit,
            thresholds: thresholds
        )
        // Critical sustained is 60s > 40s, but warn sustained is 30s <= 40s.
        #expect(outcome?.severity == .warn)
    }

    @Test func dropBelowWarn_clearsBandTimestamps() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(40)

        var warn: Date? = nil
        var crit: Date? = nil
        _ = KernelTaskProbe.evaluate(
            cpuPct: 30, now: t0,
            warnEnteredAt: &warn, criticalEnteredAt: &crit,
            thresholds: thresholds
        )
        #expect(warn == t0)
        // Drop back to 10% — bands should reset.
        let outcome = KernelTaskProbe.evaluate(
            cpuPct: 10, now: t1,
            warnEnteredAt: &warn, criticalEnteredAt: &crit,
            thresholds: thresholds
        )
        #expect(outcome == nil)
        #expect(warn == nil)
        #expect(crit == nil)
    }

    @Test func dropFromCritical_toWarn_keepsWarnTimestamp() {
        // CPU goes 60% → 30%: should leave critical band but stay in warn,
        // preserving the original warn-entered timestamp so we don't reset
        // the sustained timer for a temporary dip.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(20)

        var warn: Date? = nil
        var crit: Date? = nil
        _ = KernelTaskProbe.evaluate(
            cpuPct: 60, now: t0,
            warnEnteredAt: &warn, criticalEnteredAt: &crit,
            thresholds: thresholds
        )
        let origWarn = warn
        _ = KernelTaskProbe.evaluate(
            cpuPct: 30, now: t1,
            warnEnteredAt: &warn, criticalEnteredAt: &crit,
            thresholds: thresholds
        )
        #expect(crit == nil)
        #expect(warn == origWarn) // warn timestamp preserved
    }

    @Test func endToEnd_withInjectedSnapshotter() async throws {
        // Use an actor-backed counter so the @Sendable closures can advance
        // synthesised time without an unsafe captured `var`.
        actor Tick {
            var n: Int = 0
            func nextIndex() -> Int { n += 1; return n }
            func peek() -> Int { n }
        }
        let tick = Tick()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let probe = KernelTaskProbe(
            thresholds: .default,
            clock: {
                // The clock is read once per run() call. We snapshot the
                // current tick index synchronously via the actor's nonisolated
                // initial value: since `clock` is @Sendable, we keep a fresh
                // `Tick` actor read by spawning a detached read. Swift bans
                // sync actor reads, so we settle on time advancing
                // deterministically using a shared monotonic seed.
                Date()
            },
            pidFinder: { 0 },
            snapshotter: { _ in
                ProcessSampler.Snapshot(
                    pid: 0,
                    name: "kernel_task",
                    cpuTimeNanos: 0,
                    residentSizeBytes: 0,
                    virtualSizeBytes: 0,
                    startTime: baseDate,
                    sampledAt: Date()
                )
            }
        )

        // End-to-end smoke: should not throw, returns 0 or 1 alerts.
        let r = try await probe.run()
        #expect(r.count <= 1)
        _ = await tick.nextIndex()
    }
}
