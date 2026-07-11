import Testing
import Foundation
@testable import uZora

/// Phase A3a: the `[ui.popover]` config section — TOML round-trip of the
/// preset + the customized-layout JSON string (D-C3.ii: a scalar the
/// hand-rolled TOML parser CAN store), plus the garbage-degrades contract.
@Suite("[ui.popover] config round-trip")
struct PopoverLayoutConfigTests {

    @Test func default_uiPopover_isMinimalPresetEmptyJSON() throws {
        let d = UZoraConfig.default
        #expect(d.ui.popover.preset == "minimal")
        #expect(d.ui.popover.layoutJSON == "")
        // Round-trips unchanged through TOML.
        let decoded = try UZoraConfig.fromTOML(d.toTOML())
        #expect(decoded.ui == d.ui)
        #expect(decoded.ui.popover.preset == "minimal")
        #expect(decoded.ui.popover.layoutJSON == "")
    }

    @Test func popoverUIConfigDefault_matchesPresetNameDefault() {
        // The literal default in `PopoverUIConfig` must stay in lock-step with
        // the single-source-of-truth `PresetName.default`.
        #expect(PopoverUIConfig().preset == PresetName.default.rawValue)
        #expect(PresetName.default.rawValue == "minimal")
    }

    @Test func setPresetAndLayoutJSON_survivesRoundTrip() throws {
        // A customized layout serialized to JSON must survive write → read,
        // INCLUDING the quote-escaping through the TOML emitter/parser.
        var c = UZoraConfig.default
        let custom = PopoverLayout(
            blocks: [
                BlockConfig(kind: .verdict, visible: true),
                BlockConfig(kind: .systemOverview, visible: true),
                BlockConfig(kind: .attention, visible: false),
            ],
            tiles: [
                TileConfig(kind: .memPressureLevel, visible: true),
                TileConfig(kind: .cpuTemp, visible: false),
            ]
        )
        c.ui.popover.preset = "diagnosis"
        c.ui.popover.layoutJSON = custom.toJSONString()

        let toml = c.toTOML()
        let decoded = try UZoraConfig.fromTOML(toml)

        #expect(decoded.ui.popover.preset == "diagnosis")
        #expect(decoded.ui.popover.layoutJSON == custom.toJSONString())
        // The survived JSON re-parses to the exact same layout.
        #expect(PopoverLayout(jsonString: decoded.ui.popover.layoutJSON) == custom)
        // And the resolver would render that custom layout.
        #expect(effectiveLayout(
            preset: decoded.ui.popover.preset,
            layoutJSON: decoded.ui.popover.layoutJSON
        ) == custom)
    }

    @Test func garbageLayoutJSON_degradesToEmpty() throws {
        // A hand-edited config with a non-parseable layout_json must degrade
        // to "" at the read boundary (never crash), so the popover falls back
        // to the preset.
        let toml = """
        [ui.popover]
        preset = "balanced"
        layout_json = "not valid json {"
        """
        let cfg = try UZoraConfig.fromTOML(toml)
        #expect(cfg.ui.popover.preset == "balanced")
        #expect(cfg.ui.popover.layoutJSON == "")
        // Resolver still yields a usable layout (the named preset).
        #expect(effectiveLayout(
            preset: cfg.ui.popover.preset,
            layoutJSON: cfg.ui.popover.layoutJSON
        ) == .balanced)
    }

    @Test func missingUiPopoverSection_yieldsDefaults() throws {
        // A pre-A3a config with no [ui.popover] → default preset + empty JSON.
        let toml = """
        [general]
        language = "en"
        [http]
        port = 39842
        """
        let cfg = try UZoraConfig.fromTOML(toml)
        #expect(cfg.ui.popover.preset == "minimal")
        #expect(cfg.ui.popover.layoutJSON == "")
    }

    @Test func emptyPresetString_keepsDefault() throws {
        // An explicitly-empty preset falls back to the default rather than
        // becoming an empty name.
        let toml = """
        [ui.popover]
        preset = ""
        """
        let cfg = try UZoraConfig.fromTOML(toml)
        #expect(cfg.ui.popover.preset == "minimal")
    }
}
