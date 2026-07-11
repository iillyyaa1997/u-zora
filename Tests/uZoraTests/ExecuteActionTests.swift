import Testing
import Foundation
@testable import uZora

/// Phase B2 — the Execute tier: an LLM may REQUEST an action run over the
/// bridge, but it is gated. OFF by default, bearer-required (a write, reuses
/// B1b), and human-tap-confirmed by default (a macOS approval notification whose
/// tap runs the action) with an opt-in capability token for UNATTENDED runs.
/// `dry_run` (a non-mutating preview) is always allowed.
///
/// Groups:
///  1. `RESTHandlers.runAction` decision order (401 / 403 / 404 / dry / approval
///     / unattended), including the capability-token fallback.
///  2. MCP `uzora_run_action` parity (tool present; dry-run ok; disabled → error).
///  3. Config round-trip of execute_enabled / capability_token + the
///     bridge-write-cannot-set-them invariant.
@Suite("B2 — Execute tier (uzora_run_action / POST /actions/run)")
struct ExecuteActionTests {

    // MARK: - Fixtures

    private static let knownID = "prune_apfs_snapshots"

    private func tempAuditDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-b2-audit-\(UUID().uuidString)", isDirectory: true)
    }
    private func tempConfigURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-b2-cfg-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.toml")
    }

    /// A runner whose registry holds ONE no-side-effect fake action (id =
    /// `knownID`), so a confirmed/unattended run never touches the machine.
    private func makeRunner(auditDir: URL) throws -> ActionRunner {
        let audit = try AuditLog(baseDir: auditDir, retentionDays: 30)
        return ActionRunner(
            registry: ActionRegistry(actions: [FakeRunAction(id: Self.knownID)]),
            policy: PolicyEngine(),
            audit: audit,
            contextProvider: { PolicyEngine.Context(powerState: .acConnectedLidOpen, focusActive: false, config: ActionsConfig()) }
        )
    }

    /// Build a RESTHandlers wired for the Execute tier. `recorder` captures the
    /// human-tap approval requests so a test asserts the approval path was taken
    /// (and, crucially, that no inline run happened).
    private func makeRest(
        runner: ActionRunner,
        token: String = "T0KEN",
        allowWrites: Bool = true,
        executeEnabled: Bool,
        capabilityToken: String = "",
        recorder: ApprovalRecorder? = nil
    ) -> RESTHandlers {
        let requester: (@Sendable (String, String) async -> Void)?
        if let rec = recorder {
            requester = { id, name in await rec.record(id: id, name: name) }
        } else {
            requester = nil
        }
        return RESTHandlers(
            state: StateStore(),
            allowWrites: allowWrites,
            actionRunner: runner,
            bridgeAuth: BridgeAuth(token: token),
            executeEnabled: executeEnabled,
            capabilityToken: capabilityToken,
            approvalRequester: requester
        )
    }

    private func status(of resp: HTTPResponse) -> String? {
        guard case .object(let o)? = try? JSONValue.decode(resp.body),
              case .string(let s)? = o["status"] else { return nil }
        return s
    }

    // MARK: - 1. runAction decision order

    @Test func run_noBearer_401_andNothingRuns() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = try makeRunner(auditDir: dir)
        let rest = makeRest(runner: runner, executeEnabled: true)
        // No Authorization ⇒ 401 (auth wired). The gate short-circuits before any run.
        let resp = await rest.runAction(id: Self.knownID, dryRun: false, capabilityToken: "")
        #expect(resp.status == 401)
        #expect(await runner.recentAudit(10).isEmpty)
    }

    @Test func run_executeDisabled_realRun_403() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = try makeRunner(auditDir: dir)
        // execute_enabled defaults false → a real run is refused even with a valid bearer.
        let rest = makeRest(runner: runner, executeEnabled: false)
        let resp = await rest.runAction(
            id: Self.knownID, dryRun: false, capabilityToken: "",
            auth: WriteAuthContext(authorization: "Bearer T0KEN")
        )
        #expect(resp.status == 403)
        let body = String(data: resp.body, encoding: .utf8) ?? ""
        #expect(body.contains("execute"))
        #expect(await runner.recentAudit(10).isEmpty)   // nothing ran
    }

    @Test func run_dryRun_allowedEvenWhenDisabled() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = try makeRunner(auditDir: dir)
        let rest = makeRest(runner: runner, executeEnabled: false)   // tier OFF
        let resp = await rest.runAction(
            id: Self.knownID, dryRun: true, capabilityToken: "",
            auth: WriteAuthContext(authorization: "Bearer T0KEN")
        )
        #expect(resp.status == 200)
        #expect(status(of: resp) == "dry")
        // A dry-run previews (no mutation) but DOES audit — it went through the
        // runner's .dryRun path, not the execute gate.
        let recent = await runner.recentAudit(10)
        #expect(recent.count == 1)
        #expect(recent[0].policyDecision == "dry_run")
    }

    @Test func run_executeEnabled_noToken_approvalRequested_notRun() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = try makeRunner(auditDir: dir)
        let recorder = ApprovalRecorder()
        let rest = makeRest(runner: runner, executeEnabled: true, recorder: recorder)
        let resp = await rest.runAction(
            id: Self.knownID, dryRun: false, capabilityToken: "",
            auth: WriteAuthContext(authorization: "Bearer T0KEN")
        )
        // 202-style approval_requested; the run happens later on the human tap.
        #expect(resp.status == 202)
        #expect(status(of: resp) == "approval_requested")
        // The approval was posted for THIS id — and NOTHING ran inline.
        #expect(await recorder.count == 1)
        #expect(await recorder.lastID == Self.knownID)
        #expect(await runner.recentAudit(10).isEmpty)
    }

    @Test func run_executeEnabled_validCapabilityToken_unattended() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = try makeRunner(auditDir: dir)
        let recorder = ApprovalRecorder()
        let rest = makeRest(
            runner: runner, executeEnabled: true,
            capabilityToken: "cap-secret", recorder: recorder
        )
        let resp = await rest.runAction(
            id: Self.knownID, dryRun: false, capabilityToken: "cap-secret",
            auth: WriteAuthContext(authorization: "Bearer T0KEN")
        )
        #expect(resp.status == 200)
        #expect(status(of: resp) == "ran")
        // Ran UNATTENDED (confirmed trigger); NO approval was posted.
        #expect(await recorder.count == 0)
        let recent = await runner.recentAudit(10)
        #expect(recent.count == 1)
        #expect(recent[0].trigger == .confirmed)
        #expect(recent[0].policyDecision == "allow")
    }

    @Test func run_invalidCapabilityToken_fallsBackToApproval_notUnattended() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = try makeRunner(auditDir: dir)
        let recorder = ApprovalRecorder()
        // Config token set, but the REQUEST presents the wrong one → must NOT run
        // unattended; falls to the human-tap gate.
        let rest = makeRest(
            runner: runner, executeEnabled: true,
            capabilityToken: "cap-secret", recorder: recorder
        )
        let resp = await rest.runAction(
            id: Self.knownID, dryRun: false, capabilityToken: "WRONG",
            auth: WriteAuthContext(authorization: "Bearer T0KEN")
        )
        #expect(resp.status == 202)
        #expect(status(of: resp) == "approval_requested")
        #expect(await recorder.count == 1)
        #expect(await runner.recentAudit(10).isEmpty)   // did NOT run
    }

    @Test func run_unknownID_404() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = try makeRunner(auditDir: dir)
        let rest = makeRest(runner: runner, executeEnabled: true)
        let resp = await rest.runAction(
            id: "does_not_exist", dryRun: false, capabilityToken: "",
            auth: WriteAuthContext(authorization: "Bearer T0KEN")
        )
        #expect(resp.status == 404)
    }

    @Test func run_allowWritesFalse_validBearer_stays403() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = try makeRunner(auditDir: dir)
        // The write master switch is independent of the Execute tier: allow_writes
        // = false ⇒ 403 even with a valid bearer AND execute_enabled true.
        let rest = makeRest(runner: runner, allowWrites: false, executeEnabled: true)
        let resp = await rest.runAction(
            id: Self.knownID, dryRun: false, capabilityToken: "",
            auth: WriteAuthContext(authorization: "Bearer T0KEN")
        )
        #expect(resp.status == 403)
        let body = String(data: resp.body, encoding: .utf8) ?? ""
        #expect(body.contains("allow_writes"))
        #expect(await runner.recentAudit(10).isEmpty)
    }

    @Test func run_dispatch_threadsHeaders_POST_actionsRun() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = try makeRunner(auditDir: dir)
        let rest = makeRest(runner: runner, executeEnabled: false)
        // Full REST dispatch path: no bearer ⇒ 401.
        let noAuth = await rest.dispatch(HTTPRequest(
            method: "POST", path: "/actions/run", query: [:], headers: [:],
            body: Data(#"{"id":"prune_apfs_snapshots","dry_run":true}"#.utf8)
        ))
        #expect(noAuth.status == 401)
        // With a bearer, a dry-run is allowed even though the tier is off.
        let dry = await rest.dispatch(HTTPRequest(
            method: "POST", path: "/actions/run", query: [:],
            headers: ["authorization": "Bearer T0KEN", "host": "127.0.0.1:39842"],
            body: Data(#"{"id":"prune_apfs_snapshots","dry_run":true}"#.utf8)
        ))
        #expect(dry.status == 200)
        #expect(status(of: dry) == "dry")
    }

    // MARK: - 2. MCP parity

    @Test func mcp_runAction_toolPresent_dryRunOK_disabledIsError() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = try makeRunner(auditDir: dir)
        let rest = makeRest(runner: runner, executeEnabled: false)
        let tools = MCPTools(rest: rest, httpBaseURL: "http://127.0.0.1:0")

        // 10 read tools + 3 write tools (ack / set_probe_config / run_action) = 13.
        let names = tools.listSchemas().compactMap { schema -> String? in
            if case .string(let n)? = schema["name"] { return n }
            return nil
        }
        #expect(names.count == 13)
        #expect(names.contains("uzora_run_action"))

        let auth = WriteAuthContext(authorization: "Bearer T0KEN")
        // dry_run:true ⇒ not an error even when the tier is disabled.
        let dry = try await tools.invoke(
            name: "uzora_run_action",
            arguments: .object(["id": .string(Self.knownID), "dry_run": .bool(true)]),
            auth: auth
        )
        #expect(Self.isError(dry) == false)

        // dry_run:false while disabled ⇒ 403 wrapped as isError.
        let real = try await tools.invoke(
            name: "uzora_run_action",
            arguments: .object(["id": .string(Self.knownID), "dry_run": .bool(false)]),
            auth: auth
        )
        #expect(Self.isError(real) == true)
    }

    @Test func mcp_runAction_noBearer_isError() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runner = try makeRunner(auditDir: dir)
        let rest = makeRest(runner: runner, executeEnabled: true)
        let tools = MCPTools(rest: rest, httpBaseURL: "http://127.0.0.1:0")
        // No auth context ⇒ 401 wrapped as isError; nothing ran.
        let denied = try await tools.invoke(
            name: "uzora_run_action",
            arguments: .object(["id": .string(Self.knownID), "dry_run": .bool(false)])
        )
        #expect(Self.isError(denied) == true)
        #expect(await runner.recentAudit(10).isEmpty)
    }

    // MARK: - 3. Config round-trip + bridge-write invariant

    @Test func config_executeFields_defaultsAndRoundTrip() throws {
        // Defaults: tier OFF, no capability token.
        #expect(UZoraConfig.default.mcp.executeEnabled == false)
        #expect(UZoraConfig.default.mcp.capabilityToken == "")

        var cfg = UZoraConfig.default
        cfg.mcp.executeEnabled = true
        cfg.mcp.capabilityToken = "sekret-cap-token"
        let toml = cfg.toTOML()
        let decoded = try UZoraConfig.fromTOML(toml)
        #expect(decoded == cfg)
        #expect(decoded.mcp.executeEnabled == true)
        #expect(decoded.mcp.capabilityToken == "sekret-cap-token")
    }

    @Test func config_bridgeWrite_cannotSetExecuteFields() async throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = try ConfigLoader(configURL: url)
        // Seed the on-disk config with the Execute tier enabled + a capability token
        // (config-only path, e.g. Settings/hand-edit).
        var seed = await loader.current
        seed.mcp.executeEnabled = true
        seed.mcp.capabilityToken = "sekret"
        try await loader.write(seed)

        // The ONLY bridge config-write path is reconfigureProbe — it has NO field
        // for the execute-tier knobs, so it can neither set nor clear them.
        let rest = RESTHandlers(state: StateStore(), configLoader: loader, bridgeAuth: BridgeAuth(token: "T0KEN"))
        let resp = await rest.reconfigureProbe(
            name: "disk", patch: .init(enabled: false),
            auth: WriteAuthContext(authorization: "Bearer T0KEN")
        )
        #expect(resp.status == 200)

        let reloaded = await loader.current
        #expect(reloaded.probes.disk.enabled == false)     // the probe write applied
        #expect(reloaded.mcp.executeEnabled == true)        // untouched by the write
        #expect(reloaded.mcp.capabilityToken == "sekret")   // untouched by the write
    }

    // MARK: - helpers

    private static func isError(_ v: JSONValue) -> Bool? {
        guard case .object(let o) = v, case .bool(let b)? = o["isError"] else { return nil }
        return b
    }
}

/// Records the human-tap approval requests posted by `RESTHandlers.runAction`.
/// An `actor` so the `@Sendable` bridge closure can mutate it safely.
private actor ApprovalRecorder {
    private(set) var calls: [(id: String, name: String)] = []
    func record(id: String, name: String) { calls.append((id, name)) }
    var count: Int { calls.count }
    var lastID: String? { calls.last?.id }
}

/// A no-side-effect fake action so B2 confirmed/unattended runs never touch the
/// real machine (mirrors ActionRunnerTests' fake).
private struct FakeRunAction: Action {
    let descriptor: ActionDescriptor
    init(id: String) {
        self.descriptor = ActionDescriptor(
            id: id, name: "Fake cleanup", detail: "fake", reversible: true,
            requiresSudo: false, relatedProbe: "disk", relatedSeverityFloor: .warn
        )
    }
    func dryRun() async -> ActionPreview {
        ActionPreview(actionID: descriptor.id, estimatedFreedBytes: 42, summary: "would free ~42B")
    }
    func execute() async -> ActionResult {
        ActionResult(actionID: descriptor.id, succeeded: true, skipped: false,
                     freedBytes: 42, beforeFreeBytes: 0, afterFreeBytes: 42)
    }
}
