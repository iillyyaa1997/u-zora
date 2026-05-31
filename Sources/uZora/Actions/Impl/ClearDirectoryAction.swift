import Foundation
import os

/// Destructive cache-cleanup actions that remove the *contents* of a single
/// documented directory: `clear_derived_data` and `clear_user_caches`.
///
/// Both share this implementation, parameterised by the target root, because
/// the dangerous part — deleting files — is identical and MUST go through the
/// SAME `ActionPathGuard` chokepoint:
///
///  - `clear_derived_data` → `~/Library/Developer/Xcode/DerivedData`
///  - `clear_user_caches`  → `~/Library/Caches` (flagged CAUTION)
///
/// The target root is injectable so `ActionPathGuardTests` / dry-run tests
/// can point it at a temp directory. In production it resolves under the user
/// home. `execute()` NEVER deletes the root itself — only its top-level
/// entries, each re-validated + removed by lexical path so a symlink entry is
/// unlinked rather than followed (see `ActionPathGuard.removeContents`).
public struct ClearDirectoryAction: Action {

    public let descriptor: ActionDescriptor
    /// The directory whose contents are cleared. Resolved lazily so the
    /// home-relative default reflects the real `NSHomeDirectory()` at call
    /// time (tests inject an explicit URL).
    private let targetRoot: @Sendable () -> URL

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "action-clear")

    public init(descriptor: ActionDescriptor, targetRoot: @escaping @Sendable () -> URL) {
        self.descriptor = descriptor
        self.targetRoot = targetRoot
    }

    // MARK: - Factories for the two MVP actions

    /// `~/Library/Developer/Xcode/DerivedData`
    public static func derivedData(descriptor: ActionDescriptor) -> ClearDirectoryAction {
        ClearDirectoryAction(descriptor: descriptor) {
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        }
    }

    /// `~/Library/Caches`
    public static func userCaches(descriptor: ActionDescriptor) -> ClearDirectoryAction {
        ClearDirectoryAction(descriptor: descriptor) {
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Caches", isDirectory: true)
        }
    }

    // MARK: - Action

    public func dryRun() async -> ActionPreview {
        let root = targetRoot()
        // Validate the root the SAME way execute() will — if it's unsafe or
        // doesn't exist, report a skip rather than estimate a delete.
        switch ActionPathGuard.validateRoot(root) {
        case .failure(let why):
            return ActionPreview(
                actionID: descriptor.id,
                estimatedFreedBytes: 0,
                summary: "Would not run: \(why.description)",
                skipped: true,
                note: why.description
            )
        case .success(let canonicalRoot):
            let url = URL(fileURLWithPath: canonicalRoot, isDirectory: true)
            let exists = FileManager.default.fileExists(atPath: canonicalRoot)
            if !exists {
                return ActionPreview(
                    actionID: descriptor.id,
                    estimatedFreedBytes: 0,
                    summary: "Nothing to clear (\(url.lastPathComponent) does not exist)",
                    skipped: true
                )
            }
            // Estimate freed = total recursive size of the directory contents
            // (excluding symlinks). No mutation.
            let estimate = ActionPathGuard.directorySize(of: url)
            return ActionPreview(
                actionID: descriptor.id,
                estimatedFreedBytes: estimate,
                summary: "Would clear contents of \(url.lastPathComponent) (~\(ActionFormat.bytes(estimate)))"
            )
        }
    }

    public func execute() async -> ActionResult {
        let before = ActionShell.bootVolumeFreeBytes()
        let root = targetRoot()
        do {
            let (bytesRemoved, entriesRemoved) = try ActionPathGuard.removeContents(of: root)
            let after = ActionShell.bootVolumeFreeBytes()
            // Prefer the guard's measured bytesRemoved (it walked the tree
            // before deletion); fall back to the before/after delta. The
            // statfs delta can be noisy (other processes) so use the larger
            // signal as the headline freed figure when both are available.
            let freed = max(bytesRemoved, after >= before ? after - before : 0)
            let skipped = entriesRemoved == 0
            log.info("\(descriptor.id, privacy: .public): removed \(entriesRemoved, privacy: .public) entr\(entriesRemoved == 1 ? "y" : "ies", privacy: .public), ~\(freed, privacy: .public) bytes")
            return ActionResult(
                actionID: descriptor.id,
                succeeded: true,
                skipped: skipped,
                freedBytes: freed,
                beforeFreeBytes: before,
                afterFreeBytes: after
            )
        } catch let refusal as ActionPathGuard.Refusal {
            // The guard refused — DO NOT delete anything. Record a failed,
            // non-mutating result so the audit log captures the refusal.
            log.error("\(descriptor.id, privacy: .public) refused by path-guard: \(refusal.description, privacy: .public)")
            return ActionResult(
                actionID: descriptor.id,
                succeeded: false,
                skipped: true,
                freedBytes: 0,
                beforeFreeBytes: before,
                afterFreeBytes: before,
                error: "path-guard refused: \(refusal.description)"
            )
        } catch {
            return ActionResult(
                actionID: descriptor.id,
                succeeded: false,
                skipped: true,
                freedBytes: 0,
                beforeFreeBytes: before,
                afterFreeBytes: before,
                error: "\(error)"
            )
        }
    }
}

/// Compact byte formatting shared by action previews / summaries.
public enum ActionFormat {
    public static func bytes(_ n: UInt64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB, .useKB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(clamping: n))
    }
}
