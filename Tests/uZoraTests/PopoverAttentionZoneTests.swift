import Testing
import Foundation
import SwiftUI
@testable import uZora

/// Phase A2 (IA redesign): the unified "Attention" zone (findings lead, then
/// de-duplicated raw alerts as "Other signals"), the Verdict card reduced to a
/// one-line summary, and the memory-pressure LEVEL tile (D5 + D6).
///
/// Model-layer assertions only (no view-snapshot harness): the de-dup + zone
/// visibility pure functions, the mem-pressure level→color mapping, the demo
/// cycling the level, and a compile-level check that the whole view graph
/// (incl. the slimmed `VerdictCard`) type-checks against both data sources.
@Suite("Popover attention zone (A2)")
@MainActor
struct PopoverAttentionZoneTests {

    // MARK: - Builders

    private func finding(subject: String) -> Finding {
        let now = Date()
        return Finding(
            detector: "d", subject: subject, severity: .warn, confidence: .high,
            title: "t", explanation: "e", evidence: nil, suggestedAction: nil,
            firstSeen: now, lastUpdated: now
        )
    }

    // Qualified: `import SwiftUI` also brings in a (deprecated) `SwiftUI.Alert`,
    // so the bare name is ambiguous — pin to the app model's `uZora.Alert`.
    private func alert(probe: String, key: String) -> uZora.Alert {
        let now = Date()
        return uZora.Alert(
            probe: probe, key: key, severity: .warn, message: "m",
            details: nil, firstSeen: now, lastUpdated: now
        )
    }

    // MARK: - De-dup: unexplainedAlerts

    @Test func unexplainedHidesAlertMatchedByProbe() {
        // finding.subject "disk" == alert.probe "disk" → explained → hidden.
        let a = alert(probe: "disk", key: "/vol1")
        let out = unexplainedAlerts([a], findings: [finding(subject: "disk")])
        #expect(out.isEmpty)
    }

    @Test func unexplainedHidesAlertMatchedByKey() {
        // finding.subject "/" == alert.key "/" → explained → hidden.
        let a = alert(probe: "disk", key: "/")
        let out = unexplainedAlerts([a], findings: [finding(subject: "/")])
        #expect(out.isEmpty)
    }

    @Test func unexplainedUnrelatedAlertSurvives() {
        // No finding subject matches "network"/"eth0" → shown.
        let a = alert(probe: "network", key: "eth0")
        let out = unexplainedAlerts([a], findings: [finding(subject: "disk")])
        #expect(out.map(\.id) == [a.id])
    }

    @Test func unexplainedAmbiguousMatchSurvives() {
        // "disk" ⊂ "diskstore" is a partial/fuzzy overlap, NOT exact equality.
        // Fail-safe: SHOW the alert (never hide on an uncertain match).
        let a = alert(probe: "diskstore", key: "vol1")
        let out = unexplainedAlerts([a], findings: [finding(subject: "disk")])
        #expect(out.map(\.id) == [a.id])
    }

    @Test func unexplainedEmptyFindingsShowAll() {
        let a1 = alert(probe: "disk", key: "/")
        let a2 = alert(probe: "cpu", key: "runaway")
        let out = unexplainedAlerts([a1, a2], findings: [])
        #expect(out.map(\.id) == [a1.id, a2.id])
    }

    @Test func unexplainedEmptySubjectNeverHides() {
        // An empty finding subject must not spuriously "explain" an alert with
        // empty identifiers (fail-safe against the empty-string match).
        let a = alert(probe: "", key: "")
        let out = unexplainedAlerts([a], findings: [finding(subject: "")])
        #expect(out.map(\.id) == [a.id])
    }

    @Test func unexplainedMixedKeepsOnlyTheUnexplained() {
        // Disk finding explains the disk alert; the cpu alert (subject is the
        // daemon name, not "cpu"/"runaway") survives as an "Other signal".
        let disk = alert(probe: "disk", key: "/")
        let cpu = alert(probe: "cpu", key: "runaway")
        let out = unexplainedAlerts(
            [disk, cpu],
            findings: [finding(subject: "disk"), finding(subject: "mdworker_shared")]
        )
        #expect(out.map(\.id) == [cpu.id])
    }

