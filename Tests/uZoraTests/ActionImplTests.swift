import Testing
import Foundation
@testable import uZora

@Suite("Action implementations — dry-run + execute")
struct ActionImplTests {

    /// A temp directory strictly under the user home (the path guard requires
    /// deletion roots to be under home).
    private func tempRootUnderHome(prefix: String) throws -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let base = home
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func clearDescriptor(id: String = "clear_user_caches", caution: Bool = true) -> ActionDescriptor {
        ActionDescriptor(id: id, name: "n", detail: "d", reversible: true, requiresSudo: false,
                         caution: caution, relatedProbe: "disk", relatedSeverityFloor: .warn)
    }

    // MARK: - ClearDirectoryAction: dry-run does NOT mutate

    @Test func clearDir_dryRun_doesNotMutate() async throws {
        let root = try tempRootUnderHome(prefix: "uzora-impl-dry")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x41, count: 4096).write(to: root.appendingPathComponent("f1"))
        try Data(repeating: 0x42, count: 4096).write(to: root.appendingPathComponent("f2"))

        let action = ClearDirectoryAction(descriptor: clearDescriptor()) { root }
        let preview = await action.dryRun()
        #expect(preview.actionID == "clear_user_caches")
        #expect(preview.skipped == false)
        #expect(preview.estimatedFreedBytes > 0)
        // Files MUST still be present after a dry-run (no mutation).
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("f1").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("f2").path))
    }

    @Test func clearDir_dryRun_missingDir_isSkip() async throws {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let ghost = home.appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("uzora-impl-ghost-\(UUID().uuidString)", isDirectory: true)
        let action = ClearDirectoryAction(descriptor: clearDescriptor()) { ghost }
        let preview = await action.dryRun()
        #expect(preview.skipped == true)
        #expect(preview.estimatedFreedBytes == 0)
    }

    // MARK: - ClearDirectoryAction: execute deletes contents (in isolation)

    @Test func clearDir_execute_removesContents() async throws {
        let root = try tempRootUnderHome(prefix: "uzora-impl-exec")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x41, count: 10_000).write(to: root.appendingPathComponent("a"))
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 10_000).write(to: sub.appendingPathComponent("b"))

        let action = ClearDirectoryAction(descriptor: clearDescriptor()) { root }
        let result = await action.execute()
        #expect(result.succeeded == true)
        #expect(result.skipped == false)
        #expect(result.error == nil)
        // Contents gone, root remains.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
        #expect(!FileManager.default.fileExists(atPath: sub.path))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func clearDir_execute_refusesUnsafeRoot_noDeletion() async throws {
        // Point the action at the HOME dir — execute must refuse via the
        // guard and NOT delete anything (succeeded=false, error set).
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let action = ClearDirectoryAction(descriptor: clearDescriptor()) { home }
        let result = await action.execute()
        #expect(result.succeeded == false)
        #expect(result.skipped == true)
        #expect(result.freedBytes == 0)
        #expect(result.error?.contains("path-guard refused") == true)
        // Home obviously still exists.
        #expect(FileManager.default.fileExists(atPath: home.path))
    }

    // MARK: - ShellCommandAction: brew skip when absent

    @Test func brewCleanup_skipsGracefully_whenBrewAbsent() async {
        let desc = ActionDescriptor(id: "brew_cleanup", name: "n", detail: "d", reversible: true,
                                    requiresSudo: false, relatedProbe: "disk", relatedSeverityFloor: .warn)
        let action = ShellCommandAction(
            descriptor: desc, kind: .brewCleanup,
            runner: { _ in ActionShell.ProcessOutcome(exitCode: 0, stdout: "", stderr: "", launched: true) },
            resolve: { _ in nil },          // brew NOT found
            freeBytes: { 1000 }
        )
        let preview = await action.dryRun()
        #expect(preview.skipped == true)
        let result = await action.execute()
        #expect(result.skipped == true)
        #expect(result.succeeded == true)   // a graceful skip is not a failure
        #expect(result.freedBytes == 0)
    }

    @Test func brewCleanup_runsAndMeasuresFreed_whenPresent() async {
        let desc = ActionDescriptor(id: "brew_cleanup", name: "n", detail: "d", reversible: true,
                                    requiresSudo: false, relatedProbe: "disk", relatedSeverityFloor: .warn)
        // Inject: brew resolves, runner succeeds, free goes 1000 → 5000.
        let freeSeq = FreeSeq([1000, 5000])
        let action = ShellCommandAction(
            descriptor: desc, kind: .brewCleanup,
            runner: { argv in
                // The argv should end in "cleanup".
                #expect(argv.last == "cleanup")
                return ActionShell.ProcessOutcome(exitCode: 0, stdout: "==> done", stderr: "", launched: true)
            },
            resolve: { name in name == "brew" ? "/opt/homebrew/bin/brew" : nil },
            freeBytes: { freeSeq.next() }
        )
        let result = await action.execute()
        #expect(result.succeeded == true)
        #expect(result.skipped == false)
        #expect(result.beforeFreeBytes == 1000)
        #expect(result.afterFreeBytes == 5000)
        #expect(result.freedBytes == 4000)
    }

    @Test func brewCleanup_nonZeroExit_isFailure() async {
        let desc = ActionDescriptor(id: "brew_cleanup", name: "n", detail: "d", reversible: true,
                                    requiresSudo: false, relatedProbe: "disk", relatedSeverityFloor: .warn)
        let action = ShellCommandAction(
            descriptor: desc, kind: .brewCleanup,
            runner: { _ in ActionShell.ProcessOutcome(exitCode: 1, stdout: "", stderr: "boom", launched: true) },
            resolve: { _ in "/opt/homebrew/bin/brew" },
            freeBytes: { 1000 }
        )
        let result = await action.execute()
        #expect(result.succeeded == false)
        #expect(result.error?.contains("boom") == true)
    }

    // MARK: - ShellCommandAction: prune smoke (injected)

    @Test func pruneSnapshots_smoke_injectedRunner() async {
        let desc = ActionRegistry.Descriptors.pruneApfsSnapshots
        let freeSeq = FreeSeq([2000, 9000])
        let action = ShellCommandAction(
            descriptor: desc, kind: .pruneSnapshots,
            runner: { argv in
                #expect(argv.contains("deletelocalsnapshots"))
                return ActionShell.ProcessOutcome(exitCode: 0, stdout: "Deleted local snapshots", stderr: "", launched: true)
            },
            resolve: { name in name.contains("tmutil") ? "/usr/bin/tmutil" : nil },
            freeBytes: { freeSeq.next() }
        )
        let result = await action.execute()
        #expect(result.succeeded == true)
        #expect(result.freedBytes == 7000)
    }
}

/// Returns a scripted sequence of free-byte values across calls (for
/// before/after deltas). Repeats the last value if exhausted.
private final class FreeSeq: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]
    private var idx = 0
    init(_ v: [UInt64]) { values = v }
    func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let v = values[min(idx, values.count - 1)]
        idx += 1
        return v
    }
}
