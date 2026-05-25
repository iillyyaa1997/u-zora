import Testing
import Foundation
@testable import uZora

@Suite("DiskFreeProbe threshold logic")
struct DiskFreeProbeTests {

    private func sample(free: UInt64, total: UInt64) -> DiskFreeProbe.Sample {
        DiskFreeProbe.Sample(freeBytes: free, totalBytes: total, mount: "/")
    }

    @Test func plentyOfSpace_50pct_noAlert() {
        let s = sample(free: 500_000_000_000, total: 1_000_000_000_000) // 50%
        #expect(DiskFreeProbe.severity(for: s, thresholds: .default) == nil)
    }

    @Test func almostFull_14pct_warn() {
        let s = sample(free: 140_000_000_000, total: 1_000_000_000_000) // 14%
        #expect(DiskFreeProbe.severity(for: s, thresholds: .default) == .warn)
    }

    @Test func criticallyFull_4pct_critical() {
        let s = sample(free: 40_000_000_000, total: 1_000_000_000_000) // 4%
        #expect(DiskFreeProbe.severity(for: s, thresholds: .default) == .critical)
    }

    @Test func exactlyAtWarnThreshold_15pct_noAlert() {
        // 15.0% is the *boundary*: severity uses strict `<`, so 15% → no alert.
        let s = sample(free: 150_000_000_000, total: 1_000_000_000_000)
        #expect(DiskFreeProbe.severity(for: s, thresholds: .default) == nil)
    }

    @Test func exactlyAtCriticalThreshold_5pct_warn() {
        // 5.0% is the boundary; strict `<`, so it's warn-but-not-critical.
        let s = sample(free: 50_000_000_000, total: 1_000_000_000_000)
        #expect(DiskFreeProbe.severity(for: s, thresholds: .default) == .warn)
    }

    @Test func zeroTotalBytes_treatedAsFull_noAlert() {
        // A pathological 0-total mount should not crash — `freeFraction`
        // is defined as 1.0 in that case (treat as "all free").
        let s = sample(free: 0, total: 0)
        #expect(s.freeFraction == 1.0)
        #expect(DiskFreeProbe.severity(for: s, thresholds: .default) == nil)
    }

    @Test func customThresholds() {
        let strict = DiskFreeProbe.Thresholds(warnFreeFraction: 0.30, criticalFreeFraction: 0.20)
        let s = sample(free: 250_000_000_000, total: 1_000_000_000_000) // 25%
        #expect(DiskFreeProbe.severity(for: s, thresholds: strict) == .warn)
    }

    @Test func endToEndWithInjectedSampler() async throws {
        // Drive the probe with a deterministic sampler so we know the alert
        // shape stays consistent. We pick 4% free to trigger `.critical`.
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let probe = DiskFreeProbe(
            thresholds: .default,
            sampler: { DiskFreeProbe.Sample(freeBytes: 40, totalBytes: 1000, mount: "/") },
            clock: { fixedDate }
        )
        let alerts = try await probe.run()
        #expect(alerts.count == 1)
        let alert = try #require(alerts.first)
        #expect(alert.probe == "disk")
        #expect(alert.key == "/")
        #expect(alert.severity == .critical)
        #expect(alert.firstSeen == fixedDate)
        #expect(alert.lastUpdated == fixedDate)
        #expect(alert.details?["mount"] == "/")
        #expect(alert.details?["free_bytes"] == "40")
        #expect(alert.details?["total_bytes"] == "1000")
    }

    @Test func samplerReturnsNil_yieldsEmptyAlerts() async throws {
        let probe = DiskFreeProbe(
            thresholds: .default,
            sampler: { nil },
            clock: { Date() }
        )
        let alerts = try await probe.run()
        #expect(alerts.isEmpty)
    }
}
