import Foundation
import Testing
@testable import uZora

@Suite("Verdict model — contribution table + derivation")
struct VerdictTests {

    // MARK: - Builder

    private static func finding(
        detector: String = "d",
        subject: String = "s",
        severity: Severity,
        confidence: Confidence,
        title: String = "T",
        explanation: String = "E"
    ) -> Finding {
        Finding(
            detector: detector,
            subject: subject,
            severity: severity,
            confidence: confidence,
            title: title,
            explanation: explanation,
            evidence: nil,
            suggestedAction: nil,
            firstSeen: Date(timeIntervalSince1970: 1000),
            lastUpdated: Date(timeIntervalSince1970: 1100)
        )
    }

    // MARK: - VerdictLevel ordering

    @Test func level_isOrderedGoodWatchDegradedProblem() {
        #expect(VerdictLevel.good < VerdictLevel.watch)
        #expect(VerdictLevel.watch < VerdictLevel.degraded)
        #expect(VerdictLevel.degraded < VerdictLevel.problem)
        #expect(VerdictLevel.good < VerdictLevel.problem)
        #expect(!(VerdictLevel.problem < VerdictLevel.good))
    }

    @Test func level_caseIterableOrder() {
        #expect(VerdictLevel.allCases == [.good, .watch, .degraded, .problem])
    }

    @Test func level_codesAsRawString() throws {
        let encoder = JSONEncoder()
        for (value, raw) in [(VerdictLevel.good, "good"), (.watch, "watch"), (.degraded, "degraded"), (.problem, "problem")] {
            let data = try encoder.encode(value)
            #expect(String(data: data, encoding: .utf8) == "\"\(raw)\"")
            #expect(try JSONDecoder().decode(VerdictLevel.self, from: data) == value)
        }
    }

    // MARK: - contribution table (every (severity, confidence))

    @Test func contribution_criticalAlwaysProblem() {
        for conf in Confidence.allCases {
            #expect(Verdict.contribution(severity: .critical, confidence: conf) == .problem, "conf=\(conf)")
        }
    }

    @Test func contribution_warnHighIsDegraded() {
        #expect(Verdict.contribution(severity: .warn, confidence: .high) == .degraded)
    }

    @Test func contribution_warnLowOrMediumIsWatch() {
        #expect(Verdict.contribution(severity: .warn, confidence: .low) == .watch)
        #expect(Verdict.contribution(severity: .warn, confidence: .medium) == .watch)
    }

    @Test func contribution_infoAlwaysWatch() {
        for conf in Confidence.allCases {
            #expect(Verdict.contribution(severity: .info, confidence: conf) == .watch, "conf=\(conf)")
        }
    }

    /// Exhaustive cross-product table.
    @Test func contribution_fullTable() {
        let cases: [(Severity, Confidence, VerdictLevel)] = [
            (.critical, .low, .problem),
            (.critical, .medium, .problem),
            (.critical, .high, .problem),
            (.warn, .low, .watch),
            (.warn, .medium, .watch),
            (.warn, .high, .degraded),
            (.info, .low, .watch),
            (.info, .medium, .watch),
            (.info, .high, .watch),
        ]
        for (sev, conf, expected) in cases {
            #expect(Verdict.contribution(severity: sev, confidence: conf) == expected, "sev=\(sev) conf=\(conf)")
        }
    }

    // MARK: - derive: empty / single-level

    @Test func derive_emptyIsGood() {
        let v = Verdict.derive(from: [])
        #expect(v.level == .good)
        #expect(v.headline == "All systems healthy")
        #expect(v.headline == Verdict.healthyHeadline)
        #expect(v.findings.isEmpty)
    }

    @Test func derive_singleWatch() {
        let f = Self.finding(severity: .warn, confidence: .low, title: "Trend")
        let v = Verdict.derive(from: [f])
        #expect(v.level == .watch)
        #expect(v.headline == "Trend")
    }

