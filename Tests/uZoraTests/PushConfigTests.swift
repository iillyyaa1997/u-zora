import Testing
import Foundation
@testable import uZora

@Suite("PushConfig — TOML round-trip, defaults, sanitize, config-only")
struct PushConfigTests {

    // MARK: - Defaults (OFF by default)

    @Test func defaults_offAndSafe() {
        let p = PushConfig()
        #expect(p.enabled == false)
        #expect(p.severityFloor == .critical)          // stricter than banner floor
        #expect(p.kinds == ["alert", "verdict"])       // finding OFF by default
        #expect(p.pushCleared == false)
        #expect(p.coolDownSeconds == 60)
        #expect(p.rateLimitPerHour == 30)
        #expect(p.circuitBreakerThreshold == 5)
        #expect(p.execEnabled == false)
        #expect(p.execArgv == [])
        #expect(p.outboxEnabled == false)
        #expect(p.outboxPath == "")
    }

    @Test func uzoraConfig_default_includesPushDefaults() {
        #expect(UZoraConfig.default.push == PushConfig())
    }

    // MARK: - TOML round-trip (incl. string arrays)

    @Test func toml_roundTrip_preservesPush() throws {
        var c = UZoraConfig.default
        c.push = PushConfig(
            enabled: true,
            severityFloor: .warn,
            kinds: ["alert", "verdict", "finding"],
            pushCleared: true,
            coolDownSeconds: 120,
            rateLimitPerHour: 10,
            circuitBreakerThreshold: 3,
            execEnabled: true,
            execArgv: ["claude", "-p"],
            outboxEnabled: true,
            outboxPath: "/tmp/uzora-agent"
        )

        let toml = c.toTOML()
        let parsed = try UZoraConfig.fromTOML(toml)

        #expect(parsed.push == c.push)
        // The string arrays survive the hand-rolled parser/emitter verbatim.
        #expect(parsed.push.kinds == ["alert", "verdict", "finding"])
        #expect(parsed.push.execArgv == ["claude", "-p"])
        #expect(parsed.push.severityFloor == .warn)
        #expect(parsed.push.enabled == true)
        #expect(parsed.push.outboxPath == "/tmp/uzora-agent")
    }

    @Test func toml_defaultConfig_roundTrips() throws {
        // The whole-config default round-trip (mirrors ConfigParserTests) must
        // still hold now that [push] is emitted + parsed.
        let cfg = UZoraConfig.default
        let decoded = try UZoraConfig.fromTOML(cfg.toTOML())
        #expect(decoded == cfg)
    }

    @Test func toml_missingPushSection_yieldsDefaults() throws {
        let toml = """
        [general]
        language = "en"
        [http]
        port = 39842
        """
        let parsed = try UZoraConfig.fromTOML(toml)
        #expect(parsed.push == PushConfig())
    }

    @Test func toml_partialPushSection_keepsOtherDefaults() throws {
        let toml = """
        [push]
        enabled = true
        exec_enabled = true
        exec_argv = ["claude", "-p"]
        """
        let parsed = try UZoraConfig.fromTOML(toml)
        #expect(parsed.push.enabled == true)
        #expect(parsed.push.execEnabled == true)
        #expect(parsed.push.execArgv == ["claude", "-p"])
        // Untouched fields keep defaults.
        #expect(parsed.push.severityFloor == .critical)
        #expect(parsed.push.kinds == ["alert", "verdict"])
        #expect(parsed.push.rateLimitPerHour == 30)
        #expect(parsed.push.outboxEnabled == false)
    }

    // MARK: - Garbage degrades to defaults (read-boundary)

