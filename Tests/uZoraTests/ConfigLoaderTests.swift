import Testing
import Foundation
@testable import uZora

@Suite("ConfigLoader: write/read + atomic + watcher")
struct ConfigLoaderTests {

    /// Helper — create a fresh temp directory + config path for each test.
    private func makeTempPath() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-config-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.toml")
    }

    @Test func firstLaunch_writesDefaults() async throws {
        let path = makeTempPath()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let loader = try ConfigLoader(configURL: path)
        // File should now exist + parseable to defaults.
        #expect(FileManager.default.fileExists(atPath: path.path))
        let current = await loader.current
        #expect(current == UZoraConfig.default)
        // Cleanup.
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }

    @Test func write_thenReload_roundTrip() async throws {
        let path = makeTempPath()
        let loader = try ConfigLoader(configURL: path)
        var cfg = await loader.current
        cfg.general.language = "ru"
        cfg.http.port = 47000
        cfg.notifications.bannerSeverityFloor = .critical
        try await loader.write(cfg)
        // Re-load from disk and verify persistence.
        let reloaded = try await loader.reload()
        #expect(reloaded.general.language == "ru")
        #expect(reloaded.http.port == 47000)
        #expect(reloaded.notifications.bannerSeverityFloor == .critical)
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }

    @Test func atomicWrite_replacesExistingContent() async throws {
        let path = makeTempPath()
        let loader = try ConfigLoader(configURL: path)
        var c1 = await loader.current
        c1.http.port = 11111
        try await loader.write(c1)
        let firstSize = try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int ?? 0
        #expect(firstSize > 0)
        var c2 = c1
        c2.http.port = 22222
        c2.general.language = "ru"
        try await loader.write(c2)
        let reloaded = try await loader.reload()
        #expect(reloaded.http.port == 22222)
        #expect(reloaded.general.language == "ru")
        // The .tmp sidecar should not linger.
        let tmpURL = path.deletingLastPathComponent().appendingPathComponent("config.toml.tmp")
        #expect(!FileManager.default.fileExists(atPath: tmpURL.path))
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }

    @Test func watcher_firesOnExternalEdit() async throws {
        let path = makeTempPath()
        let loader = try ConfigLoader(configURL: path)
        await loader.startWatching()
        // Pre-condition.
        var initial = await loader.current
        #expect(initial.general.language == "system")

        // Externally rewrite the file directly bypassing the loader.
        initial.general.language = "ru"
        initial.http.port = 50505
        let payload = initial.toTOML()
        try ConfigLoader.writeAtomic(payload, to: path)

        // Wait up to ~3s for the watcher debounce + reload to fire.
        let deadline = Date().addingTimeInterval(3)
        var sawUpdate = false
        while Date() < deadline {
            let current = await loader.current
            if current.general.language == "ru" {
                sawUpdate = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(sawUpdate, "Watcher did not pick up external edit within 3 s")

        await loader.stopWatching()
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }

    @Test func observe_firesImmediatelyWithCurrent() async throws {
        let path = makeTempPath()
        let loader = try ConfigLoader(configURL: path)
        let box = ConfigBox()
        await loader.observe { cfg in
            Task { await box.set(cfg) }
        }
        // Wait briefly for the immediate-fire callback to run.
        try await Task.sleep(for: .milliseconds(100))
        let stored = await box.value
        #expect(stored != nil)
        #expect(stored?.general.language == "system")
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }

    @Test func observe_broadcastsAfterWrite() async throws {
        let path = makeTempPath()
        let loader = try ConfigLoader(configURL: path)
        let box = ConfigBox()
        await loader.observe { cfg in
            Task { await box.set(cfg) }
        }
        var c = await loader.current
        c.http.port = 60000
        try await loader.write(c)
        // Give the observer task a moment to settle.
        try await Task.sleep(for: .milliseconds(100))
        let stored = await box.value
        #expect(stored?.http.port == 60000)
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }
}

/// Tiny actor used as a thread-safe box for the latest seen value.
private actor ConfigBox {
    var value: UZoraConfig?
    func set(_ v: UZoraConfig) { value = v }
}
