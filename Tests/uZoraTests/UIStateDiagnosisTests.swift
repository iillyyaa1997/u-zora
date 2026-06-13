import Testing
import Foundation
@testable import uZora

/// Phase 4 — `UIState.applyDiagnosis` mirrors a derived `Verdict` into the
/// observable fields the popover Verdict card + menu-bar glyph read.
@Suite("UIState.applyDiagnosis")
struct UIStateDiagnosisTests {

    private func finding(severity: Severity, confidence: Confidence, title: String) -> Finding {
        Finding(
            detector: "d",
            subject: "s",
            severity: severity,
            confidence: confidence,
            title: title,
            explanation: "why",
            evidence: nil,
            suggestedAction: nil,
            firstSeen: Date(timeIntervalSince1970: 1000),
            lastUpdated: Date(timeIntervalSince1970: 1100)
        )
    }

    @Test @MainActor func applyDiagnosis_setsLevelHeadlineFindings() {
        let state = UIState()
        // Defaults before any diagnosis.
        #expect(state.verdict == .good)
        #expect(state.verdictHeadline == Verdict.healthyHeadline)
        #expect(state.findings.isEmpty)

        let f = finding(severity: .critical, confidence: .high, title: "Disk full")
        state.applyDiagnosis(Verdict.derive(from: [f]))

        #expect(state.verdict == .problem)
        #expect(state.verdictHeadline == "Disk full")
        #expect(state.findings.count == 1)
        #expect(state.findings.first?.title == "Disk full")
        #expect(state.verdictTint == .red)
    }

    @Test @MainActor func applyDiagnosis_emptyResetsToGood() {
        let state = UIState()
        state.applyDiagnosis(Verdict.derive(from: [finding(severity: .warn, confidence: .high, title: "x")]))
        #expect(state.verdict == .degraded)
        // Clearing back to no findings.
        state.applyDiagnosis(Verdict.derive(from: []))
        #expect(state.verdict == .good)
        #expect(state.verdictHeadline == Verdict.healthyHeadline)
        #expect(state.findings.isEmpty)
        #expect(state.verdictTint == .green)
    }
}
