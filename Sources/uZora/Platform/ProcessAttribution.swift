import Foundation
import os

/// One named process, as resolved by the gated Tier-B `/bin/ps` snapshot.
///
/// This is the discriminating value type for the **only no-sudo route** to
/// name cross-uid `/System` daemons (the seed-incident culprits
/// `ecosystemd` / `ecosystemanalyticsd`). uZora's own `ProcessSampler`
/// (libproc `proc_pid_rusage`) returns **EPERM** for any different-uid
/// process — see the feasibility analysis §0 — so own-uid apps are nameable
/// in-process but root/`_windowserver` daemons are not. `/bin/ps` is
/// setuid-root and carries `com.apple.system-task-ports.read`; it
/// self-elevates and we parse its stdout.
public struct AttributedProcess: Sendable, Equatable, Hashable {
    /// Process id.
    public let pid: Int32
    /// Owning uid (0 = root, 88 = `_windowserver`, …).
    public let uid: UInt32
    /// Executable basename (last path component of `path`).
    public let command: String
    /// Full executable path (the Darwin `ps comm=` column).
    public let path: String
    /// Cumulative CPU time since process start, in seconds (parsed from the
    /// `ps` `TIME` column). This is the lifetime-CPU signal the seed incident
    /// keys on (an `ecosystemd` busy-loop accrues tens of hours of CPU), NOT
    /// an instantaneous percentage.
    public let cpuSeconds: Double
    /// True when `path` is under a system prefix (`/System`, `/usr/libexec`,
    /// `/usr/sbin`) — i.e. an OS daemon rather than a user tool.
    public let isSystem: Bool

    public init(
        pid: Int32,
        uid: UInt32,
        command: String,
        path: String,
        cpuSeconds: Double,
        isSystem: Bool
    ) {
        self.pid = pid
        self.uid = uid
        self.command = command
        self.path = path
        self.cpuSeconds = cpuSeconds
        self.isSystem = isSystem
    }
}

/// The gated Tier-B `/bin/ps` attribution bridge.
///
/// Everything here is a **pure function** except the single impure
/// `snapshotViaPS()`, which launches `/bin/ps` and parses its output. The
/// `DiagnosisEngine` calls `snapshotViaPS()` at most once per cycle, and only
/// when a detector's `wantsAttribution(_:)` says a Tier-A trigger is hot
/// (cores pinned, sustained) — keeping the ~80 ms shell-out rare. Detectors
/// themselves never call it; they read `DiagnosisContext.attributedProcesses`.
public enum ProcessAttribution {

    static let log = Logger(subsystem: "place.unicorns.uzora", category: "process-attribution")

    // MARK: - Suppression allowlist (D7)

    /// Basenames of legitimately-bursty system daemons that must NEVER be
    /// flagged as a runaway, even when sustained on CPU: the indexing/backup
    /// family. Spotlight metadata indexing (`mds*`) and Time Machine
    /// (`backupd*`) routinely pin a core for minutes during legitimate work.
    ///
    /// Deliberately SMALL and conservative (plan D7): we do NOT suppress
    /// `ecosystemd` / `ecosystemanalyticsd` — those are the seed culprit and
    /// the entire target of this detector. A curated wider fingerprint list
    /// is a v1.x growth path, not v1.
    public static let suppressionAllowlist: Set<String> = [
        "mds",
        "mds_stores",
        "mdworker",
        "mdworker_shared",
        "mdbulkimport",
        "backupd",
        "backupd-helper",
        "Spotlight",
    ]

    // MARK: - Pure parsing helpers

    /// Parse a `ps` `TIME` column to cumulative seconds. PURE.
    ///
    /// `ps` emits CPU time in several shapes depending on magnitude:
    ///  - `"SS.ss"`               — seconds (sub-minute)
    ///  - `"MM:SS.ss"`            — minutes:seconds
    ///  - `"HH:MM:SS"` / `"HH:MM:SS.ss"` — hours:minutes:seconds
    ///  - `"D-HH:MM:SS"`          — days-hours:minutes:seconds (long-lived procs)
    ///
    /// Returns `nil` on anything that doesn't parse cleanly (so a malformed
    /// row is skipped rather than scored). Testable with fixtures.
    public static func parseCPUTime(_ s: String) -> Double? {
        let raw = s.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }

        // Optional leading day component: "D-HH:MM:SS".
        var days = 0.0
        var rest = Substring(raw)
        if let dash = rest.firstIndex(of: "-") {
            let dayPart = rest[rest.startIndex..<dash]
            guard let d = Double(dayPart), d >= 0 else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }

