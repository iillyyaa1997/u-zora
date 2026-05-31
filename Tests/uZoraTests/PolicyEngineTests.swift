import Testing
import Foundation
@testable import uZora

/// Gate-chain coverage for the Q10 PolicyEngine. Each gate is exercised in
/// isolation (deny) plus the all-pass allow case, with an injected clock +
/// Context so verdicts are deterministic.
@Suite("PolicyEngine — gate chain")
struct PolicyEngineTests {

    // A reversible, auto-eligible descriptor (the kind that can pass).
    private func descriptor(reversible: Bool = true, id: String = "prune_apfs_snapshots") -> ActionDescriptor {
        ActionDescriptor(
            id: id,
            name: "n", detail: "d",
            reversible: reversible, requiresSudo: false,
            relatedProbe: "disk", relatedSeverityFloor: .warn
        )
    }

    /// A config with the given action opted-in + all gates configurable.
    private func config(
        id: String = "prune_apfs_snapshots",
        autoEnabled: Bool = true,
        powerGate: Bool = true,
        focusGate: Bool = true,
        coolDownEnabled: Bool = true,
        coolDownMinutes: Int = 30,
        rateLimitEnabled: Bool = true,
        rateLimitPerHour: Int = 6
    ) -> ActionsConfig {
        var c = ActionsConfig(
            coolDownEnabled: coolDownEnabled,
            coolDownMinutes: coolDownMinutes,
            rateLimitEnabled: rateLimitEnabled,
            rateLimitPerHour: rateLimitPerHour,
            powerGate: powerGate,
            focusGate: focusGate
        )
        c.setOverride(ActionOverride(autoEnabled: autoEnabled), for: id)
        return c
    }


    /// Config with EVERY MVP action opted-in (so rate-limit tests can use
    /// several distinct action ids without tripping the enabled gate first).
    private func allOptedInConfig(
        coolDownEnabled: Bool = true,
        coolDownMinutes: Int = 30,
        rateLimitEnabled: Bool = true,
        rateLimitPerHour: Int = 6
    ) -> ActionsConfig {
        var c = ActionsConfig(
            coolDownEnabled: coolDownEnabled,
            coolDownMinutes: coolDownMinutes,
            rateLimitEnabled: rateLimitEnabled,
            rateLimitPerHour: rateLimitPerHour
        )
        for d in ActionsConfig.descriptors {
            c.setOverride(ActionOverride(autoEnabled: true), for: d.id)
        }
        return c
    }

    private func ctx(
        power: PowerState = .acConnectedLidOpen,
        focus: Bool = false,
        config: ActionsConfig
    ) -> PolicyEngine.Context {
        PolicyEngine.Context(powerState: power, focusActive: focus, config: config)
    }

    // MARK: - Allow

    @Test func allow_whenEverythingPasses() async {
        let engine = PolicyEngine()
        let d = await engine.evaluate(descriptor: descriptor(), trigger: .auto, context: ctx(config: config()))
        #expect(d == .allow)
        #expect(d.auditString == "allow")
    }

    // MARK: - Gate 1: reversibility

    @Test func deny_notReversible_evenWhenConfirmed() async {
        let engine = PolicyEngine()
        // Auto:
        let dAuto = await engine.evaluate(descriptor: descriptor(reversible: false), trigger: .auto, context: ctx(config: config()))
        #expect(dAuto == .deny(.notReversible))
        // Confirmed STILL enforces reversibility (a non-reversible action is
        // never silently run, even on an explicit click).
        let dConfirmed = await engine.evaluate(descriptor: descriptor(reversible: false), trigger: .confirmed, context: ctx(config: config()))
        #expect(dConfirmed == .deny(.notReversible))
    }

    // MARK: - Gate 2: enabled (per-action opt-in)

    @Test func deny_notEnabled_byDefault() async {
        let engine = PolicyEngine()
        // Default config = auto_enabled false for every action (Q3).
        let d = await engine.evaluate(descriptor: descriptor(), trigger: .auto, context: ctx(config: ActionsConfig()))
        #expect(d == .deny(.notEnabled))
    }

    @Test func confirmed_bypassesEnabledGate() async {
        let engine = PolicyEngine()
        // auto_enabled false, but a CONFIRMED click is allowed.
        let d = await engine.evaluate(descriptor: descriptor(), trigger: .confirmed, context: ctx(config: ActionsConfig()))
        #expect(d == .allow)
    }

    // MARK: - Gate 3: power

    @Test func deny_onBattery_whenPowerGateOn() async {
        let engine = PolicyEngine()
        let d = await engine.evaluate(descriptor: descriptor(), trigger: .auto, context: ctx(power: .batteryLidOpen, config: config(powerGate: true)))
        #expect(d == .deny(.onBattery))
    }

    @Test func allow_onBattery_whenPowerGateOff() async {
        let engine = PolicyEngine()
        let d = await engine.evaluate(descriptor: descriptor(), trigger: .auto, context: ctx(power: .batteryLidClosed, config: config(powerGate: false)))
        #expect(d == .allow)
    }

    // MARK: - Gate 4: focus

    @Test func deny_focusActive_whenFocusGateOn() async {
        let engine = PolicyEngine()
        let d = await engine.evaluate(descriptor: descriptor(), trigger: .auto, context: ctx(focus: true, config: config(focusGate: true)))
        #expect(d == .deny(.focusActive))
    }

