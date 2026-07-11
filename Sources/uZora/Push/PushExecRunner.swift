import Foundation
import os

/// The local-agent-exec push backend's run primitive (plan B3, backend #1).
///
/// A protocol so `ProactivePush` can be unit-tested with a mock that RECORDS
/// the argv instead of spawning a real `claude` process. The producer always
/// hands the FULLY-BUILT argv (`exec_argv + [summary]`); this type just runs it.
public protocol PushExecRunning: Sendable {
    /// Run the fixed argv and return the process outcome. `argv[0]` is the
    /// command NAME or absolute path; the remaining tokens are literal
    /// arguments (the last one is the event summary — a single token).
    func run(argv: [String], timeoutSeconds: Double) async -> ActionShell.ProcessOutcome
}

/// Production local-exec backend: resolves `argv[0]` on the conservative
/// `ActionShell` PATH (so a bare `"claude"` is found on Apple-Silicon or Intel
/// Homebrew), then runs the fixed argv via `ActionShell.run` — the SAME
/// zero-shell primitive the Q10 actions use.
///
/// **No shell, ever.** The summary is already one element of `argv`; `ActionShell`
/// sets it as a literal `Process.arguments` entry — there is no `/bin/sh -c`, no
/// string interpolation, so a summary containing `;`, quotes, `$(…)`, or newlines
/// is passed to the child as a single inert argument. The blocking spawn/wait is
/// offloaded to a detached task so it never wedges the `ProactivePush` actor.
public struct ActionShellPushRunner: PushExecRunning {

    private static let log = Logger(subsystem: "place.unicorns.uzora", category: "push-exec")

    public init() {}

    public func run(argv: [String], timeoutSeconds: Double) async -> ActionShell.ProcessOutcome {
        // Offload the blocking `ActionShell.run` (spawn + waitUntilExit) to a
        // detached task so awaiting it merely SUSPENDS the push actor (which
        // stays free to process other events) rather than blocking a thread.
        await Task.detached(priority: .utility) {
            guard let first = argv.first, !first.isEmpty else {
                return ActionShell.ProcessOutcome(exitCode: -1, stdout: "", stderr: "empty argv", launched: false)
            }
            // Resolve the command to an executable path (a bare name like
            // "claude" isn't executable-at-path until resolved on the ActionShell
            // PATH). `ActionShell.run` requires argv[0] be an executable path.
            guard let resolved = ActionShell.resolveBinary(first) else {
                return ActionShell.ProcessOutcome(exitCode: -1, stdout: "", stderr: "command not found: \(first)", launched: false)
            }
            var fixed = argv
            fixed[0] = resolved
            // v1: fire-and-forget — the LLM's RESPONSE (stdout) is discarded;
            // only the launch/exit outcome is captured for the audit.
            return ActionShell.run(fixed, timeoutSeconds: timeoutSeconds)
        }.value
    }
}
