import Testing
import Foundation
@testable import uZora

@Suite("Watchdog diff state machine")
struct WatchdogDiffTests {

    private func alert(probe: String = "disk", key: String, severity: Severity, at: Date = Date()) -> Alert {
        Alert(
            probe: probe,
            key: key,
            severity: severity,
            message: "test",
            details: nil,
            firstSeen: at,
            lastUpdated: at
        )
    }

    // MARK: - step() based table tests

    @Test func emptyToOneAlert_appears() async {
        let w = Watchdog()
        let a = alert(key: "/", severity: .warn)
        let events = await w.step(currentAlerts: [a])
        #expect(events.count == 1)
        if case .appeared(let got) = events[0] {
            #expect(got.id == a.id)
        } else {
            Issue.record("expected .appeared, got \(events[0])")
        }
    }

    @Test func sameAlertSameSeverity_silent() async {
        let w = Watchdog()
        let a = alert(key: "/", severity: .warn)
        _ = await w.step(currentAlerts: [a])
        let events = await w.step(currentAlerts: [a])
        #expect(events.isEmpty)
    }

    @Test func sameAlertEscalated_emitsEscalated() async {
        let w = Watchdog()
        let warnVersion = alert(key: "/", severity: .warn)
        _ = await w.step(currentAlerts: [warnVersion])
        let criticalVersion = alert(key: "/", severity: .critical)
        let events = await w.step(currentAlerts: [criticalVersion])
        #expect(events.count == 1)
        if case .escalated(let got, let prev) = events[0] {
            #expect(got.id == criticalVersion.id)
            #expect(got.severity == .critical)
            #expect(prev == .warn)
        } else {
            Issue.record("expected .escalated, got \(events[0])")
        }
    }

    @Test func alertDisappears_emitsCleared() async {
        let w = Watchdog()
        let a = alert(key: "/", severity: .warn)
        _ = await w.step(currentAlerts: [a])
        let events = await w.step(currentAlerts: [])
        #expect(events.count == 1)
        if case .cleared(let id) = events[0] {
            #expect(id == a.id)
        } else {
            Issue.record("expected .cleared, got \(events[0])")
        }
    }

    @Test func deescalation_isSilent() async {
        // Phase 3 spec: downgrade is not an event. Only appear/escalate/clear.
        let w = Watchdog()
        let crit = alert(key: "/", severity: .critical)
        _ = await w.step(currentAlerts: [crit])
        let warn = alert(key: "/", severity: .warn)
        let events = await w.step(currentAlerts: [warn])
        #expect(events.isEmpty)
    }

    @Test func mixedTransitions_correctSet() async {
        let w = Watchdog()

        // Turn 1: appear A.warn + B.info
        let a1 = alert(key: "a", severity: .warn)
        let b1 = alert(key: "b", severity: .info)
        let events1 = await w.step(currentAlerts: [a1, b1])
        #expect(events1.count == 2)

        // Turn 2: A.warn stays, B.info escalates to B.critical, C.warn appears.
        let a2 = alert(key: "a", severity: .warn)
        let b2 = alert(key: "b", severity: .critical)
        let c2 = alert(key: "c", severity: .warn)
        let events2 = await w.step(currentAlerts: [a2, b2, c2])
        // Expected: escalated B, appeared C. A is silent.
        #expect(events2.count == 2)
        let hasEscalateB = events2.contains { ev in
            if case .escalated(let alert, _) = ev { return alert.id == "disk:b" }
            return false
        }
        let hasAppearC = events2.contains { ev in
            if case .appeared(let alert) = ev { return alert.id == "disk:c" }
            return false
        }
        #expect(hasEscalateB)
        #expect(hasAppearC)

        // Turn 3: A disappears, B stays critical, C stays warn.
        let b3 = alert(key: "b", severity: .critical)
        let c3 = alert(key: "c", severity: .warn)
        let events3 = await w.step(currentAlerts: [b3, c3])
        #expect(events3.count == 1) // cleared A
        if case .cleared(let id) = events3[0] {
            #expect(id == "disk:a")
        } else {
            Issue.record("expected cleared(disk:a)")
        }
    }

    @Test func reset_clearsPriorState() async {
        let w = Watchdog()
        _ = await w.step(currentAlerts: [alert(key: "/", severity: .warn)])
        await w.reset()
        let snap = await w.snapshot()
        #expect(snap.isEmpty)
        // After reset, the same alert appears again rather than being silent.
        let events = await w.step(currentAlerts: [alert(key: "/", severity: .warn)])
        #expect(events.count == 1)
        if case .appeared = events[0] {
            // ok
        } else {
            Issue.record("expected appeared after reset")
        }
    }

    @Test func emptyToEmpty_isSilent() async {
        let w = Watchdog()
        let events = await w.step(currentAlerts: [])
        #expect(events.isEmpty)
    }

    // MARK: - diff() pure variant

    @Test func purediff_basicAppearAndClear() async {
        let w = Watchdog()
        let a = alert(key: "/", severity: .warn)
        let events1 = await w.diff(previous: [:], current: [a])
        #expect(events1.count == 1)
        if case .appeared = events1[0] {} else { Issue.record("expected appeared") }

        let events2 = await w.diff(previous: [a.id: a], current: [])
        #expect(events2.count == 1)
        if case .cleared = events2[0] {} else { Issue.record("expected cleared") }
    }

    @Test func clearedOrdering_isStableSorted() async {
        // Sort guarantee in the spec: cleared events arrive in sorted-by-id order.
        let w = Watchdog()
        let a = alert(key: "alpha", severity: .warn)
        let b = alert(key: "beta", severity: .warn)
        let c = alert(key: "charlie", severity: .warn)
        _ = await w.step(currentAlerts: [a, b, c])
        let events = await w.step(currentAlerts: [])
        let clearedIds: [String] = events.compactMap { ev in
            if case .cleared(let id) = ev { return id }
            return nil
        }
        #expect(clearedIds == ["disk:alpha", "disk:beta", "disk:charlie"])
    }
}
