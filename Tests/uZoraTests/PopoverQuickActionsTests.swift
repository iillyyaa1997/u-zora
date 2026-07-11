import Testing
import Foundation
import SwiftUI
@testable import uZora

/// Phase A4c (inline quick-actions + per-alert ack): the finding → probe →
/// action resolution helpers, the `availableActionsByProbe` data plumbing
/// (grouping active alerts + resolving through the REAL `ActionRegistry`), the
/// demo's seeded action, and a compile-level check that `PopoverView` threads
/// the two async handlers with REAL vs default (no-op) closures over both data
/// sources.
///
/// Model-layer assertions only (no view-snapshot harness): the button TAP
/// wiring isn't unit-testable without a UI harness, so these prove the pure
/// resolution + the data plumbing that decides whether a button renders.
@Suite("Popover quick actions (A4c)")
@MainActor
struct PopoverQuickActionsTests {

    // MARK: - Builders

    private func finding(detector: String, subject: String) -> Finding {
        let now = Date()
        return Finding(
            detector: detector, subject: subject, severity: .warn, confidence: .high,
            title: "t", explanation: "e", evidence: nil, suggestedAction: nil,
            firstSeen: now, lastUpdated: now
        )
    }

    // `import SwiftUI` also surfaces a deprecated `SwiftUI.Alert`, so pin the
    // app model's `uZora.Alert`.
    private func alert(probe: String, key: String, severity: Severity) -> uZora.Alert {
        let now = Date()
        return uZora.Alert(
            probe: probe, key: key, severity: severity, message: "m",
            details: nil, firstSeen: now, lastUpdated: now
        )
    }

    // MARK: - findingActionProbe: derive the probe token from the detector id

    @Test func findingActionProbeDerivesLeadingDetectorSegment() {
        // The REAL disk detector AND the demo's disk detector both → "disk"
        // (the token space of `ActionDescriptor.relatedProbe`).
        #expect(findingActionProbe(finding(detector: "disk_hard_critical", subject: "/")) == "disk")
        #expect(findingActionProbe(finding(detector: "disk_hard", subject: "/")) == "disk")
        // Non-actionable families derive their own (action-less) tokens.
        #expect(findingActionProbe(finding(detector: "memory_pressure", subject: "memory")) == "memory")
        #expect(findingActionProbe(finding(detector: "runaway_daemon", subject: "mdworker")) == "runaway")
        // No underscore → the whole detector id is the token.
        #expect(findingActionProbe(finding(detector: "disk", subject: "/")) == "disk")
    }

    // MARK: - availableActions(for:in:): finding → runnable actions via the map

