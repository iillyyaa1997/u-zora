import Testing
import Foundation
@testable import uZora

/// Phase A3b: the PURE layout-mutation helpers the Settings "Layout" tab drives
/// (`movingBlock` / `settingBlock` / `settingTile`). The SwiftUI wiring isn't
/// unit-tested, but these — the actual logic the List.onMove + toggles call —
/// are, including the persist round-trip (`toJSONString` → `init?(jsonString:)`
/// → `effectiveLayout`) so an edit survives config exactly as rendered.
@Suite("Popover layout edit helpers (A3b)")
struct PopoverLayoutEditTests {

    // MARK: - Small lookups

    private func blockVisible(_ layout: PopoverLayout, _ kind: WidgetKind) -> Bool? {
        layout.blocks.first { $0.kind == kind }?.visible
    }
    private func tileVisible(_ layout: PopoverLayout, _ kind: TileKind) -> Bool? {
        layout.tiles.first { $0.kind == kind }?.visible
    }

    // MARK: - movingBlock

    @Test func movingBlockReordersAndPreservesVisibility() {
        // minimal: [verdict✓, attention✓, systemOverview✓, topProcesses✗,
        // recentActions✗, sevenDayChart✗, topNet✗] (A4b catalog blocks appended).
        let base = PopoverLayout.minimal
        // Move the first block (verdict) down to offset 3 (SwiftUI move
        // semantics: destination is an offset into the pre-removal array).
        let moved = base.movingBlock(from: IndexSet(integer: 0), to: 3)
        #expect(moved.blocks.map(\.kind) == [.attention, .systemOverview, .verdict, .topProcesses, .recentActions, .sevenDayChart, .topNet])
        // Visibility travels with each block — unchanged from minimal.
        #expect(blockVisible(moved, .verdict) == true)
        #expect(blockVisible(moved, .attention) == true)
        #expect(blockVisible(moved, .topProcesses) == false)
        #expect(blockVisible(moved, .recentActions) == false)
        // Same set of blocks, just reordered.
        #expect(Set(moved.blocks.map(\.kind)) == Set(base.blocks.map(\.kind)))
        // Tiles untouched.
        #expect(moved.tiles == base.tiles)
    }

    @Test func movingBlockUpwardMatchesArrayMoveSemantics() {
        // Move recentActions (index 4) up to offset 1 — SwiftUI move semantics.
        // The two A4b catalog blocks (indices 5,6) stay put at the tail.
        let moved = PopoverLayout.minimal.movingBlock(from: IndexSet(integer: 4), to: 1)
        #expect(moved.blocks.map(\.kind) == [.verdict, .recentActions, .attention, .systemOverview, .topProcesses, .sevenDayChart, .topNet])
    }

    @Test func movingMultipleBlocksMatchesArrayMoveSemantics() {
        // balanced: [verdict, attention, systemOverview, topProcesses,
        // recentActions, sevenDayChart, topNet].
        // Move {0,1} to offset 4 ⇒ the A4b tail (indices 5,6) is undisturbed.
        let base = PopoverLayout.balanced
        let moved = base.movingBlock(from: IndexSet([0, 1]), to: 4)
        #expect(moved.blocks.map(\.kind) == [.systemOverview, .topProcesses, .verdict, .attention, .recentActions, .sevenDayChart, .topNet])
        // Still the same set of blocks, and each block's visibility is preserved
        // (balanced = original five visible, the two A4b catalog blocks OFF).
        #expect(Set(moved.blocks.map(\.kind)) == Set(base.blocks.map(\.kind)))
        for cfg in moved.blocks {
            #expect(cfg.visible == base.blocks.first { $0.kind == cfg.kind }?.visible)
        }
    }

    // MARK: - settingBlock / settingTile flip exactly one entry

    @Test func settingBlockFlipsOnlyTheTargetBlock() {
        let base = PopoverLayout.minimal
        let edited = base.settingBlock(.topProcesses, visible: true)
        #expect(blockVisible(edited, .topProcesses) == true)  // flipped
        // Every OTHER block's visibility is unchanged.
        for cfg in base.blocks where cfg.kind != .topProcesses {
            #expect(blockVisible(edited, cfg.kind) == cfg.visible)
        }
        // Order unchanged; tiles unchanged.
        #expect(edited.blocks.map(\.kind) == base.blocks.map(\.kind))
        #expect(edited.tiles == base.tiles)
    }

    @Test func settingBlockCanHideAndIsIdempotentInValue() {
        let base = PopoverLayout.balanced  // everything visible
        let hidden = base.settingBlock(.verdict, visible: false)
        #expect(blockVisible(hidden, .verdict) == false)
        // Setting the same value again yields an equal layout (pure).
        #expect(hidden.settingBlock(.verdict, visible: false) == hidden)
    }

    @Test func settingTileFlipsOnlyTheTargetTile() {
        let base = PopoverLayout.minimal  // battery hidden, rest visible
        let edited = base.settingTile(.battery, visible: true)
        #expect(tileVisible(edited, .battery) == true)  // flipped
        for cfg in base.tiles where cfg.kind != .battery {
            #expect(tileVisible(edited, cfg.kind) == cfg.visible)
        }
        // Canonical tile order preserved; blocks unchanged.
        #expect(edited.tiles.map(\.kind) == base.tiles.map(\.kind))
        #expect(edited.blocks == base.blocks)
    }

    @Test func settingUnknownlyAbsentEntryIsNoOp() {
        // A layout missing a given kind: setting it changes nothing.
        let sparse = PopoverLayout(
            blocks: [BlockConfig(kind: .verdict, visible: true)],
            tiles: [TileConfig(kind: .cpuTemp, visible: true)]
        )
        #expect(sparse.settingBlock(.recentActions, visible: true) == sparse)
        #expect(sparse.settingTile(.battery, visible: false) == sparse)
    }

    // MARK: - Reorder → JSON round-trip preserves the new order

    @Test func reorderRoundTripsThroughJSONPreservingOrder() {
        let moved = PopoverLayout.minimal.movingBlock(from: IndexSet(integer: 0), to: 3)
        let json = moved.toJSONString()
        let back = PopoverLayout(jsonString: json)
        #expect(back == moved)
        // The NEW order specifically survives the JSON codec.
        #expect(back?.blocks.map(\.kind) == [.attention, .systemOverview, .verdict, .topProcesses, .recentActions, .sevenDayChart, .topNet])
    }

    // MARK: - Toggle → persist → effectiveLayout yields the edited layout

    @Test func toggleThenEffectiveLayoutYieldsEditedLayout() {
        // Simulate the tab: fork the active preset by writing the edited JSON,
        // then resolve exactly as the popover does.
        let base = PopoverLayout.minimal
        let edited = base
            .settingBlock(.topProcesses, visible: true)
            .settingTile(.battery, visible: true)
        let producedJSON = edited.toJSONString()

        // The preset name still reads "minimal", but the non-empty JSON wins.
        let resolved = effectiveLayout(preset: "minimal", layoutJSON: producedJSON)
        #expect(resolved == edited)
        #expect(resolved != base)
        #expect(blockVisible(resolved, .topProcesses) == true)
        #expect(tileVisible(resolved, .battery) == true)
    }

    @Test func reorderThenEffectiveLayoutYieldsReorderedLayout() {
        let reordered = PopoverLayout.balanced.movingBlock(from: IndexSet(integer: 4), to: 0)
        let resolved = effectiveLayout(preset: "balanced", layoutJSON: reordered.toJSONString())
        #expect(resolved == reordered)
        #expect(resolved.blocks.first?.kind == .recentActions)
    }
}
