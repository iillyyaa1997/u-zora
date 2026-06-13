import Testing
import Foundation
@testable import uZora

@Suite("FindingWatchdog diff state machine")
struct FindingWatchdogDiffTests {

    private func finding(
        detector: String = "runaway_daemon",
        subject: String,
        severity: Severity,
        confidence: Confidence,
        at: Date = Date()
    ) -> Finding {
        Finding(
            detector: detector,
            subject: subject,
            severity: severity,
            confidence: confidence,
            title: "test",
            explanation: "test",
            evidence: nil,
            suggestedAction: nil,
            firstSeen: at,
            lastUpdated: at
        )
    }

    @Test func emptyToOne_diagnosed() async {
        let w = FindingWatchdog()
        let f = finding(subject: "ecosystemd", severity: .warn, confidence: .low)
        let events = await w.step(currentFindings: [f])
        #expect(events.count == 1)
        if case .diagnosed(let got) = events[0] {
            #expect(got.id == f.id)
        } else {
            Issue.record("expected .diagnosed, got \(events[0])")
        }
    }

    @Test func sameSeverityAndConfidence_silent() async {
        let w = FindingWatchdog()
        let f = finding(subject: "ecosystemd", severity: .warn, confidence: .medium)
        _ = await w.step(currentFindings: [f])
        let events = await w.step(currentFindings: [f])
        #expect(events.isEmpty)
    }

    @Test func severityRise_emitsRediagnosed() async {
        let w = FindingWatchdog()
        let warnVersion = finding(subject: "ecosystemd", severity: .warn, confidence: .medium)
        _ = await w.step(currentFindings: [warnVersion])
        let criticalVersion = finding(subject: "ecosystemd", severity: .critical, confidence: .medium)
        let events = await w.step(currentFindings: [criticalVersion])
        #expect(events.count == 1)
        if case .rediagnosed(let got, let prevSev, let prevConf) = events[0] {
            #expect(got.severity == .critical)
            #expect(prevSev == .warn)
            #expect(prevConf == .medium)
        } else {
            Issue.record("expected .rediagnosed on severity rise, got \(events[0])")
        }
    }

    @Test func confidenceRise_emitsRediagnosed() async {
        let w = FindingWatchdog()
        let lowConf = finding(subject: "ecosystemd", severity: .warn, confidence: .low)
        _ = await w.step(currentFindings: [lowConf])
        // Severity UNCHANGED, only confidence rises low→high.
        let highConf = finding(subject: "ecosystemd", severity: .warn, confidence: .high)
        let events = await w.step(currentFindings: [highConf])
        #expect(events.count == 1)
        if case .rediagnosed(let got, let prevSev, let prevConf) = events[0] {
            #expect(got.confidence == .high)
            #expect(got.severity == .warn)
            #expect(prevSev == .warn)
            #expect(prevConf == .low)
        } else {
            Issue.record("expected .rediagnosed on confidence rise, got \(events[0])")
        }
    }

    @Test func findingDisappears_emitsResolved() async {
        let w = FindingWatchdog()
        let f = finding(subject: "ecosystemd", severity: .warn, confidence: .medium)
        _ = await w.step(currentFindings: [f])
        let events = await w.step(currentFindings: [])
        #expect(events.count == 1)
        if case .resolved(let id) = events[0] {
            #expect(id == f.id)
        } else {
            Issue.record("expected .resolved, got \(events[0])")
        }
    }

    @Test func deWorseningSeverity_isSilent() async {
        // Downgrade (critical→warn) is not an event.
        let w = FindingWatchdog()
        let crit = finding(subject: "ecosystemd", severity: .critical, confidence: .high)
        _ = await w.step(currentFindings: [crit])
        let warn = finding(subject: "ecosystemd", severity: .warn, confidence: .high)
        let events = await w.step(currentFindings: [warn])
        #expect(events.isEmpty)
    }

    @Test func deWorseningConfidence_isSilent() async {
        // Confidence downgrade (high→low) is not an event.
        let w = FindingWatchdog()
        let high = finding(subject: "ecosystemd", severity: .warn, confidence: .high)
        _ = await w.step(currentFindings: [high])
        let low = finding(subject: "ecosystemd", severity: .warn, confidence: .low)
        let events = await w.step(currentFindings: [low])
        #expect(events.isEmpty)
    }

    @Test func bothAxesUnchangedAfterPriorRise_silent() async {
        // After a rediagnosed, re-ticking at the new level is idempotent.
        let w = FindingWatchdog()
        _ = await w.step(currentFindings: [finding(subject: "d", severity: .warn, confidence: .low)])
        let bumped = finding(subject: "d", severity: .critical, confidence: .high)
        let e1 = await w.step(currentFindings: [bumped])
        #expect(e1.count == 1)
        let e2 = await w.step(currentFindings: [bumped])
        #expect(e2.isEmpty)
    }

