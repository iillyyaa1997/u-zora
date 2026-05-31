import Foundation
import os

/// Loads, persists, and hot-reloads `UZoraConfig` from
/// `~/Library/Application Support/uZora/config.toml`.
///
/// On first launch the loader writes a default config if the file is
/// missing. `startWatching()` installs a `DispatchSourceFileSystemObject`
/// keyed on the config file so user edits via TextEdit / vim trigger an
/// immediate reload broadcast to subscribers.
///
/// Atomic write: `write(_:)` writes to `<path>.tmp` then `rename(2)`s
/// over the destination to guarantee the watcher never sees a half-written
/// file (and so a crash mid-write can't corrupt the live config).
public actor ConfigLoader {

    public typealias ReloadCallback = @Sendable (UZoraConfig) -> Void

    public let configURL: URL
    private(set) public var current: UZoraConfig

    private var observers: [(UUID, ReloadCallback)] = []
    private var watchSource: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1

    /// Exact TOML text of the most recent `write(_:)`. The file-watcher
    /// compares an incoming reload's on-disk text against this and SKIPS the
    /// reload+broadcast when they match byte-for-byte — that event is just our
    /// own atomic rename echoing back, and broadcasting it would fire the
    /// hot-reload chain a SECOND time for byte-identical content (every in-app
    /// reconfigure used to reconfigure twice). A genuine external edit differs
    /// from this text, so it still reloads normally. Cleared whenever a real
    /// external reload lands so a later edit reverting to the last-written
    /// bytes is still observed.
    private var lastWrittenTOML: String?

    /// Test hook: total number of observer broadcasts performed (both the
    /// direct `write()` broadcast and watcher-driven reloads). A single
    /// in-app `write()` must increment this by exactly ONE — the watcher's
    /// self-write echo is suppressed. Internal — `@testable import`.
    private(set) var broadcastCount: Int = 0

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "config")

    /// Construct a loader bound to `configURL` (default:
    /// `~/Library/Application Support/uZora/config.toml`). Writes a
    /// default file if the path does not exist.
    public init(configURL: URL? = nil) throws {
        let url = configURL ?? Self.defaultURL()
        self.configURL = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            let defaultConfig = UZoraConfig.default
            try Self.writeAtomic(defaultConfig.toTOML(), to: url)
            self.current = defaultConfig
        } else {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                self.current = try UZoraConfig.fromTOML(text)
            } catch {
                self.current = UZoraConfig.default
                throw ConfigError.malformed(error)
            }
        }
    }

    /// Default config-file path: `~/Library/Application Support/uZora/config.toml`.
    /// Override with `UZORA_CONFIG_PATH` environment variable for tests.
    public static func defaultURL() -> URL {
        if let env = ProcessInfo.processInfo.environment["UZORA_CONFIG_PATH"],
           !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: false)
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent("uZora", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    /// Re-read the config file from disk, replacing `current`. Returns the
    /// freshly loaded config and broadcasts to every observer.
    ///
    /// Always broadcasts — callers that explicitly `reload()` (tests, manual
    /// refresh) want the observer fire. The file-watcher uses the private
    /// `reloadFromWatcher()` instead, which suppresses the self-write echo.
    @discardableResult
    public func reload() throws -> UZoraConfig {
        let text = try String(contentsOf: configURL, encoding: .utf8)
        let parsed = try UZoraConfig.fromTOML(text)
        current = parsed
        // A genuine external edit invalidates the self-write fingerprint: if
        // the user later re-writes the exact last-written bytes by hand, the
        // watcher should still observe it.
        lastWrittenTOML = nil
        log.info("config.toml reloaded")
        broadcast()
        return parsed
    }

    /// Watcher-driven reload. Reads the file; if its text is byte-identical to
    /// the most recent `write(_:)` (i.e. this event is our own atomic rename
    /// echoing back), it SKIPS the reload+broadcast so the hot-reload chain
    /// fires exactly once per in-app write — not twice. A real external edit
    /// (different bytes) reloads + broadcasts normally.
    private func reloadFromWatcher() throws {
        let text = try String(contentsOf: configURL, encoding: .utf8)
        if let written = lastWrittenTOML, written == text {
            // Our own write echoing back through the watcher — already
            // broadcast by write(). Consume the fingerprint (one echo only)
            // and stay silent.
            lastWrittenTOML = nil
            log.debug("config watcher: ignoring self-write echo")
            return
        }
        let parsed = try UZoraConfig.fromTOML(text)
        current = parsed
        lastWrittenTOML = nil
        log.info("config.toml reloaded (external edit)")
        broadcast()
    }

    /// Persist `config` to disk atomically and update `current`.
    ///
    /// Records the exact written TOML so the file-watcher can recognise (and
    /// suppress) the resulting filesystem event as a self-write echo —
    /// otherwise every in-app reconfigure would fire the hot-reload chain
    /// twice (once here, once from the watcher reloading byte-identical
    /// content).
    public func write(_ config: UZoraConfig) throws {
        let toml = config.toTOML()
        lastWrittenTOML = toml
        try Self.writeAtomic(toml, to: configURL)
        current = config
        broadcast()
    }

    /// Subscribe to reload events. Callback is invoked once with `current`
    /// at registration time. Returns a token usable with `unobserve(_:)`.
    @discardableResult
    public func observe(_ callback: @escaping ReloadCallback) -> UUID {
        observe(callback, skippingInitial: false)
    }

    /// Subscribe to reload events, optionally suppressing the one-shot
    /// invocation with `current` at registration time. Pass
    /// `skippingInitial: true` when the subscriber already reflects the
    /// current config (e.g. the probe registry was just built from it) and
    /// only cares about *subsequent* hot-reloads.
    @discardableResult
    public func observe(_ callback: @escaping ReloadCallback, skippingInitial: Bool) -> UUID {
        let token = UUID()
        observers.append((token, callback))
        if !skippingInitial {
            callback(current)
        }
        return token
    }

    public func unobserve(_ token: UUID) {
        observers.removeAll { $0.0 == token }
    }

    /// Start an FSEvents-style file watcher on the config file. Calls
    /// `reload()` whenever the file changes. Idempotent.
    public func startWatching() {
        guard watchSource == nil else { return }
        // Make sure file exists (creating defaults if needed) before opening fd.
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try? Self.writeAtomic(current.toTOML(), to: configURL)
        }
        let fd = open(configURL.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("config watcher open() failed for \(self.configURL.path, privacy: .public)")
            return
        }
        watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: DispatchQueue.global(qos: .utility)
        )
        let url = configURL
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { [weak self] in
                // Tiny debounce — editors often touch+rename atomically.
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                do {
                    // Watcher path suppresses the self-write echo (see
                    // reloadFromWatcher) so an in-app write reconfigures once.
                    try await self.reloadFromWatcher()
                } catch {
                    // Reload failed; reset the watcher to the (possibly
                    // freshly created) path so atomic-rename editors stay
                    // observed.
                    await self.restartWatching(after: url)
                }
            }
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        watchSource = source
        log.info("config watcher armed on \(self.configURL.path, privacy: .public)")
    }

    public func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
        watchedFD = -1
    }

    /// Internal: tear down + re-arm the watcher (used after delete/rename).
    private func restartWatching(after url: URL) {
        stopWatching()
        startWatching()
    }

    // MARK: - Helpers

    private func broadcast() {
        broadcastCount += 1
        for (_, callback) in observers {
            callback(current)
        }
    }

    /// Atomically replace `url`'s contents with `text` by writing to a
    /// sibling `.tmp` then renaming in place. Avoids partial writes.
    public static func writeAtomic(_ text: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(url.lastPathComponent + ".tmp")
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        // `replaceItem(at:withItemAt:...)` performs the rename + handles
        // backup correctly across volumes.
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            // Fallback: best-effort rename if replaceItem fails (e.g. file
            // doesn't yet exist on a volume that requires it pre-existing).
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}

/// Errors emitted by the config loader.
public enum ConfigError: Swift.Error, CustomStringConvertible {
    case malformed(Swift.Error)
    case ioFailure(Swift.Error)

    public var description: String {
        switch self {
        case .malformed(let e): return "malformed config: \(e)"
        case .ioFailure(let e): return "config I/O: \(e)"
        }
    }
}
