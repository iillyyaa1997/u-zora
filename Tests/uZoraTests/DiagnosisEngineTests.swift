import Foundation
import Testing
@testable import uZora

@Suite("DiagnosisEngine + Detector running")
struct DiagnosisEngineTests {

    // MARK: - Fixture detectors

    /// Always emits a finding (id `always:x`).
    private struct AlwaysFires: Detector {
        let id = "always"
        func evaluate(_ context: DiagnosisContext) -> Finding? {
            Finding(
                detector: id, subject: "x", severity: .warn, confidence: .medium,
                title: "always", explanation: "always fires",
                firstSeen: context.now, lastUpdated: context.now
            )
        }
    }

    /// Never emits a finding.
    private struct NeverFires: Detector {
        let id = "never"
        func evaluate(_ context: DiagnosisContext) -> Finding? { nil }
    }

    /// Fires only when latest `cores_pinned` >= 2. Reads via the context's
    /// pure `latest` accessor — exercising the engine→context→detector path.
    private struct ReadsLatest: Detector {
        let id = "reads_latest"
        let lookback: Duration = .seconds(600)
        func evaluate(_ context: DiagnosisContext) -> Finding? {
            let pinned = context.latest(
                probe: "system_signals", name: "cores_pinned"
            )?.value ?? 0
            guard pinned >= 2 else { return nil }
            return Finding(
                detector: id, subject: "cpu", severity: .critical, confidence: .high,
                title: "cores pinned", explanation: "cores pinned >= 2",
                evidence: ["cores_pinned": String(pinned)],
                firstSeen: context.now, lastUpdated: context.now
            )
        }
    }

    private func sample(_ name: String, _ value: Double, at: Date, key: String = "system") -> MetricsStore.Sample {
        MetricsStore.Sample(probe: "system_signals", key: key, name: name, value: value, at: at)
    }

    // MARK: - Pure evaluate(context:) path

    @Test func evaluate_collectsOnlyFiringFindings_sortedById() async {
        let engine = DiagnosisEngine(
            detectors: [AlwaysFires(), NeverFires(), ReadsLatest()],
            store: nil
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // cores_pinned = 3 → ReadsLatest fires.
        let ctx = DiagnosisContext(now: now, samples: [
            sample("cores_pinned", 3, at: now.addingTimeInterval(-10))
        ])
        let findings = engine.evaluate(context: ctx)
        // Only AlwaysFires + ReadsLatest fire; NeverFires abstains.
        #expect(findings.map(\.id) == ["always:x", "reads_latest:cpu"])
    }

    @Test func evaluate_isEmptyWhenNoDetectorFires() async {
        let engine = DiagnosisEngine(detectors: [NeverFires(), ReadsLatest()], store: nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // cores_pinned = 1 → ReadsLatest abstains; NeverFires never fires.
        let ctx = DiagnosisContext(now: now, samples: [
            sample("cores_pinned", 1, at: now.addingTimeInterval(-10))
        ])
        let findings = engine.evaluate(context: ctx)
        #expect(findings.isEmpty)
    }

    @Test func evaluate_emptyDetectors_isEmpty() async {
        let engine = DiagnosisEngine(detectors: [], store: nil)
        let ctx = DiagnosisContext(now: Date(), samples: [])
        #expect(engine.evaluate(context: ctx).isEmpty)
    }

    // MARK: - diagnose() over an in-memory MetricsStore

    @Test func diagnose_overSeededStore_returnsExpectedFinding() async throws {
        let store = try MetricsStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Seed a few system_signals rows inside the lookback window; the
        // freshest cores_pinned is 4 → ReadsLatest must fire.
        try await store.recordSamples([
            sample("cores_pinned", 1, at: now.addingTimeInterval(-300)),
            sample("cores_pinned", 2, at: now.addingTimeInterval(-200)),
            sample("cores_pinned", 4, at: now.addingTimeInterval(-100)),
            sample("gpu_util_pct", 80, at: now.addingTimeInterval(-100)),
        ])

        let engine = DiagnosisEngine(
            detectors: [ReadsLatest(), NeverFires()],
            store: store,
            probes: ["system_signals"],
            clock: { now }
        )
        let findings = await engine.diagnose()
        #expect(findings.count == 1)
        let f = try #require(findings.first)
        #expect(f.id == "reads_latest:cpu")
        #expect(f.severity == .critical)
        #expect(f.confidence == .high)
        #expect(f.evidence?["cores_pinned"] == "4.0")
        await store.close()
    }

    @Test func diagnose_pureEvaluateMatchesDiagnose() async throws {
        // The loaded-history diagnose() and the hand-built evaluate(context:)
        // should agree on the same data.
        let store = try MetricsStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.recordSamples([
            sample("cores_pinned", 5, at: now.addingTimeInterval(-50)),
        ])
        let detectors: [Detector] = [AlwaysFires(), ReadsLatest()]
        let engine = DiagnosisEngine(detectors: detectors, store: store, clock: { now })

        let viaDiagnose = await engine.diagnose()
        let ctx = DiagnosisContext(now: now, samples: [
            sample("cores_pinned", 5, at: now.addingTimeInterval(-50)),
        ])
        let viaEvaluate = engine.evaluate(context: ctx)
        #expect(viaDiagnose.map(\.id) == viaEvaluate.map(\.id))
        #expect(viaDiagnose.map(\.id) == ["always:x", "reads_latest:cpu"])
        await store.close()
    }

    @Test func diagnose_outOfWindowSamplesExcluded() async throws {
        // A cores_pinned=9 sample OUTSIDE the lookback window must not reach
        // the detector (engine queries [now-lookback, now]).
        let store = try MetricsStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // ReadsLatest lookback = 600s; this sample is 1200s old → excluded.
        try await store.recordSamples([
            sample("cores_pinned", 9, at: now.addingTimeInterval(-1200)),
        ])
        let engine = DiagnosisEngine(detectors: [ReadsLatest()], store: store, clock: { now })
        let findings = await engine.diagnose()
        #expect(findings.isEmpty, "samples older than max lookback must be excluded")
        await store.close()
    }

    @Test func diagnose_nilStore_runsWithEmptyContext() async {
        // No store → empty samples; ReadsLatest abstains, AlwaysFires fires.
        let engine = DiagnosisEngine(detectors: [AlwaysFires(), ReadsLatest()], store: nil)
        let findings = await engine.diagnose()
        #expect(findings.map(\.id) == ["always:x"])
    }
}