    @Test func mixedTransitions_correctSet() async {
        let w = FindingWatchdog()

        // Turn 1: diagnose A (warn/low) + B (info/medium).
        let a1 = finding(subject: "a", severity: .warn, confidence: .low)
        let b1 = finding(subject: "b", severity: .info, confidence: .medium)
        let events1 = await w.step(currentFindings: [a1, b1])
        #expect(events1.count == 2)

        // Turn 2: A stays, B escalates info→critical, C (warn/high) appears.
        let a2 = finding(subject: "a", severity: .warn, confidence: .low)
        let b2 = finding(subject: "b", severity: .critical, confidence: .medium)
        let c2 = finding(subject: "c", severity: .warn, confidence: .high)
        let events2 = await w.step(currentFindings: [a2, b2, c2])
        #expect(events2.count == 2)
        let hasRediagB = events2.contains { ev in
            if case .rediagnosed(let f, _, _) = ev { return f.id == "runaway_daemon:b" }
            return false
        }
        let hasDiagC = events2.contains { ev in
            if case .diagnosed(let f) = ev { return f.id == "runaway_daemon:c" }
            return false
        }
        #expect(hasRediagB)
        #expect(hasDiagC)

        // Turn 3: A disappears, B stays, C stays.
        let b3 = finding(subject: "b", severity: .critical, confidence: .medium)
        let c3 = finding(subject: "c", severity: .warn, confidence: .high)
        let events3 = await w.step(currentFindings: [b3, c3])
        #expect(events3.count == 1)
        if case .resolved(let id) = events3[0] {
            #expect(id == "runaway_daemon:a")
        } else {
            Issue.record("expected resolved(runaway_daemon:a), got \(events3[0])")
        }
    }

    @Test func resolvedOrdering_isStableSorted() async {
        let w = FindingWatchdog()
        let a = finding(subject: "alpha", severity: .warn, confidence: .low)
        let b = finding(subject: "beta", severity: .warn, confidence: .low)
        let c = finding(subject: "charlie", severity: .warn, confidence: .low)
        _ = await w.step(currentFindings: [a, b, c])
        let events = await w.step(currentFindings: [])
        let resolvedIds: [String] = events.compactMap { ev in
            if case .resolved(let id) = ev { return id }
            return nil
        }
        #expect(resolvedIds == [
            "runaway_daemon:alpha", "runaway_daemon:beta", "runaway_daemon:charlie",
        ])
    }

    @Test func reset_clearsPriorState() async {
        let w = FindingWatchdog()
        _ = await w.step(currentFindings: [finding(subject: "d", severity: .warn, confidence: .low)])
        await w.reset()
        let snap = await w.snapshot()
        #expect(snap.isEmpty)
        // After reset, the same finding is diagnosed again rather than silent.
        let events = await w.step(currentFindings: [finding(subject: "d", severity: .warn, confidence: .low)])
        #expect(events.count == 1)
        if case .diagnosed = events[0] {} else { Issue.record("expected diagnosed after reset") }
    }

    @Test func emptyToEmpty_isSilent() async {
        let w = FindingWatchdog()
        let events = await w.step(currentFindings: [])
        #expect(events.isEmpty)
    }

    // MARK: - FindingEvent Codable single-tag layout

    @Test func findingEvent_roundTripsAllCases() throws {
        let f = finding(subject: "ecosystemd", severity: .warn, confidence: .low,
                        at: Date(timeIntervalSince1970: 1_700_000_000))
        let cases: [FindingEvent] = [
            .diagnosed(f),
            .rediagnosed(f, previousSeverity: .info, previousConfidence: .low),
            .resolved(f.id),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for ev in cases {
            let data = try encoder.encode(ev)
            let back = try decoder.decode(FindingEvent.self, from: data)
            #expect(back == ev)
        }
    }

    @Test func findingEvent_usesKindTagAndExpectedKeys() throws {
        let f = finding(subject: "ecosystemd", severity: .warn, confidence: .low,
                        at: Date(timeIntervalSince1970: 1_700_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let resolvedJSON = String(data: try encoder.encode(FindingEvent.resolved("runaway_daemon:ecosystemd")), encoding: .utf8) ?? ""
        #expect(resolvedJSON.contains("\"kind\":\"resolved\""))
        #expect(resolvedJSON.contains("\"finding_id\":\"runaway_daemon:ecosystemd\""))

        let rediagJSON = String(data: try encoder.encode(FindingEvent.rediagnosed(f, previousSeverity: .info, previousConfidence: .low)), encoding: .utf8) ?? ""
        #expect(rediagJSON.contains("\"kind\":\"rediagnosed\""))
        #expect(rediagJSON.contains("\"previous_severity\":\"info\""))
        #expect(rediagJSON.contains("\"previous_confidence\":\"low\""))

        let diagJSON = String(data: try encoder.encode(FindingEvent.diagnosed(f)), encoding: .utf8) ?? ""
        #expect(diagJSON.contains("\"kind\":\"diagnosed\""))
        #expect(diagJSON.contains("\"finding\""))
    }
}
