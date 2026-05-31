import Testing
import Foundation
@testable import uZora

@Suite("ActionRunner — registry × policy × audit integration")
struct ActionRunnerTests {

    private func tempAuditDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-runner-tests-\(UUID().uuidString)", isDirectory: true)
    }

    /// A registry holding a single injectable fake action so the runner test
    /// doesn't touch the real machine.
    private func fakeRegistry(id: String = "prune_apfs_snapshots", reversible: Bool = true) -> ActionRegistry {
        ActionRegistry(actions: [FakeAction(id: id, reversible: reversible)])
    }

    private func ctx(_ config: ActionsConfig, power: PowerState = .acConnectedLidOpen, focus: Bool = false) -> PolicyEngine.Context {
        PolicyEngine.Context(powerState: power, focusActive: focus, config: config)
    }

    @Test func run_confirmed_executes_andAudits() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try AuditLog(baseDir: dir, retentionDays: 30)
        let runner = ActionRunner(
            registry: fakeRegistry(),
            policy: PolicyEngine(),
            audit: audit,
            contextProvider: { [self] in ctx(ActionsConfig()) } // all auto OFF
        )
        // Confirmed bypasses the (default off) enabled gate.
        let outcome = await runner.run(actionID: "prune_apfs_snapshots", trigger: .confirmed)
        #expect(outcome.decision == .allow)
        #expect(outcome.result?.succeeded == true)
        let recent = await audit.recent(10)
        #expect(recent.count == 1)
        #expect(recent[0].trigger == .confirmed)
        #expect(recent[0].policyDecision == "allow")
        await audit.close()
    }

    @Test func run_auto_deniedWhenNotOptedIn_andAuditsDeny() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try AuditLog(baseDir: dir, retentionDays: 30)
        let runner = ActionRunner(
            registry: fakeRegistry(),
            policy: PolicyEngine(),
            audit: audit,
            contextProvider: { [self] in ctx(ActionsConfig()) }
        )
        let outcome = await runner.run(actionID: "prune_apfs_snapshots", trigger: .auto)
        #expect(outcome.decision == .deny(.notEnabled))
        #expect(outcome.result == nil)
        let recent = await audit.recent(10)
        #expect(recent.count == 1)
        #expect(recent[0].policyDecision == "deny:not_enabled")
        await audit.close()
    }

    @Test func run_auto_executesWhenOptedIn() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try AuditLog(baseDir: dir, retentionDays: 30)
        let cfg: ActionsConfig = {
            var c = ActionsConfig()
            c.setOverride(ActionOverride(autoEnabled: true), for: "prune_apfs_snapshots")
            return c
        }()
        let runner = ActionRunner(
            registry: fakeRegistry(),
            policy: PolicyEngine(),
            audit: audit,
            contextProvider: { [self] in ctx(cfg) }
        )
        let outcome = await runner.run(actionID: "prune_apfs_snapshots", trigger: .auto)
        #expect(outcome.decision == .allow)
        #expect(outcome.result?.succeeded == true)
        await audit.close()
    }

    @Test func handleAlertEvent_autoPath_inertWhenAllOff() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try AuditLog(baseDir: dir, retentionDays: 30)
        // Real registry (4 actions, all → disk). All auto OFF (default).
        let runner = ActionRunner(
            registry: ActionRegistry.defaultPopulated(),
            policy: PolicyEngine(),
            audit: audit,
            contextProvider: { [self] in ctx(ActionsConfig()) }
        )
        let alert = Alert(probe: "disk", key: "/", severity: .critical, message: "full",
                          firstSeen: Date(), lastUpdated: Date())
        await runner.handleAlertEvent(.appeared(alert))
        // Nothing opted in → nothing ran → no audit entries (the runner skips
        // evaluation for not-opted-in actions to avoid deny spam).
        #expect(await audit.recordedCount == 0)
        await audit.close()
    }

    @Test func handleAlertEvent_runsOnlyOptedInMappedAction() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try AuditLog(baseDir: dir, retentionDays: 30)
        let cfg: ActionsConfig = {
            var c = ActionsConfig()
            // Opt in exactly ONE of the four.
            c.setOverride(ActionOverride(autoEnabled: true), for: "brew_cleanup")
            return c
        }()
        let runner = ActionRunner(
            registry: ActionRegistry.defaultPopulated(),
            policy: PolicyEngine(),
            audit: audit,
            contextProvider: { [self] in ctx(cfg) }
        )
        let alert = Alert(probe: "disk", key: "/", severity: .warn, message: "low",
                          firstSeen: Date(), lastUpdated: Date())
        await runner.handleAlertEvent(.appeared(alert))
        let recent = await audit.recent(10)
        // Only brew_cleanup attempted (it skips gracefully if brew absent, but
        // either way it AUDITS exactly once; the other 3 are not opted in).
        #expect(recent.count == 1)
        #expect(recent[0].actionID == "brew_cleanup")
        await audit.close()
    }

    @Test func handleAlertEvent_clearedIgnored() async throws {
        let dir = tempAuditDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let audit = try AuditLog(baseDir: dir, retentionDays: 30)
        let cfg: ActionsConfig = {
            var c = ActionsConfig()
            c.setOverride(ActionOverride(autoEnabled: true), for: "brew_cleanup")
            return c
        }()
        let runner = ActionRunner(
            registry: ActionRegistry.defaultPopulated(),
            policy: PolicyEngine(),
            audit: audit,
            contextProvider: { [self] in ctx(cfg) }
        )
        await runner.handleAlertEvent(.cleared("disk:/"))
        #expect(await audit.recordedCount == 0)
        await audit.close()
    }
}

/// A no-side-effect fake action for runner integration tests.
private struct FakeAction: Action {
    let descriptor: ActionDescriptor
    init(id: String, reversible: Bool) {
        self.descriptor = ActionDescriptor(
            id: id, name: "fake", detail: "fake", reversible: reversible,
            requiresSudo: false, relatedProbe: "disk", relatedSeverityFloor: .warn
        )
    }
    func dryRun() async -> ActionPreview {
        ActionPreview(actionID: descriptor.id, estimatedFreedBytes: 123, summary: "would do nothing")
    }
    func execute() async -> ActionResult {
        ActionResult(actionID: descriptor.id, succeeded: true, skipped: false,
                     freedBytes: 123, beforeFreeBytes: 0, afterFreeBytes: 123)
    }
}
