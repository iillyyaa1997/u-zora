import Testing
import Foundation
@testable import uZora

/// Phase 5 — MCP `uzora_list_findings` + `uzora_get_verdict` read tools.
/// Invokes them through `MCPTools.invoke(...)` (single-sourced through the
/// REST handlers) and asserts the wrapped `structuredContent` shape, plus
/// that both tools appear in `listSchemas()` / `readSchemas`.
@Suite("MCP findings + verdict read tools")
struct MCPFindingsToolsTests {

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

    private func tools(_ diag: DiagnosisStore?) -> MCPTools {
        let rest = RESTHandlers(state: StateStore(), diagnosisStore: diag)
        return MCPTools(rest: rest, httpBaseURL: "http://127.0.0.1:0")
    }

    /// Unwrap the `structuredContent` object from a wrapped tool result.
    private func structured(_ result: JSONValue) -> [String: JSONValue]? {
        guard case .object(let obj) = result,
              case .object(let sc)? = obj["structuredContent"] else { return nil }
        return sc
    }

    @Test func listFindings_returnsWrappedStructuredContent() async throws {
        let diag = DiagnosisStore()
        let f = finding(detector: "runaway_daemon", subject: "ecosystemd", severity: .critical)
        await diag.update(findings: [f], verdict: Verdict.derive(from: [f]))

        let result = try await tools(diag).invoke(name: "uzora_list_findings", arguments: .object([:]))
        let sc = structured(result)
        guard case .array(let arr)? = sc?["findings"] else {
            Issue.record("findings array missing")
            return
        }
        #expect(arr.count == 1)
        guard case .int(let count)? = sc?["count"] else {
            Issue.record("count missing/not int")
            return
        }
        #expect(count == 1)
        // isError is false on a successful read.
        if case .object(let obj) = result, case .bool(let isErr)? = obj["isError"] {
            #expect(isErr == false)
        } else {
            Issue.record("isError missing")
        }
    }

    @Test func listFindings_severityFilter() async throws {
        let diag = DiagnosisStore()
        let warn = finding(detector: "x", subject: "2", severity: .warn)
        let crit = finding(detector: "x", subject: "3", severity: .critical)
        await diag.update(findings: [warn, crit], verdict: Verdict.derive(from: [warn, crit]))

        let args: JSONValue = .object(["severity": .string("critical")])
        let result = try await tools(diag).invoke(name: "uzora_list_findings", arguments: args)
        guard case .array(let arr)? = structured(result)?["findings"] else {
            Issue.record("findings array missing")
            return
        }
        #expect(arr.count == 1)
    }

    @Test func getVerdict_returnsWrappedStructuredContent() async throws {
        let diag = DiagnosisStore()
        let f = finding(detector: "runaway_daemon", subject: "d", severity: .warn, confidence: .high, title: "Daemon pinning CPU")
        await diag.update(findings: [f], verdict: Verdict.derive(from: [f]))

        let result = try await tools(diag).invoke(name: "uzora_get_verdict", arguments: .object([:]))
        let sc = structured(result)
        if case .string(let level)? = sc?["level"] {
            #expect(level == "degraded")
        } else {
            Issue.record("level missing")
        }
        if case .string(let headline)? = sc?["headline"] {
            #expect(headline == "Daemon pinning CPU")
        } else {
            Issue.record("headline missing")
        }
    }

    @Test func getVerdict_nilStore_returnsGood() async throws {
        let result = try await tools(nil).invoke(name: "uzora_get_verdict", arguments: .object([:]))
        if case .string(let level)? = structured(result)?["level"] {
            #expect(level == "good")
        } else {
            Issue.record("level missing")
        }
    }

    @Test func bothTools_appearInSchemas() {
        let schemas = tools(DiagnosisStore())
        let names = Set(schemas.listSchemas().compactMap { schema -> String? in
            if case .string(let n)? = schema["name"] { return n }
            return nil
        })
        #expect(names.contains("uzora_list_findings"))
        #expect(names.contains("uzora_get_verdict"))

        // Both are read-only → present in readSchemas regardless of writes.
        let readNames = Set(MCPTools.readSchemas.compactMap { schema -> String? in
            if case .string(let n)? = schema["name"] { return n }
            return nil
        })
        #expect(readNames.contains("uzora_list_findings"))
        #expect(readNames.contains("uzora_get_verdict"))
    }
}
