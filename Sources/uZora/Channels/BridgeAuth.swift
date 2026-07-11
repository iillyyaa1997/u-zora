import Foundation
import Security
import os

/// Bearer-token authenticator for the bridge **write tier** (Phase B1b).
///
/// The read tier (metrics / alerts / findings / verdict / list_metrics /
/// get_layout / subscribe) stays OPEN on loopback — no auth. The write tier
/// (`ack_alert` / `set_probe_config`, over BOTH REST and MCP) now requires a
/// bearer token presented as `Authorization: Bearer <token>`; a missing/wrong
/// token yields 401 (see `RESTHandlers.authorizeWrite`).
///
/// The token is a secure-random 256-bit value rendered as 64 hex chars,
/// generated on first launch and persisted to a **`0600` sidecar file**
/// (`~/Library/Application Support/uZora/bridge-token`) — deliberately NOT the
/// world-readable `config.toml` (a signing/auth secret must not live in the
/// user-editable config). `loadOrCreate()` reads the existing token or mints +
/// persists a fresh one; production wires the result into the channel host so
/// every write is gated. B5 (Settings) will reuse `current()` to reveal/copy
/// the token and `regenerate(at:)` to roll it.
public struct BridgeAuth: Sendable {

    /// The active bridge token (64 hex chars). Exposed via `current()` so B5's
    /// Settings surface can reveal/copy it; the write path only ever calls
    /// `validate(_:)`.
    public let token: String

    private static let log = Logger(subsystem: "place.unicorns.uzora", category: "bridge-auth")

    public init(token: String) {
        self.token = token
    }

    /// The current bridge token, for display in Settings (B5). The write path
    /// uses `validate(_:)`; this accessor exists so the token can be surfaced
    /// without exposing a mutable field.
    public func current() -> String { token }

    /// Whether a presented bearer value equals the active token. A nil / empty
    /// value never validates. Uses a constant-time comparison — overkill for a
    /// loopback token, but cheap and avoids leaking prefix-match timing.
    public func validate(_ presented: String?) -> Bool {
        guard let presented, !presented.isEmpty else { return false }
        return Self.constantTimeEquals(presented, token)
    }

    // MARK: - Persistence

    /// Sidecar token path: `~/Library/Application Support/uZora/bridge-token`.
    /// Override with `UZORA_BRIDGE_TOKEN_PATH` for isolated tests / E2E (mirrors
    /// `ConfigLoader`'s `UZORA_CONFIG_PATH`). Intentionally a SEPARATE file from
    /// `config.toml` — the config is world-readable + hand-editable; an auth
    /// secret must not live there.
    public static func defaultTokenURL() -> URL {
        if let env = ProcessInfo.processInfo.environment["UZORA_BRIDGE_TOKEN_PATH"],
           !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: false)
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent("uZora", isDirectory: true)
            .appendingPathComponent("bridge-token", isDirectory: false)
    }

    /// Load the persisted token, or mint + persist a fresh one when the sidecar
    /// is missing/empty. Never throws — a persistence failure still returns an
    /// in-memory token (writes then FAIL CLOSED: they require a bearer the app
    /// knows, rather than falling back to no-auth). Re-asserts `0600` on load in
    /// case the file's mode drifted.
    public static func loadOrCreate(at url: URL? = nil) -> BridgeAuth {
        let target = url ?? defaultTokenURL()
        if let existing = try? String(contentsOf: target, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Defensive: re-assert 0600 (a prior write, backup tool, or
                // hand-copy may have widened it).
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: target.path
                )
                return BridgeAuth(token: trimmed)
            }
        }
        let token = generateToken()
        do {
            try persist(token, to: target)
        } catch {
            log.error("bridge token persist failed at \(target.path, privacy: .public): \(String(describing: error), privacy: .public); using in-memory token")
        }
        return BridgeAuth(token: token)
    }

    /// Mint a NEW token, persist it (best-effort), and return the new auth —
    /// the B5 "regenerate" action. Existing MCP/REST write clients must then
    /// re-read the token.
    @discardableResult
    public static func regenerate(at url: URL? = nil) -> BridgeAuth {
        let target = url ?? defaultTokenURL()
        let token = generateToken()
        do {
            try persist(token, to: target)
        } catch {
            log.error("bridge token regenerate persist failed: \(String(describing: error), privacy: .public)")
        }
        return BridgeAuth(token: token)
    }

    /// Write `token` to `url` with `0600` permissions, creating the parent
    /// directory. Sets the mode at creation (`createFile` honours the
    /// `.posixPermissions` attribute) AND re-asserts it afterwards so an
    /// overwrite of a pre-existing wider-mode file is tightened.
    static func persist(_ token: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = Data(token.utf8)
        let created = FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        if !created {
            // createFile can fail if the path already exists on some volumes;
            // fall back to an explicit write + chmod.
            try data.write(to: url, options: [.atomic])
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    // MARK: - Token generation + compare

    /// A secure-random 256-bit token rendered as 64 lowercase hex chars. Prefers
    /// `SecRandomCopyBytes`; falls back to `SystemRandomNumberGenerator` (also a
    /// CSPRNG on Apple platforms) if that ever fails.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Length-checked constant-time byte comparison. The length check leaks the
    /// length (acceptable — the token length is fixed + public); the body avoids
    /// early-exit so a same-length guess can't be refined by timing.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in ab.indices { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    /// Extract the token from an `Authorization: Bearer <token>` header value
    /// (case-insensitive scheme). Returns nil when the header is absent or not a
    /// Bearer credential.
    static func bearerToken(from header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let scheme = "bearer "
        guard trimmed.count > scheme.count,
              trimmed.prefix(scheme.count).lowercased() == scheme else { return nil }
        let value = trimmed.dropFirst(scheme.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

/// Auth material lifted from a write request's HTTP headers, threaded from the
/// HTTP/MCP entry points down to `RESTHandlers.authorizeWrite`. Sendable so it
/// crosses the actor boundaries the channel layer uses.
///
/// The header dict handed to `init(headers:)` uses lowercased keys (that is how
/// `HTTPRequest.parse` normalises them). A header-less context (`init()` with
/// all-nil) is the default for in-process / direct-call write paths: it passes
/// the Origin/Host check (absent ⇒ allowed) and — when no `BridgeAuth` is wired
/// — the bearer check too, so unit tests of write *semantics* stay unauthenticated.
public struct WriteAuthContext: Sendable {
    public let authorization: String?
    public let origin: String?
    public let host: String?

    public init(authorization: String? = nil, origin: String? = nil, host: String? = nil) {
        self.authorization = authorization
        self.origin = origin
        self.host = host
    }

    /// Build from a parsed request's (lowercased-key) header dict.
    public init(headers: [String: String]) {
        self.authorization = headers["authorization"]
        self.origin = headers["origin"]
        self.host = headers["host"]
    }

    /// The presented bearer token (nil unless `Authorization: Bearer <token>`).
    public var presentedBearer: String? {
        BridgeAuth.bearerToken(from: authorization)
    }
}
