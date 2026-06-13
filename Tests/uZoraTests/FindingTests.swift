import Foundation
import Testing
@testable import uZora

@Suite("Finding + Confidence value-type contracts")
struct FindingTests {

    private static func sampleFinding(
        detector: String = "runaway_daemon",
        subject: String = "ecosystemd",
        severity: Severity = .warn,
        confidence: Confidence = .medium,
        evidence: [String: String]? = ["cores_pinned": "2", "cpu_pct": "98.5"],
        suggestedAction: String? = "reboot recommended"
    ) -> Finding {
        Finding(
            detector: detector,
            subject: subject,
            severity: severity,
            confidence: confidence,
            title: "System daemon pinning CPU",
            explanation: "ecosystemd is re-hashing code signatures in a loop.",
            evidence: evidence,
            suggestedAction: suggestedAction,
            firstSeen: Date(timeIntervalSince1970: 1_700_000_000),
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_300)
        )
    }

    // MARK: - id format

    @Test func id_isDetectorColonSubject() {
        let f = Self.sampleFinding(detector: "disk_hard_critical", subject: "/")
        #expect(f.id == "disk_hard_critical:/")
    }

    // MARK: - Finding round-trip Codable

    @Test func finding_roundTripsThroughJSON() throws {
        let original = Self.sampleFinding()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Finding.self, from: data)
        #expect(decoded == original)
    }

    @Test func finding_roundTripsWithNilOptionals() throws {
        let original = Self.sampleFinding(evidence: nil, suggestedAction: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Finding.self, from: data)
        #expect(decoded == original)
        #expect(decoded.evidence == nil)
        #expect(decoded.suggestedAction == nil)
    }

    @Test func finding_isHashableByValue() {
        let a = Self.sampleFinding()
        let b = Self.sampleFinding()
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        let set: Set<Finding> = [a, b]
        #expect(set.count == 1)
    }

    // MARK: - Confidence Comparable ordering

    @Test func confidence_isOrderedLowMediumHigh() {
        #expect(Confidence.low < Confidence.medium)
        #expect(Confidence.medium < Confidence.high)
        #expect(Confidence.low < Confidence.high)
        #expect(!(Confidence.high < Confidence.low))
        #expect(!(Confidence.medium < Confidence.medium))
    }

    @Test func confidence_sortsAscending() {
        let sorted = [Confidence.high, .low, .medium].sorted()
        #expect(sorted == [.low, .medium, .high])
    }

    @Test func confidence_caseIterableHasThreeCases() {
        #expect(Confidence.allCases == [.low, .medium, .high])
    }

    // MARK: - Confidence Codable

    @Test func confidence_codesAsRawString() throws {
        let encoder = JSONEncoder()
        for (value, raw) in [(Confidence.low, "low"), (.medium, "medium"), (.high, "high")] {
            let data = try encoder.encode(value)
            let str = String(data: data, encoding: .utf8)
            #expect(str == "\"\(raw)\"")
            let back = try JSONDecoder().decode(Confidence.self, from: data)
            #expect(back == value)
        }
    }
}
