import Testing
import Foundation
@testable import uZora

@Suite("ActionsConfig — TOML round-trip, defaults, sanitize")
struct ActionsConfigTests {

    // MARK: - Defaults (Q3 / Q4)

    @Test func defaults_everyActionAutoDisabled() {
        let c = ActionsConfig()
        #expect(c.pruneApfsSnapshots.autoEnabled == false)
        #expect(c.clearDerivedData.autoEnabled == false)
        #expect(c.brewCleanup.autoEnabled == false)
        #expect(c.clearUserCaches.autoEnabled == false)
        // Every descriptor-known action defaults OFF.
        for d in ActionsConfig.descriptors {
            #expect(c[id: d.id]?.autoEnabled == false, "\(d.id) must default to auto-disabled")
        }
    }

    @Test func defaults_safetyKnobs() {
        let c = ActionsConfig()
        #expect(c.coolDownEnabled == true)
        #expect(c.coolDownMinutes == 30)
        #expect(c.rateLimitEnabled == true)
        #expect(c.rateLimitPerHour == 6)
        #expect(c.powerGate == true)
        #expect(c.focusGate == true)
        #expect(c.dryRunPreview == true)
    }

    @Test func uzoraConfig_default_includesActionsDefaults() {
        // The top-level default config carries an all-off actions section.
        let c = UZoraConfig.default
        #expect(c.actions == ActionsConfig())
    }

    // MARK: - TOML round-trip

    @Test func toml_roundTrip_preservesActions() throws {
        var c = UZoraConfig.default
        c.actions.pruneApfsSnapshots = ActionOverride(autoEnabled: true)
        c.actions.clearUserCaches = ActionOverride(autoEnabled: true, probe: "disk", severityFloor: .critical)
        c.actions.coolDownMinutes = 45
        c.actions.rateLimitPerHour = 3
        c.actions.powerGate = false
        c.actions.focusGate = false
        c.actions.dryRunPreview = false
        c.actions.coolDownEnabled = false
        c.actions.rateLimitEnabled = false

        let toml = c.toTOML()
        let parsed = try UZoraConfig.fromTOML(toml)

        #expect(parsed.actions == c.actions)
        #expect(parsed.actions.pruneApfsSnapshots.autoEnabled == true)
        #expect(parsed.actions.clearUserCaches.autoEnabled == true)
        #expect(parsed.actions.clearUserCaches.probe == "disk")
        #expect(parsed.actions.clearUserCaches.severityFloor == .critical)
        #expect(parsed.actions.coolDownMinutes == 45)
        #expect(parsed.actions.rateLimitPerHour == 3)
        #expect(parsed.actions.powerGate == false)
        #expect(parsed.actions.focusGate == false)
        #expect(parsed.actions.dryRunPreview == false)
        #expect(parsed.actions.coolDownEnabled == false)
        #expect(parsed.actions.rateLimitEnabled == false)
    }

    @Test func toml_missingActionsSection_yieldsDefaults() throws {
        // A config.toml with NO [actions] section → all defaults (back-compat
        // with pre-Q10 config files).
        let toml = """
        [general]
        language = "en"
        [http]
        port = 39842
        """
        let parsed = try UZoraConfig.fromTOML(toml)
        #expect(parsed.actions == ActionsConfig())
    }

    @Test func toml_partialActionsSection_keepsOtherDefaults() throws {
        let toml = """
        [actions]
        cool_down_minutes = 15
        [actions.brew_cleanup]
        auto_enabled = true
        """
        let parsed = try UZoraConfig.fromTOML(toml)
        #expect(parsed.actions.coolDownMinutes == 15)
        #expect(parsed.actions.brewCleanup.autoEnabled == true)
        // Untouched fields keep defaults.
        #expect(parsed.actions.rateLimitPerHour == 6)
        #expect(parsed.actions.powerGate == true)
        #expect(parsed.actions.pruneApfsSnapshots.autoEnabled == false)
    }

    // MARK: - Sanitize (read-boundary clamps)

    @Test func sanitize_coolDownMinutes_clampsNegativeAndHuge() {
        #expect(ConfigSanitizer.clampCoolDownMinutes(-5) == ConfigSanitizer.coolDownMinutesRange.lowerBound)
        #expect(ConfigSanitizer.clampCoolDownMinutes(999_999) == ConfigSanitizer.coolDownMinutesRange.upperBound)
        #expect(ConfigSanitizer.clampCoolDownMinutes(30) == 30)
    }

    @Test func sanitize_rateLimit_clampsZeroAndHuge() {
        // 0 (or negative) would silently block every auto action while reading
        // as "enabled" — coerce up to the floor.
        #expect(ConfigSanitizer.clampRateLimitPerHour(0) == ConfigSanitizer.rateLimitPerHourRange.lowerBound)
        #expect(ConfigSanitizer.clampRateLimitPerHour(-3) == ConfigSanitizer.rateLimitPerHourRange.lowerBound)
        #expect(ConfigSanitizer.clampRateLimitPerHour(10_000_000) == ConfigSanitizer.rateLimitPerHourRange.upperBound)
        #expect(ConfigSanitizer.clampRateLimitPerHour(6) == 6)
    }

    @Test func toml_handEditedAbsurdNumbers_clampedOnRead() throws {
        // A hand-edited config with absurd safety numbers must NOT disable
        // safety by overflow — they're clamped into range on read.
        let toml = """
        [actions]
        cool_down_minutes = -100
        rate_limit_per_hour = 0
        """
        let parsed = try UZoraConfig.fromTOML(toml)
        #expect(parsed.actions.coolDownMinutes == ConfigSanitizer.coolDownMinutesRange.lowerBound)
        #expect(parsed.actions.rateLimitPerHour == ConfigSanitizer.rateLimitPerHourRange.lowerBound)
    }

    @Test func equatable_distinguishesActionChanges() {
        // Equatable must catch a per-action flip (drives hot-reload detection).
        var a = UZoraConfig.default
        let b = a
        a.actions.brewCleanup.autoEnabled = true
        #expect(a != b)
        #expect(a.actions != b.actions)
    }
}
