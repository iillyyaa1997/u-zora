import Testing
import Foundation
@testable import uZora

@Suite("Actions channel surface — GET /actions + uzora_list_actions")
struct ActionsChannelTests {

    private func tempAuditDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-actions-chan-\(UUID().uuidString)", isDirectory: true)
    }
    private func tempConfigURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-actions-cfg-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.toml")
    }

    private func makeRunner(auditDir: URL, contextConfig: ActionsConfig) throws -> ActionRunner {
        let audit = try AuditLog(baseDir: auditDir, retentionDays: 30)
        return ActionRunner(
            registry: ActionRegistry.defaultPopulated(),
            policy: PolicyEngine(),
            audit: audit,
            contextProvider: { PolicyEngine.Context(powerState: .acConnectedLidOpen, focusActive: false, config: contextConfig) }
        )
    }

    @Test func restActions_listsFourActions_withAutoStatus() async throws {
        let auditDir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: auditDir) }
        let cfgURL = tempConfigURL(); defer { try? FileManager.default.removeItem(at: cfgURL.deletingLastPathComponent()) }
        // Opt in one action in the on-disk config so auto_enabled reflects it.
        let loader = try ConfigLoader(configURL: cfgURL)
        var cfg = await loader.current
        cfg.actions.setOverride(ActionOverride(autoEnabled: true), for: "brew_cleanup")
        try await loader.write(cfg)

        let runner = try makeRunner(auditDir: auditDir, contextConfig: cfg.actions)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader, actionRunner: runner)
        let resp = await rest.actions()
        #expect(resp.status == 200)
        let json = try JSONValue.decode(resp.body)
        guard case .object(let obj) = json, case .array(let actions)? = obj["actions"] else {
            Issue.record("expected actions array"); return
        }
        #expect(actions.count == 4)
        // Find brew_cleanup and assert auto_enabled true; others false.
        var autoByID: [String: Bool] = [:]
        for a in actions {
            if case .object(let ao) = a,
               case .string(let id)? = ao["id"],
               case .bool(let auto)? = ao["auto_enabled"] {
                autoByID[id] = auto
            }
        }
        #expect(autoByID["brew_cleanup"] == true)
        #expect(autoByID["prune_apfs_snapshots"] == false)
        #expect(autoByID["clear_user_caches"] == false)
    }

    @Test func restActions_includesSafetyAndCautionFlag() async throws {
        let auditDir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: auditDir) }
        let cfgURL = tempConfigURL(); defer { try? FileManager.default.removeItem(at: cfgURL.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: cfgURL)
        let runner = try makeRunner(auditDir: auditDir, contextConfig: ActionsConfig())
        let rest = RESTHandlers(state: StateStore(), configLoader: loader, actionRunner: runner)
        let resp = await rest.actions()
        let json = try JSONValue.decode(resp.body)
        guard case .object(let obj) = json else { Issue.record("no object"); return }
        // safety block reflects defaults + always-on audit.
        if case .object(let safety)? = obj["safety"] {
            #expect(safety["audit_log_always_on"] == .bool(true))
            #expect(safety["cool_down_minutes"] == .int(30))
            #expect(safety["rate_limit_per_hour"] == .int(6))
        } else {
            Issue.record("missing safety block")
        }
        // clear_user_caches carries caution=true.
        if case .array(let actions)? = obj["actions"] {
            let caches = actions.first {
                if case .object(let a) = $0, case .string("clear_user_caches")? = a["id"] { return true }
                return false
            }
            if case .object(let a)? = caches {
                #expect(a["caution"] == .bool(true))
            } else { Issue.record("clear_user_caches not found") }
        }
    }

    @Test func restActions_noRunner_returnsEmptyWithNote() async {
        // A read-only RESTHandlers without a runner answers 200 + a note.
        let rest = RESTHandlers(state: StateStore())
        let resp = await rest.actions()
        #expect(resp.status == 200)
        let body = String(data: resp.body, encoding: .utf8) ?? ""
        #expect(body.contains("not wired"))
    }

    @Test func restActions_surfacesRecentAuditAfterRun() async throws {
        let auditDir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: auditDir) }
        let cfgURL = tempConfigURL(); defer { try? FileManager.default.removeItem(at: cfgURL.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: cfgURL)
        let runner = try makeRunner(auditDir: auditDir, contextConfig: ActionsConfig())
        // A confirmed run (brew likely absent in CI → graceful skip, still audits).
        _ = await runner.run(actionID: "brew_cleanup", trigger: .confirmed)
        let rest = RESTHandlers(state: StateStore(), configLoader: loader, actionRunner: runner)
        let resp = await rest.actions()
        let json = try JSONValue.decode(resp.body)
        guard case .object(let obj) = json, case .array(let recent)? = obj["recent_audit"] else {
            Issue.record("expected recent_audit array"); return
        }
        #expect(recent.count == 1)
    }

    // MARK: - MCP

    @Test func mcp_listActions_toolPresent_andInvokes() async throws {
        let auditDir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: auditDir) }
        let cfgURL = tempConfigURL(); defer { try? FileManager.default.removeItem(at: cfgURL.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: cfgURL)
        let runner = try makeRunner(auditDir: auditDir, contextConfig: ActionsConfig())
        let rest = RESTHandlers(state: StateStore(), configLoader: loader, actionRunner: runner)
        let tools = MCPTools(rest: rest, httpBaseURL: "http://127.0.0.1:0")

        // Listed among the read tools.
        let schemas = tools.listSchemas()
        let names = schemas.compactMap { schema -> String? in
            if case .string(let n)? = schema["name"] { return n }
            return nil
        }
        #expect(names.contains("uzora_list_actions"))
        // 10 read tools (incl. Phase 5 list_findings + get_verdict and B1a
        // list_metrics + get_layout) + 2 write tools.
        #expect(names.count == 12)

        // Invokes without error and surfaces the four action ids.
        let result = try await tools.invoke(name: "uzora_list_actions", arguments: .object([:]))
        guard case .object(let obj) = result else { Issue.record("no object"); return }
        #expect(obj["isError"] == .bool(false))
        let text: String
        if case .array(let content)? = obj["content"], case .object(let first)? = content.first,
           case .string(let t)? = first["text"] {
            text = t
        } else { text = "" }
        #expect(text.contains("prune_apfs_snapshots"))
        #expect(text.contains("clear_user_caches"))
    }
}