    @Test func derive_singleDegraded() {
        let f = Self.finding(severity: .warn, confidence: .high, title: "Slowdown")
        let v = Verdict.derive(from: [f])
        #expect(v.level == .degraded)
        #expect(v.headline == "Slowdown")
    }

    @Test func derive_singleProblem() {
        let f = Self.finding(severity: .critical, confidence: .high, title: "Disk full")
        let v = Verdict.derive(from: [f])
        #expect(v.level == .problem)
        #expect(v.headline == "Disk full")
    }

    @Test func derive_infoIsWatch() {
        let f = Self.finding(severity: .info, confidence: .low, title: "Note")
        let v = Verdict.derive(from: [f])
        #expect(v.level == .watch)
    }

    // MARK: - derive: max-aggregation + driving finding

    @Test func derive_maxAcrossMixedFindings() {
        // watch + degraded + problem present → max = problem.
        let watch = Self.finding(detector: "a", severity: .warn, confidence: .low, title: "watch")
        let degraded = Self.finding(detector: "b", severity: .warn, confidence: .high, title: "degraded")
        let problem = Self.finding(detector: "c", severity: .critical, confidence: .low, title: "problem")
        let v = Verdict.derive(from: [watch, degraded, problem])
        #expect(v.level == .problem)
        // Driving finding = highest contribution → the critical one.
        #expect(v.headline == "problem")
    }

    @Test func derive_headlinePicksDrivingNotFirst() {
        // The first-by-id finding is only `watch`; the driver is the
        // `degraded` one — headline must follow contribution, not order.
        let a = Self.finding(detector: "a_low", severity: .warn, confidence: .low, title: "low one")
        let b = Self.finding(detector: "b_high", severity: .warn, confidence: .high, title: "high one")
        let v = Verdict.derive(from: [a, b])
        #expect(v.level == .degraded)
        #expect(v.headline == "high one")
    }

    @Test func derive_tieBreaksByIdDeterministically() {
        // Two findings with identical (contribution, severity, confidence):
        // the lowest-id one drives the headline, deterministically.
        let z = Self.finding(detector: "z", severity: .warn, confidence: .high, title: "Z headline")
        let a = Self.finding(detector: "a", severity: .warn, confidence: .high, title: "A headline")
        let v1 = Verdict.derive(from: [z, a])
        let v2 = Verdict.derive(from: [a, z])
        #expect(v1.headline == "A headline")
        #expect(v2.headline == "A headline")  // input order independent
        #expect(v1 == v2)
    }

    @Test func derive_findingsSortedById() {
        let z = Self.finding(detector: "z", severity: .warn, confidence: .low)
        let a = Self.finding(detector: "a", severity: .warn, confidence: .low)
        let m = Self.finding(detector: "m", severity: .warn, confidence: .low)
        let v = Verdict.derive(from: [z, a, m])
        let ids = v.findings.map { $0.id }
        #expect(ids == ids.sorted())
        #expect(ids == ["a:s", "m:s", "z:s"])
    }

    @Test func derive_severityTieBreakBeforeConfidence() {
        // Same contribution (both .problem from .critical) but different
        // severities can't happen for problem; use degraded vs problem to
        // confirm the contribution axis dominates, then severity within a
        // contribution level. Here both are .problem (critical) at different
        // confidences → driver = higher confidence.
        let lowConf = Self.finding(detector: "a", severity: .critical, confidence: .low, title: "low-conf crit")
        let highConf = Self.finding(detector: "b", severity: .critical, confidence: .high, title: "high-conf crit")
        let v = Verdict.derive(from: [lowConf, highConf])
        #expect(v.level == .problem)
        #expect(v.headline == "high-conf crit")
    }

    // MARK: - Codable round-trip

    @Test func verdict_roundTripsThroughJSON() throws {
        let f = Self.finding(severity: .critical, confidence: .high, title: "X")
        let original = Verdict.derive(from: [f])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Verdict.self, from: data)
        #expect(decoded == original)
    }
}