        // Remaining is colon-separated H:M:S / M:S / S, with the last field
        // possibly fractional. 1–3 fields only.
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }

        var seconds = 0.0
        // Walk fields most- to least-significant, multiplying by 60 each step.
        for (i, part) in parts.enumerated() {
            guard let v = Double(part), v >= 0 else { return nil }
            // Only the LAST field may be fractional; intermediate fields must
            // be whole and < 60 to be a sane sexagesimal component. We don't
            // hard-reject >= 60 on the leading field (e.g. "MM" can exceed 59
            // when ps is given a minutes-only context), but intermediate
            // fields between a leading and trailing one should be < 60.
            if i > 0 && i < parts.count - 1 {
                guard v < 60 else { return nil }
            }
            seconds = seconds * 60.0 + v
        }
        return days * 86_400.0 + seconds
    }

    /// True if `path` is under a system executable prefix — an OS daemon, not
    /// a user tool. Per the feasibility analysis §1: `/System/`,
    /// `/usr/libexec/`, `/usr/sbin/`. Deliberately NOT `/usr/bin` (user CLI
    /// tools live there). PURE.
    public static func isSystemPath(_ path: String) -> Bool {
        path.hasPrefix("/System/")
            || path.hasPrefix("/usr/libexec/")
            || path.hasPrefix("/usr/sbin/")
    }

    /// True if `command` (a basename) is on the suppression allowlist. PURE.
    public static func isSuppressed(command: String) -> Bool {
        suppressionAllowlist.contains(command)
    }

    /// Parse the full output of
    /// `ps -axo pid=,uid=,time=,comm=` into `AttributedProcess` rows. PURE.
    ///
    /// With `=` field-suffixes `ps` prints NO header. Each line is
    /// `pid uid time comm`, whitespace-separated, where `comm` is the full
    /// executable path on Darwin (and may itself contain spaces, so it is
    /// taken as "everything after the first three columns"). Malformed lines
    /// (missing columns, unparsable pid/uid/time) are skipped. Testable with
    /// a fixture string.
    public static func parse(psOutput: String) -> [AttributedProcess] {
        var out: [AttributedProcess] = []
        for rawLine in psOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // First three whitespace-runs are pid, uid, time; the rest
            // (rejoined) is the comm path. Use a manual scan so a path with
            // embedded spaces survives intact.
            let firstThree = line.split(
                separator: " ",
                maxSplits: 3,
                omittingEmptySubsequences: true
            )
            guard firstThree.count == 4 else { continue }

            guard let pid = Int32(firstThree[0]) else { continue }
            guard let uid = UInt32(firstThree[1]) else { continue }
            guard let cpuSeconds = parseCPUTime(String(firstThree[2])) else { continue }

            let path = firstThree[3].trimmingCharacters(in: .whitespaces)
            if path.isEmpty { continue }
            let command = (path as NSString).lastPathComponent
            if command.isEmpty { continue }

            out.append(AttributedProcess(
                pid: pid,
                uid: uid,
                command: command,
                path: path,
                cpuSeconds: cpuSeconds,
                isSystem: isSystemPath(path)
            ))
        }
        return out
    }

    /// The top nameable **system** offender: the process that is a system
    /// daemon, NOT on the suppression allowlist, AND has accrued at least
    /// `minCPUSeconds` of cumulative CPU — picking the one with the highest
    /// `cpuSeconds`. Returns `nil` when nothing qualifies. PURE.
    ///
    /// Note: this is a single-snapshot CUMULATIVE-CPU heuristic, not a rate.
    /// It is correct for the seed class (a multi-day busy-loop accrues a huge
    /// lifetime CPU total) precisely because the Tier-A trigger has ALREADY
    /// confirmed cores are pinned *right now* — so a daemon with a large
    /// cumulative total is, in that gated context, the live offender. A
    /// long-lived-but-currently-idle daemon could in principle carry a large
    /// total; gating behind the sustained-pin trigger is what makes the
    /// single-snapshot total a sound attribution. (A two-snapshot rate is a
    /// v1.x refinement.)
    public static func topSystemOffender(
        _ procs: [AttributedProcess],
        minCPUSeconds: Double
    ) -> AttributedProcess? {
        procs
            .filter { $0.isSystem && !isSuppressed(command: $0.command) && $0.cpuSeconds >= minCPUSeconds }
            .max { $0.cpuSeconds < $1.cpuSeconds }
    }

    // MARK: - Impure snapshot (the ONLY I/O)

    /// Launch `/bin/ps -axo pid=,uid=,time=,comm=`, read stdout, and parse.
    /// Returns `nil` on launch/read failure (so the detector abstains →
    /// "unnamed slowdown" rather than silence — D7 graceful degradation).
    ///
    /// Kept plain + synchronous (no actor/MainActor hazard) for the macOS-15
    /// CI cross-SDK build. A read deadline guards against a hung `ps`.
    public static func snapshotViaPS(now: Date = Date()) -> [AttributedProcess]? {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,uid=,time=,comm="]

        let stdout = Pipe()
        process.standardOutput = stdout
        // Discard stderr so a warning can't block on a full pipe.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log.error("snapshotViaPS launch failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        // Read to EOF (`ps` writes the whole table then exits). Reading the
        // pipe to end-of-file naturally bounds us to `ps`'s lifetime; the
        // full process table measured ~60–100 ms in the feasibility analysis.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            log.error("snapshotViaPS: /bin/ps exited \(process.terminationStatus, privacy: .public)")
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            log.error("snapshotViaPS: /bin/ps output was not UTF-8")
            return nil
        }
        return parse(psOutput: text)
    }
}
