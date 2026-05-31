import Foundation
import os

/// The two shell-tool actions that delegate the actual cleanup to a trusted
/// system binary rather than touching files directly:
///
///  - `prune_apfs_snapshots` → `tmutil deletelocalsnapshots /`
///  - `brew_cleanup`         → `brew cleanup`  (no-op/skip if brew absent)
///
/// These don't go through `ActionPathGuard` because they don't enumerate or
/// `removeItem` any path themselves — `tmutil` / `brew` own their deletion
/// safety. uZora only invokes a FIXED argv (no shell string interpolation)
/// to a resolved binary and measures the boot-volume free-space delta for
/// the freed-bytes figure.
public struct ShellCommandAction: Action {

    public let descriptor: ActionDescriptor

    /// What kind of command this is — drives binary resolution + the
    /// graceful-skip behaviour (brew may be absent).
    public enum Kind: Sendable {
        case pruneSnapshots
        case brewCleanup
    }
    private let kind: Kind
    /// Injectable runner so tests can stub the process without spawning
    /// `tmutil` / `brew` (which mutate the real machine).
    private let runner: @Sendable ([String]) -> ActionShell.ProcessOutcome
    /// Injectable binary resolver (tests pretend brew is present/absent).
    private let resolve: @Sendable (String) -> String?
    /// Injectable disk-free sampler (tests assert freed = after - before).
    private let freeBytes: @Sendable () -> UInt64

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "action-shell-cmd")

    public init(
        descriptor: ActionDescriptor,
        kind: Kind,
        runner: @escaping @Sendable ([String]) -> ActionShell.ProcessOutcome = { ActionShell.run($0) },
        resolve: @escaping @Sendable (String) -> String? = { ActionShell.resolveBinary($0) },
        freeBytes: @escaping @Sendable () -> UInt64 = { ActionShell.bootVolumeFreeBytes() }
    ) {
        self.descriptor = descriptor
        self.kind = kind
        self.runner = runner
        self.resolve = resolve
        self.freeBytes = freeBytes
    }

    // MARK: - Argv

    /// Resolve the fixed argv for this command, or nil if the binary is not
    /// present (brew on a machine without Homebrew).
    private func argv() -> [String]? {
        switch kind {
        case .pruneSnapshots:
            // tmutil ships with macOS at a fixed path.
            guard let bin = resolve("/usr/bin/tmutil") ?? resolve("tmutil") else { return nil }
            return [bin, "deletelocalsnapshots", "/"]
        case .brewCleanup:
            guard let bin = resolve("brew") else { return nil }
            return [bin, "cleanup"]
        }
    }

    // MARK: - Action

    public func dryRun() async -> ActionPreview {
        guard let cmd = argv() else {
            return ActionPreview(
                actionID: descriptor.id,
                estimatedFreedBytes: 0,
                summary: skipSummary,
                skipped: true,
                note: skipNote
            )
        }
        // We can't reliably predict freed bytes without running the tool
        // (tmutil/brew don't expose a stable dry-run byte count), so the
        // preview is a description of the command, estimate 0 (unknown).
        let printable = cmd.map { ($0 as NSString).lastPathComponent }.joined(separator: " ")
        return ActionPreview(
            actionID: descriptor.id,
            estimatedFreedBytes: 0,
            summary: "Would run: \(printable)",
            note: "freed bytes are measured after the run (tool has no stable dry-run size)"
        )
    }

    public func execute() async -> ActionResult {
        let before = freeBytes()
        guard let cmd = argv() else {
            // Graceful skip — e.g. brew not installed. Not an error.
            log.info("\(descriptor.id, privacy: .public): \(skipNote, privacy: .public)")
            return ActionResult.skipped(descriptor.id, freeBytes: before)
        }
        let outcome = runner(cmd)
        let after = freeBytes()
        let freed = after >= before ? after - before : 0
        if !outcome.launched {
            return ActionResult(
                actionID: descriptor.id,
                succeeded: false,
                skipped: true,
                freedBytes: 0,
                beforeFreeBytes: before,
                afterFreeBytes: before,
                error: outcome.stderr.isEmpty ? "command could not be launched" : outcome.stderr
            )
        }
        let ok = outcome.exitCode == 0
        log.info("\(descriptor.id, privacy: .public): exit=\(outcome.exitCode, privacy: .public), freed≈\(freed, privacy: .public) bytes")
        return ActionResult(
            actionID: descriptor.id,
            succeeded: ok,
            skipped: false,
            freedBytes: freed,
            beforeFreeBytes: before,
            afterFreeBytes: after,
            error: ok ? nil : trimmedError(outcome)
        )
    }

    // MARK: - Skip messaging

    private var skipSummary: String {
        switch kind {
        case .pruneSnapshots: return "Would not run: tmutil not available"
        case .brewCleanup:    return "Would not run: Homebrew is not installed"
        }
    }
    private var skipNote: String {
        switch kind {
        case .pruneSnapshots: return "tmutil not found on PATH"
        case .brewCleanup:    return "brew not found on PATH (Homebrew not installed)"
        }
    }
    private func trimmedError(_ o: ActionShell.ProcessOutcome) -> String {
        let s = (o.stderr.isEmpty ? o.stdout : o.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "exit code \(o.exitCode)" : String(s.prefix(500))
    }
}
