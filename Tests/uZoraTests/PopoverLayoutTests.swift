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

    /// The canonical System-overview tile order shared by every preset (A4a:
    /// the original four, then the five expanded-catalog tiles).
    private let canonicalTileOrder: [TileKind] = [
        .memPressureLevel, .cpuTemp, .diskFree, .battery,
        .gpuPercent, .coresPinned, .swapInRate, .kernelTask, .memoryUsedPercent,
    ]

    /// The five A4a expanded-catalog tiles — opt-in, default-OFF in EVERY
    /// preset (D4).
    private let expandedCatalogTiles: [TileKind] = [
        .gpuPercent, .coresPinned, .swapInRate, .kernelTask, .memoryUsedPercent,
    ]

    /// The five original content blocks (visible in Balanced / Power).
    private let originalBlocks: [WidgetKind] = [
        .verdict, .attention, .systemOverview, .topProcesses, .recentActions,
    ]

    /// The two A4b expanded-catalog blocks — opt-in, default-OFF in EVERY
    /// preset (D4), appended after `recentActions`.
    private let expandedCatalogBlocks: [WidgetKind] = [.sevenDayChart, .topNet]

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

    @Test func jsonRoundTripPreservesNewCatalogTiles() {
        // A4a: a layout that enables the new catalog tiles must survive the
        // JSON codec verbatim (proves the new raw values encode + decode).
        let custom = PopoverLayout(
            blocks: [BlockConfig(kind: .systemOverview, visible: true)],
            tiles: [
                TileConfig(kind: .gpuPercent, visible: true),
                TileConfig(kind: .coresPinned, visible: false),
                TileConfig(kind: .swapInRate, visible: true),
                TileConfig(kind: .kernelTask, visible: false),
                TileConfig(kind: .memoryUsedPercent, visible: true),
            ]
        )
        let back = PopoverLayout(jsonString: custom.toJSONString())
        #expect(back == custom)
        #expect(back?.tiles.map(\.kind) == [
            .gpuPercent, .coresPinned, .swapInRate, .kernelTask, .memoryUsedPercent,
        ])
        #expect(back?.tiles.map(\.visible) == [true, false, true, false, true])
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
        // Block order + visibility (A4b: the two expanded-catalog blocks are
        // appended after recentActions, default-OFF).
        #expect(m.blocks.map(\.kind) == [.verdict, .attention, .systemOverview, .topProcesses, .recentActions, .sevenDayChart, .topNet])
        #expect(blockVisible(m, .sevenDayChart) == false)
        #expect(blockVisible(m, .topNet) == false)
        #expect(blockVisible(m, .verdict) == true)
        #expect(blockVisible(m, .attention) == true)
        #expect(blockVisible(m, .systemOverview) == true)
        #expect(blockVisible(m, .topProcesses) == false)
        #expect(blockVisible(m, .recentActions) == false)
        // Tiles: canonical order (mem-pressure leads, then the A4a catalog);
        // battery hidden, and the five catalog tiles all hidden (default-OFF).
        #expect(m.tiles.map(\.kind) == canonicalTileOrder)
        #expect(tileVisible(m, .memPressureLevel) == true)
        #expect(tileVisible(m, .cpuTemp) == true)
        #expect(tileVisible(m, .diskFree) == true)
        #expect(tileVisible(m, .battery) == false)
        for kind in expandedCatalogTiles {
            #expect(tileVisible(m, kind) == false)
        }
    }

    /// A4a: the five expanded-catalog tiles are present but default-OFF in
    /// EVERY preset (D4) — so they show UNCHECKED in the Layout-tab checklist.
    @Test func expandedCatalogTilesAreDefaultOffInEveryPreset() {
        for layout in [PopoverLayout.minimal, .balanced, .diagnosis, .power] {
            // Every preset lists all 9 tiles in the canonical order.
            #expect(layout.tiles.map(\.kind) == canonicalTileOrder)
            #expect(layout.tiles.count == TileKind.allCases.count)
            for kind in expandedCatalogTiles {
                #expect(tileVisible(layout, kind) == false)
            }
        }
    }

    @Test func balancedPresetHasEveryBlockAndOriginalTileVisible() {
        let b = PopoverLayout.balanced
        // The five original blocks are visible; the two A4b catalog blocks stay
        // opt-in (hidden) even in Balanced.
        for kind in originalBlocks { #expect(blockVisible(b, kind) == true) }
        for kind in expandedCatalogBlocks { #expect(blockVisible(b, kind) == false) }
        #expect(b.blocks.count == WidgetKind.allCases.count)
        // The four original tiles are all visible; the five A4a catalog tiles
        // stay opt-in (hidden) even in Balanced.
        #expect(tileVisible(b, .memPressureLevel) == true)
        #expect(tileVisible(b, .cpuTemp) == true)
        #expect(tileVisible(b, .diskFree) == true)
        #expect(tileVisible(b, .battery) == true)
        for kind in expandedCatalogTiles {
            #expect(tileVisible(b, kind) == false)
        }
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
        for kind in expandedCatalogTiles {
            #expect(tileVisible(d, kind) == false)
        }
    }

    @Test func powerPresetHasEveryBlockAndOriginalTileVisible() {
        let p = PopoverLayout.power
        // Same as Balanced: the five original blocks visible, the two A4b
        // catalog blocks opt-in (hidden).
        for kind in originalBlocks { #expect(blockVisible(p, kind) == true) }
        for kind in expandedCatalogBlocks { #expect(blockVisible(p, kind) == false) }
        #expect(p.blocks.count == WidgetKind.allCases.count)
        // Same as Balanced: original four visible, A4a catalog opt-in (hidden).
        #expect(tileVisible(p, .memPressureLevel) == true)
        #expect(tileVisible(p, .cpuTemp) == true)
        #expect(tileVisible(p, .diskFree) == true)
        #expect(tileVisible(p, .battery) == true)
        for kind in expandedCatalogTiles {
            #expect(tileVisible(p, kind) == false)
        }
        #expect(p.tiles.count == TileKind.allCases.count)
    }

    /// A4a: the tile catalog now has exactly nine kinds.
    @Test func tileKindCatalogHasNineKinds() {
        #expect(TileKind.allCases.count == 9)
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