    @Test func allow_focusActive_whenFocusGateOff() async {
        let engine = PolicyEngine()
        let d = await engine.evaluate(descriptor: descriptor(), trigger: .auto, context: ctx(focus: true, config: config(focusGate: false)))
        #expect(d == .allow)
    }

    // MARK: - Gate 5: cool-down

    @Test func deny_withinCoolDown_thenAllowAfter() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clockBox = ClockBox(t0)
        let engine = PolicyEngine(clock: { clockBox.now })
        let cfg = config(coolDownEnabled: true, coolDownMinutes: 30)

        // First run allowed; record it.
        let d1 = await engine.evaluate(descriptor: descriptor(), trigger: .auto, context: ctx(config: cfg))
        #expect(d1 == .allow)
        await engine.recordRun(actionID: "prune_apfs_snapshots", trigger: .auto)

        // 10 minutes later → still within the 30-min cool-down → deny.
        clockBox.now = t0.addingTimeInterval(10 * 60)
        let d2 = await engine.evaluate(descriptor: descriptor(), trigger: .auto, context: ctx(config: cfg))
        #expect(d2 == .deny(.coolDown))

        // 31 minutes later → past the window → allow.
        clockBox.now = t0.addingTimeInterval(31 * 60)
        let d3 = await engine.evaluate(descriptor: descriptor(), trigger: .auto, context: ctx(config: cfg))
        #expect(d3 == .allow)
    }

    @Test func coolDown_disabled_neverBlocks() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clockBox = ClockBox(t0)
        let engine = PolicyEngine(clock: { clockBox.now })
        let cfg = config(coolDownEnabled: false, coolDownMinutes: 30, rateLimitEnabled: false)
        let d1 = await engine.evaluate(descriptor: descriptor(), trigger: .auto, context: ctx(config: cfg))
        #expect(d1 == .allow)
        await engine.recordRun(actionID: "prune_apfs_snapshots", trigger: .auto)
        // 1 second later — cool-down off → still allowed.
        clockBox.now = t0.addingTimeInterval(1)
        let d2 = await engine.evaluate(descriptor: descriptor(), trigger: .auto, context: ctx(config: cfg))
        #expect(d2 == .allow)
    }

    // MARK: - Gate 6: rate-limit

    @Test func deny_whenRateLimitHit() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clockBox = ClockBox(t0)
        let engine = PolicyEngine(clock: { clockBox.now })
        // rate=2/hr, cool-down OFF so only rate-limit gates.
        let cfg = allOptedInConfig(coolDownEnabled: false, rateLimitEnabled: true, rateLimitPerHour: 2)

        // Two auto runs (using two different action ids so cool-down — even
        // though disabled — is irrelevant; rate-limit is global across actions).
        for id in ["prune_apfs_snapshots", "clear_derived_data"] {
            let d = await engine.evaluate(descriptor: descriptor(id: id), trigger: .auto, context: ctx(config: cfg))
            #expect(d == .allow)
            await engine.recordRun(actionID: id, trigger: .auto)
            clockBox.now = clockBox.now.addingTimeInterval(60) // 1 min apart
        }
        let count = await engine.autoRunsInWindow()
        #expect(count == 2)

        // Third within the hour → rate-limited.
        let d3 = await engine.evaluate(descriptor: descriptor(id: "brew_cleanup"), trigger: .auto, context: ctx(config: cfg))
        #expect(d3 == .deny(.rateLimit))

        // After the rolling hour elapses, the window empties → allow again.
        clockBox.now = t0.addingTimeInterval(3601)
        let d4 = await engine.evaluate(descriptor: descriptor(id: "brew_cleanup"), trigger: .auto, context: ctx(config: cfg))
        #expect(d4 == .allow)
    }

    @Test func rateLimit_confirmedRunsDoNotConsumeBudget() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clockBox = ClockBox(t0)
        let engine = PolicyEngine(clock: { clockBox.now })
        let cfg = allOptedInConfig(coolDownEnabled: false, rateLimitEnabled: true, rateLimitPerHour: 1)
        // A confirmed run records a cool-down stamp but NOT an auto-budget hit.
        await engine.recordRun(actionID: "prune_apfs_snapshots", trigger: .confirmed)
        let count = await engine.autoRunsInWindow()
        #expect(count == 0)
        // So an auto run is still allowed (budget untouched by the confirmed run).
        let d = await engine.evaluate(descriptor: descriptor(id: "clear_derived_data"), trigger: .auto, context: ctx(config: cfg))
        #expect(d == .allow)
    }

    // MARK: - dry-run

    @Test func dryRun_isAllowedForReversible_andDistinct() async {
        let engine = PolicyEngine()
        let d = await engine.evaluate(descriptor: descriptor(), trigger: .dryRun, context: ctx(config: ActionsConfig()))
        #expect(d == .dryRun)
        #expect(d.auditString == "dry_run")
        #expect(d.isAllowed)
    }

    // MARK: - unknown action

    @Test func deny_unknownAction() async {
        let engine = PolicyEngine()
        let d = await engine.evaluate(descriptor: descriptor(id: "not_a_real_action"), trigger: .auto, context: ctx(config: ActionsConfig()))
        #expect(d == .deny(.unknownAction))
    }
}

/// Mutable clock for injecting deterministic time into the actor-based engine.
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ d: Date) { _now = d }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); _now = newValue; lock.unlock() }
    }
}