    @Test func availableActionsResolvesDiskFindingToDiskActions() {
        let map: [String: [ActionDescriptor]] = ["disk": ActionRegistry.Descriptors.all]

        // A disk finding resolves to the disk actions → a "Fix" button shows.
        let diskActions = availableActions(
            for: finding(detector: "disk_hard_critical", subject: "/"),
            in: map
        )
        #expect(diskActions.count == ActionRegistry.Descriptors.all.count)
        #expect(diskActions.first?.id == ActionRegistry.Descriptors.pruneApfsSnapshots.id)

        // A non-disk / unmapped finding resolves to NONE → no button.
        let memActions = availableActions(
            for: finding(detector: "memory_pressure", subject: "memory"),
            in: map
        )
        #expect(memActions.isEmpty)

        let runawayActions = availableActions(
            for: finding(detector: "runaway_daemon", subject: "mdworker"),
            in: map
        )
        #expect(runawayActions.isEmpty)

        // An empty map (clean machine) resolves everything to none.
        #expect(availableActions(
            for: finding(detector: "disk_hard_critical", subject: "/"),
            in: [:]
        ).isEmpty)
    }

    // MARK: - probeSeverityFloors: group active alerts by probe (max severity)

    @Test func probeSeverityFloorsGroupsByProbeKeepingMaxSeverity() {
        let alerts = [
            alert(probe: "disk", key: "/", severity: .warn),
            alert(probe: "disk", key: "/vol2", severity: .critical),  // higher wins
            alert(probe: "cpu", key: "runaway", severity: .info),
        ]
        let floors = probeSeverityFloors(alerts)
        #expect(floors["disk"] == .critical)
        #expect(floors["cpu"] == .info)
        #expect(floors.count == 2)
        // Empty in → empty out (clean machine).
        #expect(probeSeverityFloors([]).isEmpty)
    }

    // MARK: - availableActionsByProbe resolved from active alerts via the REAL registry

    @Test func availableActionsByProbeResolvedFromAlertsThroughRegistry() async {
        // The four MVP actions all bind to `disk` at the `warn` floor.
        let registry = ActionRegistry.defaultPopulated()
        let config = ActionsConfig()

        // Direct registry contract (the resolution the data layer performs).
        let diskWarn = await registry.descriptorsFor(probe: "disk", severity: .warn, config: config)
        #expect(diskWarn.count == 4)
        let diskCritical = await registry.descriptorsFor(probe: "disk", severity: .critical, config: config)
        #expect(diskCritical.count == 4)
        // Below the floor → none (an info disk alert offers no actions).
        let diskInfo = await registry.descriptorsFor(probe: "disk", severity: .info, config: config)
        #expect(diskInfo.isEmpty)
        // Unmapped probe → none.
        let network = await registry.descriptorsFor(probe: "network", severity: .critical, config: config)
        #expect(network.isEmpty)

        // Full data-layer pipeline: active alerts → probeSeverityFloors →
        // descriptorsFor → the map the popover consumes. A disk warn + a
        // network critical yield ONLY a disk entry (network has no actions).
        let alerts = [
            alert(probe: "disk", key: "/", severity: .warn),
            alert(probe: "network", key: "eth0", severity: .critical),
        ]
        var map: [String: [ActionDescriptor]] = [:]
        for (probe, severity) in probeSeverityFloors(alerts) {
            let descriptors = await registry.descriptorsFor(probe: probe, severity: severity, config: config)
            if !descriptors.isEmpty { map[probe] = descriptors }
        }
        #expect(map.keys.sorted() == ["disk"])
        #expect(map["disk"]?.count == 4)

        // And that map lights up the disk finding's "Fix" button.
        #expect(!availableActions(for: finding(detector: "disk_hard_critical", subject: "/"), in: map).isEmpty)
    }

    // MARK: - DemoDataSource exposes a demo action (so the preview shows buttons)

    @Test func demoExposesDiskActionForPreview() {
        let demo = DemoDataSource(autostart: false)
        // The demo seeds a disk action so the Layout-tab preview renders the
        // finding-card "Fix" button (its degraded phase emits a disk finding).
        #expect(demo.availableActionsByProbe["disk"]?.isEmpty == false)

        // Walk to the `.degraded` phase (a disk finding) and confirm it resolves.
        for _ in 0..<8 where !demo.findings.contains(where: { findingActionProbe($0) == "disk" }) {
            demo.step()
        }
        let diskFinding = demo.findings.first { findingActionProbe($0) == "disk" }
        #expect(diskFinding != nil)
        if let diskFinding {
            #expect(!availableActions(for: diskFinding, in: demo.availableActionsByProbe).isEmpty)
        }
    }

    // MARK: - PopoverView threads the handlers (compile-level, both sources)

    @Test func popoverViewBuildsWithRealAndDefaultHandlersOverBothSources() {
        // REAL handlers (as PopoverGate wires them) over the demo source…
        let run: @Sendable (String) async -> Void = { _ in }
        let ack: @Sendable (uZora.Alert.ID) async -> Void = { _ in }
        let demo = DemoDataSource(autostart: false)
        _ = PopoverView(state: demo, layout: .power, onRunAction: run, onAck: ack)

        // …and the NO-OP defaults (as the preview/demo call sites use) over
        // the live UIState. If either handler weren't defaulted this call would
        // not type-check.
        _ = PopoverView(state: UIState(), layout: .power)

        // Real handlers over UIState too (the production PopoverGate shape).
        _ = PopoverView(state: UIState(), layout: .power, onRunAction: run, onAck: ack)

        // The map the finding card reads is on the read surface of both sources.
        #expect(demo.availableActionsByProbe["disk"] != nil)
        #expect(UIState().availableActionsByProbe.isEmpty)
    }
}
