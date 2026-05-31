import Foundation
import Darwin
import os

/// Shared helpers for the action implementations: boot-volume free-space
/// sampling (reuses `DiskFreeProbe.sampleRoot()`) and a minimal,
/// loopback-safe `Process` runner for the two shell actions (`tmutil`,
/// `brew`). No external dependencies — Foundation `Process` only.
///
/// Security posture: actions NEVER pass user-controlled strings to a shell.
/// Commands are fixed argv arrays to known absolute or PATH-resolved
/// binaries; there is no `/bin/sh -c` string interpolation anywhere.
public enum ActionShell {

    static let log = Logger(subsystem: "place.unicorns.uzora", category: "action-shell")

    /// Boot-volume free bytes right now (`statfs("/")` via DiskFreeProbe).
    /// Returns 0 if the syscall fails (shouldn't on a running OS).
    public static func bootVolumeFreeBytes() -> UInt64 {
        DiskFreeProbe.sampleRoot()?.freeBytes ?? 0
    }

    /// Result of running a child process.
    public struct ProcessOutcome: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public let launched: Bool   // false if the binary couldn't be spawned
    }

    /// Resolve a binary on a conservative PATH (so `brew` is found whether on
    /// Apple-Silicon `/opt/homebrew/bin` or Intel `/usr/local/bin`, without
    /// inheriting the user's arbitrary PATH). Returns nil if not found.
    public static func resolveBinary(_ name: String) -> String? {
        // Absolute path passed straight through.
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        let searchDirs = [
            "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        for dir in searchDirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Run a fixed argv (first element is the resolved binary path) and
    /// capture stdout/stderr. Synchronous (callers wrap in their async
    /// `execute()`); times out conceptually via the OS — these commands are
    /// short. Returns `launched == false` if the binary path is invalid.
    public static func run(_ argv: [String], timeoutSeconds: Double = 120) -> ProcessOutcome {
        guard let first = argv.first, FileManager.default.isExecutableFile(atPath: first) else {
            return ProcessOutcome(exitCode: -1, stdout: "", stderr: "binary not executable", launched: false)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: first)
        process.arguments = Array(argv.dropFirst())
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Minimal, deterministic environment — don't inherit the user's PATH
        // or locale into the child.
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]

        do {
            try process.run()
        } catch {
            return ProcessOutcome(exitCode: -1, stdout: "", stderr: "spawn failed: \(error)", launched: false)
        }

        // Read pipes fully then wait, to avoid a deadlock on a full pipe
        // buffer for chatty commands.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessOutcome(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            launched: true
        )
    }
}
