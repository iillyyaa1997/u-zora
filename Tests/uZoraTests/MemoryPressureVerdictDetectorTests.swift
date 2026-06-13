import Foundation
import Testing
@testable import uZora

@Suite("MemoryPressureVerdictDetector — verdict on the LEVEL signal")
struct MemoryPressureVerdictDetectorTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func context(level: Double?) -> DiagnosisContext {
        var samples: [MetricsStore.Sample] = []
        if let level {
            samples.append(MetricsStore.Sample(
                probe: "system_signals", key: "system", name: "mem_pressure_level",
                value: level, at: now.addingTimeInterval(-5)
            ))
        }
        return DiagnosisContext(now: now, samples: samples)
    }

    @Test func level0_normal_nil() {
        let det = MemoryPressureVerdictDetector()
        #expect(det.evaluate(context(level: 0)) == nil)
    }

    @Test func level1_warn() {
        let det = MemoryPressureVerdictDetector()
        let f = det.evaluate(context(level: 1))
        let finding = try? #require(f)
        #expect(finding?.detector == "memory_pressure")
        #expect(finding?.subject == "memory")
        #expect(finding?.severity == .warn)
        #expect(finding?.confidence == .high)
        #expect(finding?.title == "Memory pressure elevated")
        #expect(finding?.evidence?["mem_pressure_level"] == "1")
    }

    @Test func level2_critical() {
        let det = MemoryPressureVerdictDetector()
        let f = det.evaluate(context(level: 2))
        let finding = try? #require(f)
        #expect(finding?.severity == .critical)
        #expect(finding?.confidence == .high)
        #expect(finding?.title == "Memory pressure critical")
        #expect(finding?.evidence?["mem_pressure_level"] == "2")
    }

    @Test func absent_nil() {
        let det = MemoryPressureVerdictDetector()
        #expect(det.evaluate(context(level: nil)) == nil)
    }

    @Test func usesLatestLevel() {
        // Older critical + newer normal → latest (normal) wins → nil.
        let det = MemoryPressureVerdictDetector()
        let ctx = DiagnosisContext(now: now, samples: [
            MetricsStore.Sample(probe: "system_signals", key: "system",
                                name: "mem_pressure_level", value: 2, at: now.addingTimeInterval(-60)),
            MetricsStore.Sample(probe: "system_signals", key: "system",
                                name: "mem_pressure_level", value: 0, at: now.addingTimeInterval(-5)),
        ])
        #expect(det.evaluate(ctx) == nil)
    }
}
