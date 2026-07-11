import Testing
import Foundation
import SwiftUI
@testable import uZora

/// Phase A1 (render foundation): the injectable `PopoverDataSource`, the
/// `WidgetKind` render switch, and the `DemoDataSource` motion generator.
///
/// There is no view-snapshot harness — these assert at the model layer that
/// (a) the demo populates every block's inputs, (b) the verdict cycles with
/// motion, and (c) `UIState`'s conformance is behavior-preserving (its own
/// tint/label mapping equals the shared `PopoverDataSource` mapping).
@Suite("Popover render foundation")
@MainActor
struct PopoverRenderTests {

    // Generic helpers: exercise the values THROUGH the protocol (as the render
    // switch does) so the tests also prove the generic surface compiles.
    private func verdictTint<S: PopoverDataSource>(_ s: S) -> Color { s.verdictTint }
    private func severityTint<S: PopoverDataSource>(_ s: S) -> Color { s.overallSeverityTint }
    private func uptime<S: PopoverDataSource>(_ s: S) -> String { s.uptimeLabel }
    private func verdictLevel<S: PopoverDataSource>(_ s: S) -> VerdictLevel { s.verdict }

    // MARK: - DemoDataSource drives every block

    @Test func demoPopulatesEveryWidgetKind() {
        // autostart:false → a fully-populated static snapshot, no live timer.
        let demo = DemoDataSource(autostart: false)

        #expect(WidgetKind.allCases.count == 5)

        // Every content block must have non-empty inputs in the initial snapshot.
        for kind in WidgetKind.allCases {
            switch kind {
            case .verdict:
                #expect(!demo.verdictHeadline.isEmpty)
                #expect(!demo.findings.isEmpty)
                #expect(demo.verdict != .good)  // starts on a non-clear phase
            case .attention:
                #expect(!demo.activeAlerts.isEmpty)
            case .systemOverview:
                // >1 so MetricTile draws the Chart rather than the placeholder.
                #expect(demo.cpuTempHistory.count > 1)
                #expect(demo.diskFreeHistory.count > 1)
                #expect(demo.batteryHistory.count > 1)
                #expect(demo.memoryHistory.count > 1)
                #expect(demo.cpuTempLabel != "—")
                #expect(demo.diskFreeLabel != "—")
                #expect(demo.batteryLabel != "—")
                #expect(demo.memoryLabel != "—")
            case .topProcesses:
                #expect(!demo.topCPUProcesses.isEmpty)
                #expect(!demo.topMemProcesses.isEmpty)
            case .recentActions:
                #expect(!demo.recentActions.isEmpty)
            }
        }

        // Chrome inputs (header + footer) are populated too.
        #expect(!demo.powerStateLabel.isEmpty)
        #expect(!uptime(demo).isEmpty)
        #expect(demo.httpAlive)  // HTTP dot always on in the demo
    }

    // MARK: - Motion

    @Test func demoVerdictCyclesThroughAllLevels() {
        let demo = DemoDataSource(autostart: false)
        var seen: Set<VerdictLevel> = [verdictLevel(demo)]
        // One full cycle is 4 phases; step a few extra to be safe.
        for _ in 0..<6 {
            demo.step()
            seen.insert(demo.verdict)
        }
        #expect(seen == Set(VerdictLevel.allCases))

        // The `.good` phase clears findings + alerts; a non-good phase has them.
        // Advance until we land on `.good` and confirm the clear.
        for _ in 0..<4 where demo.verdict != .good { demo.step() }
        if demo.verdict == .good {
            #expect(demo.findings.isEmpty)
            #expect(demo.activeAlerts.isEmpty)
            #expect(demo.overallSeverity == nil)
        }
    }

    @Test func demoSparklinesMove() {
        let demo = DemoDataSource(autostart: false)
        let before = demo.cpuTempHistory
        demo.step()
        let after = demo.cpuTempHistory
        // Ring buffer stays capped; the trailing sample advances (motion).
        #expect(after.count == 60)
        #expect(after.last != before.last)
    }

    // MARK: - Demo tints derive from the shared mapping

    @Test func demoTintsMatchSharedMapping() {
        let demo = DemoDataSource(autostart: false)
        #expect(verdictTint(demo) == popoverVerdictTint(demo.verdict))
        #expect(severityTint(demo) == popoverSeverityTint(demo.overallSeverity))
    }

    // MARK: - UIState conformance is behavior-preserving

