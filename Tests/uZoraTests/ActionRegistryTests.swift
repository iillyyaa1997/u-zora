import Testing
import Foundation
@testable import uZora

@Suite("ActionRegistry — registration + hybrid mapping")
struct ActionRegistryTests {

    @Test func defaultPopulated_hasFourActions() async {
        let reg = ActionRegistry.defaultPopulated()
        let all = await reg.all()
        #expect(all.count == 4)
        let ids = await reg.allDescriptors().map(\.id)
        #expect(ids == ["prune_apfs_snapshots", "clear_derived_data", "brew_cleanup", "clear_user_caches"])
    }

    @Test func allActionsAreReversibleNoSudo() async {
        let reg = ActionRegistry.defaultPopulated()
        for d in await reg.allDescriptors() {
            #expect(d.reversible, "\(d.id) must be reversible in this iteration")
            #expect(!d.requiresSudo, "\(d.id) must not require sudo in this iteration")
            #expect(d.relatedProbe == "disk")
            #expect(d.relatedSeverityFloor == .warn)
        }
    }

    @Test func clearUserCaches_isFlaggedCaution() async {
        let reg = ActionRegistry.defaultPopulated()
        let caches = await reg.descriptor(id: "clear_user_caches")
        #expect(caches?.caution == true)
        // The others are NOT caution.
        for id in ["prune_apfs_snapshots", "clear_derived_data", "brew_cleanup"] {
            let d = await reg.descriptor(id: id)
            #expect(d?.caution == false, "\(id) should not be caution-flagged")
        }
    }

    @Test func action_lookupById() async {
        let reg = ActionRegistry.defaultPopulated()
        #expect(await reg.action(id: "brew_cleanup") != nil)
        #expect(await reg.action(id: "nope") == nil)
    }

    // MARK: - actionsFor (hybrid mapping + config override)

    @Test func actionsFor_diskWarn_returnsAllFour_byDefault() async {
        let reg = ActionRegistry.defaultPopulated()
        let mapped = await reg.actionsFor(probe: "disk", severity: .warn, config: ActionsConfig())
        #expect(mapped.count == 4)
    }

    @Test func actionsFor_diskCritical_returnsAllFour() async {
        let reg = ActionRegistry.defaultPopulated()
        // critical >= warn floor → still all four.
        let mapped = await reg.actionsFor(probe: "disk", severity: .critical, config: ActionsConfig())
        #expect(mapped.count == 4)
    }

    @Test func actionsFor_belowFloor_returnsNone() async {
        let reg = ActionRegistry.defaultPopulated()
        // info < warn floor → no actions eligible.
        let mapped = await reg.actionsFor(probe: "disk", severity: .info, config: ActionsConfig())
        #expect(mapped.isEmpty)
    }

    @Test func actionsFor_otherProbe_returnsNone_byDefault() async {
        let reg = ActionRegistry.defaultPopulated()
        let mapped = await reg.actionsFor(probe: "cpu_temp", severity: .critical, config: ActionsConfig())
        #expect(mapped.isEmpty)
    }

    @Test func actionsFor_configOverride_remapsProbe() async {
        let reg = ActionRegistry.defaultPopulated()
        // Config-override (Q6): bind brew_cleanup to cpu_temp instead of disk.
        var cfg = ActionsConfig()
        cfg.setOverride(ActionOverride(autoEnabled: false, probe: "cpu_temp"), for: "brew_cleanup")
        // Now disk no longer maps brew_cleanup (3 left), cpu_temp maps it (1).
        let onDisk = await reg.actionsFor(probe: "disk", severity: .warn, config: cfg).map { $0.descriptor.id }
        #expect(!onDisk.contains("brew_cleanup"))
        #expect(onDisk.count == 3)
        let onCPU = await reg.actionsFor(probe: "cpu_temp", severity: .warn, config: cfg).map { $0.descriptor.id }
        #expect(onCPU == ["brew_cleanup"])
    }

    @Test func actionsFor_configOverride_raisesSeverityFloor() async {
        let reg = ActionRegistry.defaultPopulated()
        // Override clear_user_caches to require critical (not warn).
        var cfg = ActionsConfig()
        cfg.setOverride(ActionOverride(severityFloor: .critical), for: "clear_user_caches")
        // At warn: clear_user_caches now excluded (3 remain).
        let atWarn = await reg.actionsFor(probe: "disk", severity: .warn, config: cfg).map { $0.descriptor.id }
        #expect(!atWarn.contains("clear_user_caches"))
        #expect(atWarn.count == 3)
        // At critical: all four again.
        let atCrit = await reg.actionsFor(probe: "disk", severity: .critical, config: cfg)
        #expect(atCrit.count == 4)
    }

    @Test func descriptorTable_idMappingRoundTrips() {
        // The ActionsConfig descriptor table is the single source of truth —
        // each id resolves to a distinct keypath and round-trips.
        var cfg = ActionsConfig()
        for d in ActionsConfig.descriptors {
            cfg.setOverride(ActionOverride(autoEnabled: true), for: d.id)
            #expect(cfg[id: d.id]?.autoEnabled == true)
        }
        // Unknown id → nil subscript + no-op setter.
        #expect(cfg[id: "ghost"] == nil)
        cfg.setOverride(ActionOverride(autoEnabled: true), for: "ghost") // no crash, no-op
    }
}
