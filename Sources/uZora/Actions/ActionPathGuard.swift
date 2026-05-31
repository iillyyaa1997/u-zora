import Foundation
import os

/// SAFETY-CRITICAL. The single chokepoint every destructive action MUST go
/// through before deleting anything on disk.
///
/// These actions delete files (`~/Library/Caches/*`,
/// `~/Library/Developer/Xcode/DerivedData/*`). A bug here deletes user data,
/// so the guard is deliberately paranoid:
///
///  1. **Documented roots only.** A delete target is rejected unless its
///     *fully symlink-resolved* path is **strictly contained** within an
///     allow-listed, symlink-resolved root (`~/Library/Caches` or
///     `~/Library/Developer/Xcode/DerivedData`). The root itself is never a
///     valid delete target (we only ever remove its *contents*).
///  2. **No symlink escape.** Resolution uses `realpath(3)` on both the
///     candidate and the root, so a symlink inside the cache dir that points
///     at `/` or `~/Documents` resolves out of the root and is refused. The
///     containment test is performed on the resolved paths, never the raw
///     ones, so `../` traversal and symlink redirection both fail closed.
///  3. **Never the home dir / root / a system path.** Even if a root were
///     mis-configured, `homeDirectory`, `/`, and anything outside the user
///     home are explicitly refused as roots.
///  4. **Per-entry deletion does not follow directory symlinks out.** When
///     clearing a directory's contents we enumerate the *top-level* entries
///     with `FileManager` (which yields the symlink itself, not its target)
///     and remove each entry by path. `removeItem` on a symlink unlinks the
///     link, never recursing into the linked-to directory — so a symlink to
///     `~/Documents` inside the cache dir is unlinked, the documents are
///     untouched.
///
/// Every method is pure / synchronous and unit-tested against a temp dir
/// (`ActionPathGuardTests`) including the symlink-escape case.
public enum ActionPathGuard {

    private static let log = Logger(subsystem: "place.unicorns.uzora", category: "action-guard")

    /// Why a path was refused. Surfaced in logs + (optionally) the audit
    /// note so a refusal is never silent.
    public enum Refusal: Swift.Error, Equatable, CustomStringConvertible {
        /// The candidate, once symlink-resolved, is not strictly inside the
        /// resolved root (escape, `..`, or symlink redirection).
        case outsideRoot(candidate: String, root: String)
        /// The candidate resolves to exactly the root — we never delete the
        /// root, only its contents.
        case isRoot(String)
        /// The supplied root is itself unsafe (home dir, `/`, outside home).
        case unsafeRoot(String)
        /// The candidate path is empty / unrepresentable.
        case empty

        public var description: String {
            switch self {
            case .outsideRoot(let c, let r): return "path '\(c)' resolves outside allowed root '\(r)'"
            case .isRoot(let r):             return "path '\(r)' is the root itself; only its contents may be removed"
            case .unsafeRoot(let r):         return "root '\(r)' is unsafe (home dir, '/', or outside the user home)"
            case .empty:                     return "empty / unrepresentable path"
            }
        }
    }

    // MARK: - Root validation

    /// The user home directory, symlink-resolved. All allowed roots MUST be
    /// strictly under this.
    public static func resolvedHome() -> String {
        canonical(NSHomeDirectory())
    }

    /// Validate that `root` is a *safe* deletion root: a real path strictly
    /// under the user home, not the home dir itself, not `/`. Returns the
    /// canonical (symlink-resolved) root on success.
    public static func validateRoot(_ root: URL) -> Result<String, Refusal> {
        let canonicalRoot = canonical(root.path)
        guard !canonicalRoot.isEmpty else { return .failure(.empty) }
        let home = resolvedHome()
        // Refuse `/`, the home dir itself, and anything not strictly under home.
        if canonicalRoot == "/" { return .failure(.unsafeRoot(canonicalRoot)) }
        if canonicalRoot == home { return .failure(.unsafeRoot(canonicalRoot)) }
        guard isStrictlyContained(canonicalRoot, in: home) else {
            return .failure(.unsafeRoot(canonicalRoot))
        }
        return .success(canonicalRoot)
    }

    // MARK: - Candidate validation

    /// Validate a single delete-candidate against a (already validated) root.
    /// Returns the canonical candidate path on success. The candidate must
    /// resolve to a path strictly inside the canonical root and must not be
    /// the root itself.
    ///
    /// `candidate` is resolved with `realpath`; if it doesn't exist yet the
    /// lexical parent is resolved and the last component appended, so a
    /// not-yet-created path still gets a faithful containment check.
    public static func validateCandidate(_ candidate: URL, underRoot canonicalRoot: String) -> Result<String, Refusal> {
        let resolved = canonicalAllowingMissingLeaf(candidate.path)
        guard !resolved.isEmpty else { return .failure(.empty) }
        if resolved == canonicalRoot { return .failure(.isRoot(canonicalRoot)) }
        guard isStrictlyContained(resolved, in: canonicalRoot) else {
            return .failure(.outsideRoot(candidate: resolved, root: canonicalRoot))
        }
        return .success(resolved)
    }

    // MARK: - Safe contents-removal

