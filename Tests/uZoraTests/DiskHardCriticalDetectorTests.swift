import Foundation
import Testing
@testable import uZora

@Suite("DiskHardCriticalDetector — R1 immediate hard critical")
struct DiskHardCriticalDetectorTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func diskContext(
        freePct: Double,
        freeBytes: Double? = nil,
        totalBytes: Double? = nil
    ) -> DiagnosisContext {
        var samples: [MetricsStore.Sample] = [
            MetricsStore.Sample(probe: "disk", key: "/", name: "free_pct",
                                value: freePct, at: now.addingTimeInterval(-10)),
        ]
        if let freeBytes {
            samples.append(MetricsStore.Sample(probe: "disk", key: "/", name: "free_bytes",
                                               value: freeBytes, at: now.addingTimeInterval(-10)))
        }
        if let totalBytes {
            samples.append(MetricsStore.Sample(probe: "disk", key: "/", name: "total_bytes",
                                               value: totalBytes, at: now.addingTimeInterval(-10)))
        }
        return DiagnosisContext(now: now, samples: samples)
    }

    @Test func fires_criticalHighAtOrBelow10PercentFree() {
        let det = DiskHardCriticalDetector()
        let f = det.evaluate(diskContext(freePct: 5, freeBytes: 5_000_000, totalBytes: 100_000_000))
        let finding = try? #require(f)
        #expect(finding?.detector == "disk_hard_critical")
        #expect(finding?.subject == "/")
        #expect(finding?.severity == .critical)
        #expect(finding?.confidence == .high)
        #expect(finding?.title == "Disk almost full")
        #expect(finding?.suggestedAction == "Free up disk space")
        #expect(finding?.evidence?["free_pct"] == "5.0")
        #expect(finding?.evidence?["free_bytes"] == "5000000")
        #expect(finding?.evidence?["total_bytes"] == "100000000")
        // 100 - 5 = 95% full.
        #expect(finding?.explanation.contains("95% full") == true)
    }

    @Test func nil_aboveThreshold() {
        let det = DiskHardCriticalDetector()
        #expect(det.evaluate(diskContext(freePct: 11)) == nil)
        #expect(det.evaluate(diskContext(freePct: 50)) == nil)
        #expect(det.evaluate(diskContext(freePct: 100)) == nil)
    }

    @Test func boundary_exactlyTenPercentFires() {
        // free_pct == 10 ⇔ 90% used ⇔ criticalUsedFraction 0.90 → free_pct ≤ 10
        // fires (inclusive boundary).
        let det = DiskHardCriticalDetector()
        let f = det.evaluate(diskContext(freePct: 10))
        #expect(f?.severity == .critical)
        // Just above the boundary does not.
        #expect(det.evaluate(diskContext(freePct: 10.01)) == nil)
    }

    @Test func nil_whenNoDiskSample() {
        let det = DiskHardCriticalDetector()
        let ctx = DiagnosisContext(now: now, samples: [])
        #expect(det.evaluate(ctx) == nil)
    }

    @Test func usesLatestSampleWhenMultiplePresent() {
        // An older critical sample + a newer healthy one → no finding (latest wins).
        let det = DiskHardCriticalDetector()
        let ctx = DiagnosisContext(now: now, samples: [
            MetricsStore.Sample(probe: "disk", key: "/", name: "free_pct",
                                value: 3, at: now.addingTimeInterval(-120)),
            MetricsStore.Sample(probe: "disk", key: "/", name: "free_pct",
                                value: 40, at: now.addingTimeInterval(-5)),
        ])
        #expect(det.evaluate(ctx) == nil)
    }

    @Test func customThreshold() {
        // criticalUsedFraction 0.95 → fire only when free_pct ≤ 5.
        let det = DiskHardCriticalDetector(criticalUsedFraction: 0.95)
        #expect(det.criticalFreePercent == 5)
        #expect(det.evaluate(diskContext(freePct: 6)) == nil)
        #expect(det.evaluate(diskContext(freePct: 5))?.severity == .critical)
    }
}
