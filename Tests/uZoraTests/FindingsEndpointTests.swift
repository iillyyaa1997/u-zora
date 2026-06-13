import Testing
import Foundation
@testable import uZora

/// Phase 5 — `GET /findings` + `GET /verdict` REST handlers. Builds a
/// `RESTHandlers` seeded via a `DiagnosisStore` and asserts JSON shape
/// (snake_case keys), the severity filter, the nil-store note path, and
/// that `dispatch(_:)` routes both endpoints. Mirrors how the existing REST
/// handler tests build a store + push synthetic state, then decode the
/// handler's `HTTPResponse.body`.
@Suite("REST /findings + /verdict handlers")
struct FindingsEndpointTests {

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

    private func json(_ resp: HTTPResponse) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
    }

    // MARK: - /findings

    @Test func findings_returnsSnakeCaseShape() async {
        let diag = DiagnosisStore()
        let f = finding(detector: "runaway_daemon", subject: "ecosystemd", severity: .critical)
        await diag.update(findings: [f], verdict: Verdict.derive(from: [f]))
        let rest = RESTHandlers(state: StateStore(), diagnosisStore: diag)

        let resp = await rest.findings()
        #expect(resp.status == 200)
        let body = json(resp)
        let arr = body?["findings"] as? [[String: Any]]
        #expect(arr?.count == 1)
        #expect(body?["count"] as? Int == 1)
        // snake_case + content surfaced.
        #expect(arr?.first?["detector"] as? String == "runaway_daemon")
        #expect(arr?.first?["subject"] as? String == "ecosystemd")
        #expect(arr?.first?["severity"] as? String == "critical")
        // No note on the wired path.
        #expect(body?["note"] == nil)
    }

    @Test func findings_filtersBySeverity() async {
        let diag = DiagnosisStore()
        let info = finding(detector: "x", subject: "1", severity: .info)
        let warn = finding(detector: "x", subject: "2", severity: .warn)
        let crit = finding(detector: "x", subject: "3", severity: .critical)
        await diag.update(findings: [info, warn, crit], verdict: Verdict.derive(from: [info, warn, crit]))
        let rest = RESTHandlers(state: StateStore(), diagnosisStore: diag)

        let resp = await rest.findings(minSeverity: .warn)
        let arr = json(resp)?["findings"] as? [[String: Any]]
        #expect(arr?.count == 2)
        #expect(json(resp)?["count"] as? Int == 2)
    }

    @Test func findings_nilStore_returnsEmptyWithNote() async {
        // No diagnosisStore wired → graceful degradation (empty + note).
        let rest = RESTHandlers(state: StateStore())
        let resp = await rest.findings()
        #expect(resp.status == 200)
        let body = json(resp)
        #expect((body?["findings"] as? [Any])?.isEmpty == true)
        #expect(body?["count"] as? Int == 0)
        #expect((body?["note"] as? String)?.contains("not wired") == true)
    }

    // MARK: - /verdict

    @Test func verdict_returnsLevelHeadlineFindings() async {
        let diag = DiagnosisStore()
        let f = finding(detector: "runaway_daemon", subject: "d", severity: .warn, confidence: .high, title: "Daemon pinning CPU")
        await diag.update(findings: [f], verdict: Verdict.derive(from: [f]))
        let rest = RESTHandlers(state: StateStore(), diagnosisStore: diag)

        let resp = await rest.verdict()
        #expect(resp.status == 200)
        let body = json(resp)
        #expect(body?["level"] as? String == "degraded")   // warn + high
        #expect(body?["headline"] as? String == "Daemon pinning CPU")
        let arr = body?["findings"] as? [[String: Any]]
        #expect(arr?.count == 1)
        #expect(body?["count"] as? Int == 1)
        #expect(body?["note"] == nil)
    }

    @Test func verdict_nilStore_returnsGoodWithNote() async {
        let rest = RESTHandlers(state: StateStore())
        let resp = await rest.verdict()
        #expect(resp.status == 200)
        let body = json(resp)
        #expect(body?["level"] as? String == "good")
        #expect(body?["headline"] as? String == Verdict.healthyHeadline)
        #expect((body?["findings"] as? [Any])?.isEmpty == true)
        #expect((body?["note"] as? String)?.contains("not wired") == true)
    }

    @Test func verdict_emptyStore_returnsGoodNoNote() async {
        // A wired-but-never-fed store is the clean-machine case: good + no note.
        let diag = DiagnosisStore()
        let rest = RESTHandlers(state: StateStore(), diagnosisStore: diag)
        let resp = await rest.verdict()
        let body = json(resp)
        #expect(body?["level"] as? String == "good")
        #expect(body?["note"] == nil)
    }

    // MARK: - dispatch routing

    @Test func dispatch_routesFindingsAndVerdict() async {
        let diag = DiagnosisStore()
        let f = finding(detector: "x", subject: "2", severity: .warn, confidence: .low)
        await diag.update(findings: [f], verdict: Verdict.derive(from: [f]))
        let rest = RESTHandlers(state: StateStore(), diagnosisStore: diag)

        let findingsReq = HTTPRequest(method: "GET", path: "/findings", query: [:], headers: [:], body: Data())
        let fResp = await rest.dispatch(findingsReq)
        #expect(fResp.status == 200)
        #expect((json(fResp)?["findings"] as? [Any])?.count == 1)

        let verdictReq = HTTPRequest(method: "GET", path: "/verdict", query: [:], headers: [:], body: Data())
        let vResp = await rest.dispatch(verdictReq)
        #expect(vResp.status == 200)
        #expect(json(vResp)?["level"] as? String == "watch")   // warn + low → watch
    }

    @Test func dispatch_findings_severityQueryParam() async {
        let diag = DiagnosisStore()
        let warn = finding(detector: "x", subject: "2", severity: .warn)
        let crit = finding(detector: "x", subject: "3", severity: .critical)
        await diag.update(findings: [warn, crit], verdict: Verdict.derive(from: [warn, crit]))
        let rest = RESTHandlers(state: StateStore(), diagnosisStore: diag)

        let req = HTTPRequest(method: "GET", path: "/findings", query: ["severity": "critical"], headers: [:], body: Data())
        let resp = await rest.dispatch(req)
        let arr = json(resp)?["findings"] as? [[String: Any]]
        #expect(arr?.count == 1)
        #expect(arr?.first?["severity"] as? String == "critical")
    }
}