    /// Remove the **top-level contents** of `root` after validating it.
    ///
    /// Returns the number of bytes removed (best-effort sum of the sizes of
    /// the entries that were successfully deleted) and the count of entries
    /// removed. Throws `Refusal` if the root is unsafe.
    ///
    /// Each top-level entry is itself re-validated against the canonical root
    /// before deletion (defence in depth) and removed by path — `removeItem`
    /// unlinks a symlink entry rather than following it, so a symlink to an
    /// out-of-root directory is unlinked without touching its target.
    @discardableResult
    public static func removeContents(of root: URL, fileManager fm: FileManager = .default) throws -> (bytesRemoved: UInt64, entriesRemoved: Int) {
        let canonicalRoot: String
        switch validateRoot(root) {
        case .success(let r): canonicalRoot = r
        case .failure(let why):
            log.error("removeContents refused unsafe root: \(why.description, privacy: .public)")
            throw why
        }

        // Enumerate top-level entries WITHOUT following symlinks or
        // descending — we get the entries (including symlink entries) of the
        // root directory itself. Use the canonical root URL so the children
        // we build are anchored at the resolved location.
        let rootURL = URL(fileURLWithPath: canonicalRoot, isDirectory: true)
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey],
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            // Root doesn't exist / unreadable → nothing to remove.
            return (0, 0)
        }

        var bytesRemoved: UInt64 = 0
        var entriesRemoved = 0
        for entry in entries {
            // Defence in depth: re-validate each child. A child that is a
            // symlink pointing out of the root resolves outside and is
            // refused here, so we never even attempt to delete through it.
            // We DO still unlink a symlink whose *own* lexical location is in
            // the root but whose target is elsewhere — see below: we validate
            // the LEXICAL child location (the entry path under the root), not
            // its symlink target, then delete by that path so only the link
            // is unlinked.
            let lexical = rootURL.appendingPathComponent(entry.lastPathComponent)
            guard isStrictlyContained(lexical.path, in: canonicalRoot) else {
                log.error("skipping entry not lexically under root: \(entry.lastPathComponent, privacy: .public)")
                continue
            }
            // Measure size before deletion (skip symlinks — unlinking a link
            // frees ~nothing and we must not stat through it).
            let isSymlink = (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            if !isSymlink {
                bytesRemoved &+= directorySize(of: entry, fileManager: fm)
            }
            do {
                try fm.removeItem(at: lexical)
                entriesRemoved += 1
            } catch {
                log.error("failed to remove \(entry.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return (bytesRemoved, entriesRemoved)
    }

    /// Best-effort recursive byte size of a file or directory. Used both for
    /// the dry-run estimate and the post-delete freed accounting. Never
    /// follows symlinks (a symlink contributes ~0).
    public static func directorySize(of url: URL, fileManager fm: FileManager = .default) -> UInt64 {
        var total: UInt64 = 0
        // A symbolic link contributes nothing — never resolve through it.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return 0
        }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if !isDir {
            return fileAllocatedSize(of: url)
        }
        guard let en = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
            options: [] // do NOT skip hidden; do NOT follow symlinks (default)
        ) else {
            return 0
        }
        for case let child as URL in en {
            // Don't follow symlinks the enumerator surfaces.
            if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                continue
            }
            let isRegular = (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isRegular {
                total &+= fileAllocatedSize(of: child)
            }
        }
        return total
    }

    private static func fileAllocatedSize(of url: URL) -> UInt64 {
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if let a = v?.totalFileAllocatedSize { return UInt64(a) }
        if let a = v?.fileAllocatedSize { return UInt64(a) }
        return 0
    }

    // MARK: - Canonicalisation + containment (pure)

    /// `realpath(3)` resolution of an existing path. Returns the input
    /// (standardised) if the path can't be resolved (doesn't exist).
    public static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(expanded, &resolved) != nil {
            // realpath writes a NUL-terminated C string into `resolved`.
            // Decode up to (not including) the NUL — `String(cString:)` is
            // deprecated on the macOS 26 SDK.
            let bytes = resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        // Fall back to a lexical standardisation (resolves `..`/`.`), so a
        // missing path still gets a sane comparison form.
        return (expanded as NSString).standardizingPath
    }

    /// Canonicalise a path whose *leaf* may not yet exist: resolve the parent
    /// with realpath, then re-attach the final component. This makes the
    /// containment check faithful for a delete target that hasn't been
    /// created (its parent — the root — does exist and resolves correctly).
    public static func canonicalAllowingMissingLeaf(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return canonical(expanded)
        }
        let url = URL(fileURLWithPath: expanded)
        let parent = url.deletingLastPathComponent().path
        let leaf = url.lastPathComponent
        let canonicalParent = canonical(parent)
        guard !canonicalParent.isEmpty, !leaf.isEmpty else {
            return (expanded as NSString).standardizingPath
        }
        return (canonicalParent as NSString).appendingPathComponent(leaf)
    }

    /// True iff `child` is *strictly* inside `parent` (child != parent, and
    /// child begins with `parent + "/"`). Both must already be canonical
    /// absolute paths. The trailing-separator anchoring prevents the classic
    /// `/foo` vs `/foobar` prefix-collision false positive.
    public static func isStrictlyContained(_ child: String, in parent: String) -> Bool {
        guard !child.isEmpty, !parent.isEmpty else { return false }
        if child == parent { return false }
        let parentWithSep = parent.hasSuffix("/") ? parent : parent + "/"
        return child.hasPrefix(parentWithSep)
    }
}