    @Test func uiStateConformsAndPreservesTintMapping() {
        let state = UIState()

        // Severity tint: UIState's own computed var must equal the shared
        // mapping the protocol layer (and DemoDataSource) use.
        state.overallSeverity = .warn
        #expect(state.overallSeverityTint == .yellow)
        #expect(state.overallSeverityTint == popoverSeverityTint(state.overallSeverity))
        #expect(severityTint(state) == state.overallSeverityTint)

        // Verdict tint: same, driven through applyDiagnosis (unchanged path).
        let f = Finding(
            detector: "d", subject: "s", severity: .critical, confidence: .high,
            title: "Disk full", explanation: "why", evidence: nil,
            suggestedAction: nil,
            firstSeen: Date(timeIntervalSince1970: 1000),
            lastUpdated: Date(timeIntervalSince1970: 1100)
        )
        state.applyDiagnosis(Verdict.derive(from: [f]))
        #expect(state.verdict == .problem)
        #expect(state.verdictTint == .red)
        #expect(state.verdictTint == popoverVerdictTint(state.verdict))
        #expect(verdictTint(state) == state.verdictTint)
        #expect(verdictLevel(state) == .problem)

        // Values read through the generic surface match the stored fields.
        #expect(state.findings.count == 1)
        #expect(state.verdictHeadline == "Disk full")
    }

    // MARK: - Shared mapping unit coverage

    @Test func sharedMappingIsCorrect() {
        #expect(popoverSeverityTint(nil) == .gray)
        #expect(popoverSeverityTint(.info) == .blue)
        #expect(popoverSeverityTint(.warn) == .yellow)
        #expect(popoverSeverityTint(.critical) == .red)

        #expect(popoverVerdictTint(.good) == .green)
        #expect(popoverVerdictTint(.watch) == .blue)
        #expect(popoverVerdictTint(.degraded) == .orange)
        #expect(popoverVerdictTint(.problem) == .red)

        let t0 = Date(timeIntervalSince1970: 10_000)
        #expect(popoverUptimeLabel(since: t0, now: t0.addingTimeInterval(12)) == "uptime 12s")
        #expect(popoverUptimeLabel(since: t0, now: t0.addingTimeInterval(90)) == "uptime 1m")
        #expect(popoverUptimeLabel(since: t0, now: t0.addingTimeInterval(7200)) == "uptime 2h")
    }

    // MARK: - A4a expanded-catalog tiles

    /// The demo drives the five A4a catalog tiles too: labels leave "—" and the
    /// sparklines have >1 point so `MetricTile` draws a chart, not a placeholder.
    @Test func demoPopulatesExpandedCatalogTiles() {
        let demo = DemoDataSource(autostart: false)
        #expect(demo.gpuHistory.count > 1)
        #expect(demo.swapInHistory.count > 1)
        #expect(demo.kernelTaskHistory.count > 1)
        #expect(demo.coresPinnedHistory.count > 1)
        #expect(demo.gpuLabel != "—")
        #expect(demo.swapInLabel != "—")
        #expect(demo.kernelTaskLabel != "—")
        #expect(demo.coresPinnedLabel != "—")
    }

    /// The four new `recordMetric` probe-strings each append to the matching
    /// `*History` buffer AND set the `*Label`, exactly like the original tiles.
    @Test func recordMetricDrivesExpandedCatalogFields() {
        let state = UIState()

        state.recordMetric(probe: "gpu", value: 42)
        #expect(state.gpuLabel == "42%")
        #expect(state.gpuHistory == [42])

        state.recordMetric(probe: "cores_pinned", value: 3)
        #expect(state.coresPinnedLabel == "3")
        #expect(state.coresPinnedHistory == [3])

        state.recordMetric(probe: "swap_in", value: 120)
        #expect(state.swapInLabel == "120/s")
        #expect(state.swapInHistory == [120])

        state.recordMetric(probe: "kernel_task", value: 8)
        #expect(state.kernelTaskLabel == "8%")
        #expect(state.kernelTaskHistory == [8])

        // Ring-buffer cap holds at 60 samples (parity with the original tiles).
        for _ in 0..<70 { state.recordMetric(probe: "gpu", value: 50) }
        #expect(state.gpuHistory.count == 60)
    }

    // MARK: - Env gate defaults off

    @Test func demoEnvGateDefaultsOff() {
        // The operator's real environment must not have the flag during tests;
        // if it does, this asserts the truthy contract instead.
        let raw = ProcessInfo.processInfo.environment["UZORA_DEMO_POPOVER"]
        if raw == nil || raw?.isEmpty == true {
            #expect(DemoDataSource.isEnabledInEnvironment == false)
        } else {
            let v = raw!.lowercased()
            let expected = v != "0" && v != "false" && v != "no"
            #expect(DemoDataSource.isEnabledInEnvironment == expected)
        }
    }
}