    @Test func toml_garbageDegradesToDefaults() throws {
        let toml = """
        [push]
        severity_floor = "bogus"
        kinds = ["nonsense", "alert"]
        cool_down_seconds = -5
        rate_limit_per_hour = 0
        circuit_breaker_threshold = 0
        """
        let parsed = try UZoraConfig.fromTOML(toml)
        // Bad floor → keep default critical.
        #expect(parsed.push.severityFloor == .critical)
        // Garbage kind dropped; only the valid one survives.
        #expect(parsed.push.kinds == ["alert"])
        // Absurd numbers clamped into range on read.
        #expect(parsed.push.coolDownSeconds == ConfigSanitizer.pushCoolDownSecondsRange.lowerBound)
        #expect(parsed.push.rateLimitPerHour == ConfigSanitizer.pushRateLimitPerHourRange.lowerBound)
        #expect(parsed.push.circuitBreakerThreshold == ConfigSanitizer.pushCircuitBreakerRange.lowerBound)
    }

    @Test func sanitizePushKinds_dedupeOrderAndFallback() {
        // De-dupe + preserve order.
        #expect(ConfigSanitizer.sanitizePushKinds(["finding", "finding", "alert"]) == ["finding", "alert"])
        // All-garbage or empty → default.
        #expect(ConfigSanitizer.sanitizePushKinds([]) == ConfigSanitizer.defaultPushKinds)
        #expect(ConfigSanitizer.sanitizePushKinds(["x", "y"]) == ConfigSanitizer.defaultPushKinds)
        // Mixed → keep only valid.
        #expect(ConfigSanitizer.sanitizePushKinds(["verdict", "x"]) == ["verdict"])
    }

    @Test func clampHelpers_negativeAndHuge() {
        #expect(ConfigSanitizer.clampPushCoolDownSeconds(-1) == ConfigSanitizer.pushCoolDownSecondsRange.lowerBound)
        #expect(ConfigSanitizer.clampPushCoolDownSeconds(9_999_999) == ConfigSanitizer.pushCoolDownSecondsRange.upperBound)
        #expect(ConfigSanitizer.clampPushCoolDownSeconds(60) == 60)
        #expect(ConfigSanitizer.clampPushRateLimitPerHour(0) == ConfigSanitizer.pushRateLimitPerHourRange.lowerBound)
        #expect(ConfigSanitizer.clampPushRateLimitPerHour(999_999) == ConfigSanitizer.pushRateLimitPerHourRange.upperBound)
        #expect(ConfigSanitizer.clampPushCircuitBreakerThreshold(0) == ConfigSanitizer.pushCircuitBreakerRange.lowerBound)
        #expect(ConfigSanitizer.clampPushCircuitBreakerThreshold(5) == 5)
    }

    @Test func equatable_distinguishesPushChanges() {
        var a = UZoraConfig.default
        let b = a
        a.push.enabled = true
        #expect(a != b)
        #expect(a.push != b.push)
    }

    // MARK: - Config-only invariant (no bridge write can set [push])

    @Test func bridgeWrite_cannotSetPush() async throws {
        // Seed a config whose [push] is customized + ENABLED. A bridge probe
        // reconfigure (the ONLY config write path) must leave [push] untouched:
        // ProbeConfigPatch has no push field and reconfigureProbe mutates only
        // `config.probes`. Same invariant as B1b's bearer / B2's capability_token.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-push-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")

        let loader = try ConfigLoader(configURL: url)
        var seeded = await loader.current
        seeded.push = PushConfig(
            enabled: true,
            severityFloor: .warn,
            kinds: ["alert", "verdict", "finding"],
            pushCleared: true,
            execEnabled: true,
            execArgv: ["claude", "-p"],
            outboxEnabled: true,
            outboxPath: "/tmp/agent"
        )
        try await loader.write(seeded)
        let original = await loader.current.push

        let rest = RESTHandlers(state: StateStore(), configLoader: loader)
        let resp = await rest.reconfigureProbe(name: "disk", patch: .init(enabled: false))
        #expect(resp.status == 200)

        // The probe write landed…
        #expect(await loader.current.probes.disk.enabled == false)
        // …and [push] is byte-for-byte preserved, in-memory AND on disk.
        #expect(await loader.current.push == original)
        let reloaded = try await loader.reload()
        #expect(reloaded.push == original)
    }
}
