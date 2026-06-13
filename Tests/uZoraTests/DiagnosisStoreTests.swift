import Testing
import Foundation
@testable import uZora

@Suite("DiagnosisStore in-memory diagnosis snapshot logic")
struct DiagnosisStoreTests {

    /// Build a Finding with a controllable (detector, subject) → id and
    /// severity. Mirrors the `alert(...)` helper in StateStoreTests.
    private func finding(
        detector: String,
        subject: String,
        severity: Severity = .warn,
        confidence: Confidence = .high,
        title: String = "t"
    ) -> Finding {
        Finding(
            detector: detector,
            subject: subject,
            severity: severity,
            confidence: confidence,
            title: title,
            explanation: "e",
            evidence: nil,
            suggestedAction: nil,
            firstSeen: Date(),
            lastUpdated: Date()
        )
    }

    @Test func defaults_toEmptyGoodVerdict() async {
        let store = DiagnosisStore()
        let f = await store.findings()
        #expect(f.isEmpty)
        let v = await store.verdict()
        #expect(v.level == .good)
        #expect(v.headline == Verdict.healthyHeadline)
        #expect(v.findings.isEmpty)
    }

    @Test func update_replacesSnapshot() async {
        let store = DiagnosisStore()
        let f1 = finding(detector: "runaway_daemon", subject: "ecosystemd", severity: .critical)
        let v1 = Verdict.derive(from: [f1])
        await store.update(findings: [f1], verdict: v1)
        #expect(await store.findings().count == 1)
        #expect(await store.verdict().level == .problem)

        // A second update fully REPLACES the snapshot (not appends).
        let f2 = finding(detector: "disk", subject: "/", severity: .warn, confidence: .low)
        let v2 = Verdict.derive(from: [f2])
        await store.update(findings: [f2], verdict: v2)
        let after = await store.findings()
        #expect(after.count == 1)
        #expect(after.first?.id == "disk:/")
        #expect(await store.verdict().level == .watch)
    }

    @Test func findings_areSortedByID() async {
        let store = DiagnosisStore()
        // Insert out of id order; expect ascending id back.
        let a = finding(detector: "zeta", subject: "z")          // id "zeta:z"
        let b = finding(detector: "alpha", subject: "a")         // id "alpha:a"
        let c = finding(detector: "mid", subject: "m")           // id "mid:m"
        await store.update(findings: [a, b, c], verdict: Verdict.derive(from: [a, b, c]))
        let ids = await store.findings().map(\.id)
        #expect(ids == ["alpha:a", "mid:m", "zeta:z"])
    }

    @Test func findings_minSeverityFilter() async {
        let store = DiagnosisStore()
        let info = finding(detector: "x", subject: "1", severity: .info)
        let warn = finding(detector: "x", subject: "2", severity: .warn)
        let crit = finding(detector: "x", subject: "3", severity: .critical)
        await store.update(
            findings: [info, warn, crit],
            verdict: Verdict.derive(from: [info, warn, crit])
        )
        let warnOrAbove = await store.findings(minSeverity: .warn)
        #expect(warnOrAbove.count == 2)
        let critOnly = await store.findings(minSeverity: .critical)
        #expect(critOnly.count == 1)
        #expect(critOnly.first?.subject == "3")
    }

    @Test func verdict_returnsLastSet() async {
        let store = DiagnosisStore()
        let f = finding(detector: "runaway_daemon", subject: "d", severity: .warn, confidence: .high)
        let v = Verdict.derive(from: [f])
        await store.update(findings: [f], verdict: v)
        let got = await store.verdict()
        #expect(got.level == .degraded)        // warn + high → degraded
        #expect(got.headline == "t")
        #expect(got.findings.count == 1)
    }
}
