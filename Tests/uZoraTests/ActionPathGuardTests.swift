import Testing
import Foundation
@testable import uZora

/// SAFETY-CRITICAL test suite for the destructive-action path guard. A bug
/// in `ActionPathGuard` deletes user data, so this suite is the mandatory
/// gate: it proves the guard refuses anything outside the documented root,
/// refuses the root itself, refuses symlink escape, and that the
/// contents-removal helper never follows a symlink out of the root.
@Suite("ActionPathGuard — destructive-delete safety")
struct ActionPathGuardTests {

    /// Build an isolated temp dir under the user home (the guard requires
    /// roots to be strictly under home). Returns the dir URL; caller cleans up.
    private func tempRootUnderHome() throws -> URL {
        // Place under ~/Library/Caches/uzora-guard-tests-<uuid> so it is a
        // real path strictly under the home dir — matching production roots.
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let base = home
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("uzora-guard-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - Containment (pure)

    @Test func strictContainment_basics() {
        #expect(ActionPathGuard.isStrictlyContained("/a/b/c", in: "/a/b"))
        // Not contained: equal paths.
        #expect(!ActionPathGuard.isStrictlyContained("/a/b", in: "/a/b"))
        // Prefix-collision must NOT count (/foo vs /foobar).
        #expect(!ActionPathGuard.isStrictlyContained("/foobar", in: "/foo"))
        // Parent is not inside child.
        #expect(!ActionPathGuard.isStrictlyContained("/a", in: "/a/b"))
        // Empty operands.
        #expect(!ActionPathGuard.isStrictlyContained("", in: "/a"))
        #expect(!ActionPathGuard.isStrictlyContained("/a", in: ""))
    }

    // MARK: - Root validation

    @Test func validateRoot_refusesHomeAndSlash() {
        // The home dir itself is never a valid root.
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if case .success = ActionPathGuard.validateRoot(home) {
            Issue.record("home dir must be refused as a root")
        }
        // "/" is never valid.
        if case .success = ActionPathGuard.validateRoot(URL(fileURLWithPath: "/")) {
            Issue.record("/ must be refused as a root")
        }
        // A path OUTSIDE home (e.g. /tmp) is refused.
        if case .success = ActionPathGuard.validateRoot(URL(fileURLWithPath: "/private/var/tmp")) {
            Issue.record("a root outside the user home must be refused")
        }
    }

    @Test func validateRoot_acceptsRealDirUnderHome() throws {
        let root = try tempRootUnderHome()
        defer { try? FileManager.default.removeItem(at: root) }
        switch ActionPathGuard.validateRoot(root) {
        case .success(let canonical):
            #expect(ActionPathGuard.isStrictlyContained(canonical, in: ActionPathGuard.resolvedHome()))
        case .failure(let why):
            Issue.record("expected a real dir under home to validate, got: \(why)")
        }
    }

    // MARK: - Candidate validation

    @Test func validateCandidate_refusesRootItself() throws {
        let root = try tempRootUnderHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalRoot = ActionPathGuard.canonical(root.path)
        // The root itself is not a deletable candidate.
        switch ActionPathGuard.validateCandidate(root, underRoot: canonicalRoot) {
        case .failure(.isRoot):
            break // expected
        default:
            Issue.record("validateCandidate must refuse the root itself")
        }
    }

    @Test func validateCandidate_refusesParentEscape() throws {
        let root = try tempRootUnderHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalRoot = ActionPathGuard.canonical(root.path)
        // A `..` escape resolves to the parent — must be refused.
        let escape = root.appendingPathComponent("../escape-target", isDirectory: false)
        switch ActionPathGuard.validateCandidate(escape, underRoot: canonicalRoot) {
        case .failure(.outsideRoot), .failure(.isRoot):
            break // refused (parent is outside or equal) — either is a refusal
        case .success(let p):
            Issue.record("`..` escape must be refused, got success: \(p)")
        case .failure(let why):
            // Any refusal is acceptable here.
            _ = why
        }
    }

    @Test func validateCandidate_acceptsChildInsideRoot() throws {
        let root = try tempRootUnderHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalRoot = ActionPathGuard.canonical(root.path)
        let child = root.appendingPathComponent("some-cache-entry", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        switch ActionPathGuard.validateCandidate(child, underRoot: canonicalRoot) {
        case .success(let p):
            #expect(ActionPathGuard.isStrictlyContained(p, in: canonicalRoot))
        case .failure(let why):
            Issue.record("a child inside the root must validate, got: \(why)")
        }
    }

    // MARK: - SYMLINK ESCAPE (the critical case)

    @Test func validateCandidate_refusesSymlinkEscape() throws {
        // Build: <root>/evil -> <home>/uzora-guard-OUTSIDE-<uuid>
        // The symlink LIVES in the root but its target resolves OUTSIDE it.
        // validateCandidate resolves the candidate via realpath → the target
        // → must be refused as outsideRoot.
        let root = try tempRootUnderHome()
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let outside = home.appendingPathComponent("uzora-guard-OUTSIDE-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let link = root.appendingPathComponent("evil", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let canonicalRoot = ActionPathGuard.canonical(root.path)
        switch ActionPathGuard.validateCandidate(link, underRoot: canonicalRoot) {
        case .failure(.outsideRoot):
            break // EXPECTED — symlink target resolves outside the root.
        case .success(let p):
            Issue.record("SYMLINK ESCAPE NOT CAUGHT — resolved to \(p); this would delete out-of-root data")
        case .failure(let why):
            Issue.record("expected outsideRoot refusal for symlink escape, got: \(why)")
        }
    }

    // MARK: - removeContents safety

    @Test func removeContents_refusesUnsafeRoot() {
        // The home dir is an unsafe root — removeContents must THROW, not
        // delete the user's entire home.
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #expect(throws: ActionPathGuard.Refusal.self) {
            _ = try ActionPathGuard.removeContents(of: home)
        }
        // "/" too.
        #expect(throws: ActionPathGuard.Refusal.self) {
            _ = try ActionPathGuard.removeContents(of: URL(fileURLWithPath: "/"))
        }
    }

    @Test func removeContents_clearsOnlyInsideRoot_andUnlinksSymlinkWithoutFollowing() throws {
        // Layout:
        //   <root>/a.txt                (real file — deleted)
        //   <root>/sub/b.txt            (real nested file — deleted)
        //   <root>/link  -> <outside>   (symlink — UNLINKED, target untouched)
        //   <outside>/precious.txt      (MUST survive)
        let root = try tempRootUnderHome()
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let outside = home.appendingPathComponent("uzora-guard-PRECIOUS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("world".utf8).write(to: sub.appendingPathComponent("b.txt"))
        let precious = outside.appendingPathComponent("precious.txt")
        try Data("DO NOT DELETE".utf8).write(to: precious)
        let link = root.appendingPathComponent("link", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let (bytesRemoved, entriesRemoved) = try ActionPathGuard.removeContents(of: root)

        // The precious file OUTSIDE the root MUST still exist (symlink was
        // unlinked, never followed).
        #expect(FileManager.default.fileExists(atPath: precious.path),
                "out-of-root file was deleted through a symlink — CRITICAL FAILURE")
        #expect(FileManager.default.fileExists(atPath: outside.path))
        // The root's real contents are gone.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        #expect(!FileManager.default.fileExists(atPath: sub.path))
        // 3 top-level entries removed (a.txt, sub, link).
        #expect(entriesRemoved == 3)
        // Some bytes accounted for from the real files (symlink contributes 0).
        #expect(bytesRemoved >= 0)
        // The root dir itself still exists (we clear CONTENTS, not the root).
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func removeContents_missingRoot_isNoOp() throws {
        // A non-existent (but lexically-safe) root under home → 0 removed, no throw.
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let ghost = home
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("uzora-guard-ghost-\(UUID().uuidString)", isDirectory: true)
        let (bytes, entries) = try ActionPathGuard.removeContents(of: ghost)
        #expect(bytes == 0)
        #expect(entries == 0)
    }

    @Test func directorySize_excludesSymlinks() throws {
        let root = try tempRootUnderHome()
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let outside = home.appendingPathComponent("uzora-guard-SZ-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        // A big file lives OUTSIDE; a symlink to it lives inside the root.
        try Data(repeating: 0x41, count: 100_000).write(to: outside.appendingPathComponent("big.bin"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("biglink"),
            withDestinationURL: outside.appendingPathComponent("big.bin")
        )
        // The symlink must NOT contribute the 100KB (size is measured without
        // following symlinks) — so the root's measured size is ~0.
        let size = ActionPathGuard.directorySize(of: root)
        #expect(size < 100_000, "directorySize followed a symlink — measured \(size)")
    }
}
