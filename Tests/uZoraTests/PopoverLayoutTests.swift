import Testing
import Foundation
@testable import uZora

/// Phase A3a: the persisted, preset-based `PopoverLayout` model — JSON
/// codec (with forward-compat unknown-kind tolerance), the four presets, and
/// the pure `effectiveLayout` resolver. No view harness; these assert the
/// model/resolution layer the render wiring consumes.
@Suite("Popover layout model + presets + resolver")
struct PopoverLayoutTests {

    // MARK: - Small lookups

    private func blockVisible(_ layout: PopoverLayout, _ kind: WidgetKind) -> Bool? {
        layout.blocks.first { $0.kind == kind }?.visible
    }
    private func tileVisible(_ layout: PopoverLayout, _ kind: TileKind) -> Bool? {
        layout.tiles.first { $0.kind == kind }?.visible
    }

    // MARK: - JSON round-trip (encode → decode identity)

    @Test func jsonRoundTripIsIdentity() {
        for layout in [PopoverLayout.minimal, .balanced, .diagnosis, .power] {
            let json = layout.toJSONString()
            let back = PopoverLayout(jsonString: json)
            #expect(back == layout)
        }
    }

    @Test func jsonRoundTripPreservesOrderAndVisibility() {
        // A non-preset custom layout (deliberately re-ordered + mixed
        // visibility) must survive verbatim, order included.
        let custom = PopoverLayout(
            blocks: [
                BlockConfig(kind: .recentActions, visible: true),
                BlockConfig(kind: .verdict, visible: false),
                BlockConfig(kind: .systemOverview, visible: true),
            ],
            tiles: [
                TileConfig(kind: .battery, visible: true),
                TileConfig(kind: .memPressureLevel, visible: false),
            ]
        )
        let back = PopoverLayout(jsonString: custom.toJSONString())
        #expect(back == custom)
        // Order preserved (not sorted by kind).
        #expect(back?.blocks.map(\.kind) == [.recentActions, .verdict, .systemOverview])
        #expect(back?.tiles.map(\.kind) == [.battery, .memPressureLevel])
    }

    @Test func toJSONStringHasStableSortedKeyOrder() {
        // `.sortedKeys` ⇒ "blocks" before "tiles", "kind" before "visible".
        let json = PopoverLayout.minimal.toJSONString()
        #expect(json.hasPrefix("{\"blocks\":[{\"kind\":"))
        #expect(json.contains("\"visible\":"))
        // Stable: encoding twice yields the identical string.
        #expect(json == PopoverLayout.minimal.toJSONString())
    }

    // MARK: - Forward-compat: unknown kind decodes without crashing + is skipped

    @Test func unknownBlockAndTileKindsAreDroppedNotThrown() {
        let json = """
        {"blocks":[\
        {"kind":"verdict","visible":true},\
        {"kind":"gremlin","visible":true},\
        {"kind":"attention","visible":false}],\
        "tiles":[\
        {"kind":"cpuTemp","visible":true},\
        {"kind":"phantomTile","visible":true},\
        {"kind":"battery","visible":false}]}
        """
        let layout = PopoverLayout(jsonString: json)
        #expect(layout != nil)
        // Known entries preserved in order; unknowns dropped.
        #expect(layout?.blocks.map(\.kind) == [.verdict, .attention])
        #expect(layout?.blocks.map(\.visible) == [true, false])
        #expect(layout?.tiles.map(\.kind) == [.cpuTemp, .battery])
        #expect(layout?.tiles.map(\.visible) == [true, false])
    }

    @Test func allUnknownDecodesToEmptyLayoutNotNil() {
        let json = """
        {"blocks":[{"kind":"nope","visible":true}],"tiles":[{"kind":"nah","visible":true}]}
        """
        let layout = PopoverLayout(jsonString: json)
        #expect(layout != nil)
        #expect(layout?.blocks.isEmpty == true)
        #expect(layout?.tiles.isEmpty == true)
    }

    @Test func malformedJSONReturnsNil() {
        #expect(PopoverLayout(jsonString: "not json{") == nil)
        #expect(PopoverLayout(jsonString: "") == nil)
        #expect(PopoverLayout(jsonString: "[1,2,3]") == nil)
    }

    // MARK: - Preset visibility (esp. minimal = D-C1)

