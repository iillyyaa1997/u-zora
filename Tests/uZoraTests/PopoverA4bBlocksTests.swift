import Testing
import Foundation
@testable import uZora

/// Phase A4b: the two new opt-in content blocks — the 7-day history sparkline
/// (`sevenDayChart`) and the top-network-talkers list (`topNet`). These assert
/// at the model layer (no view harness): the block catalog grew to seven with
/// both new blocks default-OFF in every preset, the JSON codec round-trips them
/// when enabled, the pure hourly-bucketing reducer averages correctly, the
/// byte-rate formatter, and that the demo source populates both fields.
@Suite("Popover A4b blocks (7-day chart + top_net)")
struct PopoverA4bBlocksTests {

    private func blockVisible(_ layout: PopoverLayout, _ kind: WidgetKind) -> Bool? {
        layout.blocks.first { $0.kind == kind }?.visible
    }

    // MARK: - Catalog + presets

    @Test func widgetKindCatalogHasSevenKinds() {
        #expect(WidgetKind.allCases.count == 7)
        #expect(WidgetKind.allCases.contains(.sevenDayChart))
        #expect(WidgetKind.allCases.contains(.topNet))
    }

    /// A4b: both new blocks are PRESENT but default-OFF in EVERY preset (D4),
    /// appended after `recentActions` (deterministic tail order).
    @Test func newBlocksAreDefaultOffInEveryPreset() {
        for layout in [PopoverLayout.minimal, .balanced, .diagnosis, .power] {
            #expect(blockVisible(layout, .sevenDayChart) == false)
            #expect(blockVisible(layout, .topNet) == false)
            // Appended after recentActions, in this order.
            #expect(layout.blocks.suffix(2).map(\.kind) == [.sevenDayChart, .topNet])
            #expect(layout.blocks.count == WidgetKind.allCases.count)
        }
    }

    // MARK: - JSON round-trip with the new blocks ENABLED

    @Test func jsonRoundTripPreservesEnabledNewBlocks() {
        let custom = PopoverLayout(
            blocks: [
                BlockConfig(kind: .systemOverview, visible: true),
                BlockConfig(kind: .sevenDayChart, visible: true),
                BlockConfig(kind: .topNet, visible: true),
            ],
            tiles: []
        )
        let back = PopoverLayout(jsonString: custom.toJSONString())
        #expect(back == custom)
        #expect(back?.blocks.map(\.kind) == [.systemOverview, .sevenDayChart, .topNet])
        #expect(back?.blocks.map(\.visible) == [true, true, true])
    }

    // MARK: - bucketHourly (pure 7-day reducer)

    @Test func bucketHourlyAveragesEachHourBucket() {
        // Bucket A = epoch [0, 3600): values 10, 20 → avg 15.
        // Bucket B = epoch [3600, 7200): values 30, 40 → avg 35.
        let samples = [
            sample(at: 0, value: 10),
            sample(at: 1800, value: 20),
            sample(at: 3600, value: 30),
            sample(at: 5400, value: 40),
        ]
        // Deliberately out of order to prove ordering is by bucket, ascending.
        let shuffled = [samples[3], samples[0], samples[2], samples[1]]
        #expect(bucketHourly(shuffled) == [15, 35])
    }

    @Test func bucketHourlyEmptyInputIsEmpty() {
        #expect(bucketHourly([]) == [])
    }

    @Test func bucketHourlySingleSampleIsThatValue() {
        #expect(bucketHourly([sample(at: 12345, value: 42.5)]) == [42.5])
    }

    private func sample(at epoch: TimeInterval, value: Double) -> MetricsStore.Sample {
        MetricsStore.Sample(
            probe: "cpu_temp", key: "package", name: "temp_c",
            value: value, at: Date(timeIntervalSince1970: epoch)
        )
    }

    // MARK: - Byte-rate formatter

    @Test func byteRateFormatterUsesBinaryUnits() {
        #expect(popoverByteRateString(0) == "0 B/s")
        #expect(popoverByteRateString(512) == "512 B/s")
        #expect(popoverByteRateString(1024) == "1 KB/s")
        #expect(popoverByteRateString(348_160) == "340 KB/s")       // 340 * 1024
        #expect(popoverByteRateString(2_097_152) == "2.0 MB/s")     // 2 * 1024^2
        #expect(popoverByteRateString(3_221_225_472) == "3.0 GB/s") // 3 * 1024^3
    }

    @Test func netRateStringPairsDownAndUp() {
        #expect(popoverNetRateString(inPerSec: 348_160, outPerSec: 0) == "340 KB/s ↓ / 0 B/s ↑")
        #expect(popoverNetRateString(inPerSec: 2_097_152, outPerSec: 1024) == "2.0 MB/s ↓ / 1 KB/s ↑")
    }

    // MARK: - Block-visibility gate (D-C3.iv) — samplers only work when shown

    @Test func blockVisibleGateHonorsEffectiveLayout() {
        // Default preset (empty JSON) ⇒ both A4b blocks OFF, so the samplers
        // skip their expensive work.
        #expect(blockIsVisibleInLayout(.topNet, preset: PresetName.default.rawValue, layoutJSON: "") == false)
        #expect(blockIsVisibleInLayout(.sevenDayChart, preset: "minimal", layoutJSON: "") == false)
        // A visible original block reads true (sanity: the gate isn't just false).
        #expect(blockIsVisibleInLayout(.verdict, preset: "minimal", layoutJSON: "") == true)

        // A customized layoutJSON that ENABLES topNet wins over the preset ⇒ the
        // Network sampler will run once the user opts in.
        let enabled = PopoverLayout(
            blocks: [BlockConfig(kind: .topNet, visible: true)],
            tiles: []
        )
        #expect(blockIsVisibleInLayout(.topNet, preset: "minimal", layoutJSON: enabled.toJSONString()) == true)
        // A block ABSENT from the custom layout ⇒ not visible (present-AND-visible).
        #expect(blockIsVisibleInLayout(.sevenDayChart, preset: "minimal", layoutJSON: enabled.toJSONString()) == false)

        // Garbage JSON falls back to the named preset (both blocks off there).
        #expect(blockIsVisibleInLayout(.topNet, preset: "balanced", layoutJSON: "not json{") == false)
    }

    // MARK: - DemoDataSource populates both new fields

    @MainActor
    @Test func demoPopulatesNewBlockFields() {
        let demo = DemoDataSource(autostart: false)
        // >1 so SevenDayChartBlock draws a chart, not EmptyView.
        #expect(demo.sevenDayHistory.count > 1)
        // A couple of fake talkers so the Network block renders.
        #expect(!demo.topNetProcesses.isEmpty)
        let first = demo.topNetProcesses[0]
        #expect(!first.command.isEmpty)
        #expect(first.bytesInPerSec > 0 || first.bytesOutPerSec > 0)
    }
}