    // MARK: - Zone visibility (the double "All systems healthy" fix)

    @Test func attentionZoneHiddenWhenHealthy() {
        // No findings AND no alerts → the whole zone disappears (EmptyView),
        // so the Verdict card is the SINGLE all-clear.
        #expect(attentionZoneIsVisible(findings: [], alerts: []) == false)
    }

    @Test func attentionZoneVisibleWithFindingsOrAlerts() {
        #expect(attentionZoneIsVisible(findings: [finding(subject: "disk")], alerts: []) == true)
        #expect(attentionZoneIsVisible(findings: [], alerts: [alert(probe: "disk", key: "/")]) == true)
        #expect(attentionZoneIsVisible(
            findings: [finding(subject: "disk")],
            alerts: [alert(probe: "cpu", key: "runaway")]
        ) == true)
    }

    // MARK: - Mem-pressure LEVEL tile (D6)

    @Test func memPressureColorMapping() {
        // 0 normal → green, 1 warn → amber(orange), 2+ critical → red,
        // nil/garbage → gray. Locale-independent (Color equality).
        #expect(memPressureColor(0) == .green)
        #expect(memPressureColor(1) == .orange)
        #expect(memPressureColor(2) == .red)
        #expect(memPressureColor(3) == .red)     // any level >= 2 → red
        #expect(memPressureColor(nil) == .gray)
        #expect(memPressureColor(-1) == .gray)    // out-of-range → gray
    }

    @Test func memPressureLabelMapping() {
        // Distinct non-empty words per level; nil → em dash placeholder.
        #expect(!memPressureLabel(0).isEmpty)
        #expect(memPressureLabel(0) != memPressureLabel(1))
        #expect(memPressureLabel(1) != memPressureLabel(2))
        #expect(memPressureLabel(nil) == "—")
    }

    @Test func demoPopulatesAndCyclesMemPressureLevel() {
        let demo = DemoDataSource(autostart: false)
        // Populated on the very first (pre-timer) snapshot.
        #expect(demo.memPressureLevel != nil)

        // Walk a full verdict cycle, recording the level seen at each verdict.
        var levelByVerdict: [VerdictLevel: Int] = [:]
        for _ in 0..<8 {
            if let lvl = demo.memPressureLevel { levelByVerdict[demo.verdict] = lvl }
            demo.step()
        }
        // Documented demo mapping: good=0, watch=1, problem=2.
        #expect(levelByVerdict[.good] == 0)
        #expect(levelByVerdict[.watch] == 1)
        #expect(levelByVerdict[.problem] == 2)
        // …and those levels drive the three distinct tile colors.
        #expect(memPressureColor(levelByVerdict[.good]) == .green)
        #expect(memPressureColor(levelByVerdict[.watch]) == .orange)
        #expect(memPressureColor(levelByVerdict[.problem]) == .red)
    }

    // MARK: - Verdict card slimmed + whole view graph type-checks

    @Test func popoverViewBuildsFromBothSourcesAfterVerdictSlim() {
        // Compile-level: the A2 `VerdictCard` takes only (tint, headline) — it
        // no longer receives `findings` — and `AttentionBlock` now consumes
        // (findings, alerts). If either signature still required the old shape
        // this would not type-check. Constructing `PopoverView` over both
        // sources proves the full generic view graph builds. A3a: pass the
        // `.power` layout (every block + tile visible) so the whole view graph
        // — including the layout-driven SystemOverview tile switch — is built.
        let demo = DemoDataSource(autostart: false)
        _ = PopoverView(state: demo, layout: .power)
        _ = PopoverView(state: UIState(), layout: .power)
        // The two fields the slimmed VerdictCard consumes are present.
        #expect(!demo.verdictHeadline.isEmpty)
    }
}