    @Test func minimalPresetMatchesDC1() {
        let m = PopoverLayout.minimal
        // Block order + visibility.
        #expect(m.blocks.map(\.kind) == [.verdict, .attention, .systemOverview, .topProcesses, .recentActions])
        #expect(blockVisible(m, .verdict) == true)
        #expect(blockVisible(m, .attention) == true)
        #expect(blockVisible(m, .systemOverview) == true)
        #expect(blockVisible(m, .topProcesses) == false)
        #expect(blockVisible(m, .recentActions) == false)
        // Tiles: mem-pressure leads; battery hidden.
        #expect(m.tiles.map(\.kind) == [.memPressureLevel, .cpuTemp, .diskFree, .battery])
        #expect(tileVisible(m, .memPressureLevel) == true)
        #expect(tileVisible(m, .cpuTemp) == true)
        #expect(tileVisible(m, .diskFree) == true)
        #expect(tileVisible(m, .battery) == false)
    }

    @Test func balancedPresetIsEverythingVisible() {
        let b = PopoverLayout.balanced
        let allBlocksVisible = b.blocks.allSatisfy { $0.visible }
        let allTilesVisible = b.tiles.allSatisfy { $0.visible }
        #expect(allBlocksVisible)
        #expect(b.blocks.count == WidgetKind.allCases.count)
        #expect(allTilesVisible)
        #expect(b.tiles.count == TileKind.allCases.count)
    }

    @Test func diagnosisPresetIsFindingsForward() {
        let d = PopoverLayout.diagnosis
        #expect(blockVisible(d, .verdict) == true)
        #expect(blockVisible(d, .attention) == true)
        #expect(blockVisible(d, .systemOverview) == true)
        #expect(blockVisible(d, .topProcesses) == true)
        #expect(blockVisible(d, .recentActions) == false)
        #expect(tileVisible(d, .memPressureLevel) == true)
        #expect(tileVisible(d, .cpuTemp) == true)
        #expect(tileVisible(d, .diskFree) == false)
        #expect(tileVisible(d, .battery) == false)
    }

    @Test func powerPresetIsEverythingVisible() {
        let p = PopoverLayout.power
        let allBlocksVisible = p.blocks.allSatisfy { $0.visible }
        let allTilesVisible = p.tiles.allSatisfy { $0.visible }
        #expect(allBlocksVisible)
        #expect(allTilesVisible)
        #expect(p.blocks.count == WidgetKind.allCases.count)
        #expect(p.tiles.count == TileKind.allCases.count)
    }

    @Test func presetsByNameCoversEveryPresetName() {
        for name in PresetName.allCases {
            #expect(PopoverLayout.presetsByName[name.rawValue] != nil)
        }
        #expect(PopoverLayout.presetsByName.count == PresetName.allCases.count)
        #expect(PresetName.default == .minimal)
        #expect(PopoverLayout.presetsByName[PresetName.default.rawValue] == .minimal)
    }

    // MARK: - effectiveLayout resolver

    @Test func effectiveLayout_validJSONWins() {
        let custom = PopoverLayout(
            blocks: [BlockConfig(kind: .recentActions, visible: true)],
            tiles: [TileConfig(kind: .battery, visible: true)]
        )
        // Even with a real preset name, a valid customized JSON overrides it.
        let resolved = effectiveLayout(preset: "power", layoutJSON: custom.toJSONString())
        #expect(resolved == custom)
        #expect(resolved != .power)
    }

    @Test func effectiveLayout_emptyJSONUsesNamedPreset() {
        #expect(effectiveLayout(preset: "minimal", layoutJSON: "") == .minimal)
        #expect(effectiveLayout(preset: "balanced", layoutJSON: "") == .balanced)
        #expect(effectiveLayout(preset: "diagnosis", layoutJSON: "   ") == .diagnosis)
        #expect(effectiveLayout(preset: "power", layoutJSON: "") == .power)
    }

    @Test func effectiveLayout_garbageJSONFallsBackToPreset() {
        // Non-empty but unparseable ⇒ ignore it, use the named preset.
        #expect(effectiveLayout(preset: "balanced", layoutJSON: "not json{") == .balanced)
        #expect(effectiveLayout(preset: "diagnosis", layoutJSON: "{oops") == .diagnosis)
    }

    @Test func effectiveLayout_unknownPresetFallsBackToMinimal() {
        #expect(effectiveLayout(preset: "does-not-exist", layoutJSON: "") == .minimal)
        #expect(effectiveLayout(preset: "", layoutJSON: "") == .minimal)
        // Garbage JSON + unknown preset ⇒ still minimal.
        #expect(effectiveLayout(preset: "bogus", layoutJSON: "garbage{") == .minimal)
    }
}
