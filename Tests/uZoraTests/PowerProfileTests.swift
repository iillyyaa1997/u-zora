import Testing
import Foundation
@testable import uZora

@Suite("PowerProfile state composition + monitor")
struct PowerProfileTests {

    // MARK: - Pure state composition

    @Test("PowerSignals → PowerState table",
          arguments: [
              (PowerSignals(onAC: true,  lidOpen: true,  focusActive: false), PowerState.acConnectedLidOpen),
              (PowerSignals(onAC: true,  lidOpen: false, focusActive: false), PowerState.acConnectedLidClosed),
              (PowerSignals(onAC: false, lidOpen: true,  focusActive: false), PowerState.batteryLidOpen),
              (PowerSignals(onAC: false, lidOpen: false, focusActive: false), PowerState.batteryLidClosed),
              (PowerSignals(onAC: true,  lidOpen: true,  focusActive: true),  PowerState.focusActive),
              (PowerSignals(onAC: false, lidOpen: false, focusActive: true),  PowerState.focusActive),
          ])
    func composes(signals: PowerSignals, expected: PowerState) {
        #expect(PowerState.compose(from: signals) == expected)
    }

    // MARK: - Default mapping

    @Test func acLidOpen_baselineProfile() {
        let p = PowerProfile.defaultMapping(for: .acConnectedLidOpen)
        #expect(p.pollMultiplier == 1.0)
        #expect(p.alertSeverityFloor == .info)
    }

    @Test func acLidClosed_sameAsOpen() {
        let p = PowerProfile.defaultMapping(for: .acConnectedLidClosed)
        #expect(p.pollMultiplier == 1.0)
        #expect(p.alertSeverityFloor == .info)
    }

    @Test func batteryLidOpen_3xMultiplier() {
        let p = PowerProfile.defaultMapping(for: .batteryLidOpen)
        #expect(p.pollMultiplier == 3.0)
        #expect(p.alertSeverityFloor == .info)
    }

    @Test func batteryLidClosed_6xMultiplier_warnFloor() {
        let p = PowerProfile.defaultMapping(for: .batteryLidClosed)
        #expect(p.pollMultiplier == 6.0)
        #expect(p.alertSeverityFloor == .warn)
    }

    @Test func focusActive_criticalFloor() {
        let p = PowerProfile.defaultMapping(for: .focusActive)
        #expect(p.pollMultiplier == 1.0)
        #expect(p.alertSeverityFloor == .critical)
    }

    // MARK: - effectiveInterval

    @Test func effectiveInterval_baseline_unchanged() {
        let p = PowerProfile.defaultMapping(for: .acConnectedLidOpen)
        let interval = p.effectiveInterval(.seconds(10))
        #expect(interval == .seconds(10))
    }

    @Test func effectiveInterval_battery3x() {
        let p = PowerProfile.defaultMapping(for: .batteryLidOpen)
        let interval = p.effectiveInterval(.seconds(10))
        // 10 s * 3 = 30 s = 30_000_000_000 ns
        let nanos = interval.components.seconds * 1_000_000_000 + interval.components.attoseconds / 1_000_000_000
        #expect(nanos >= 29_000_000_000 && nanos <= 31_000_000_000)
    }

    @Test func effectiveInterval_neverBusyLoops() {
        // pollMultiplier zero would be a config bug; verify we never let it
        // collapse below 100 ms.
        let degenerate = PowerProfile(state: .acConnectedLidOpen, pollMultiplier: 0.0, alertSeverityFloor: .info)
        let interval = degenerate.effectiveInterval(.seconds(10))
        let nanos = interval.components.seconds * 1_000_000_000 + interval.components.attoseconds / 1_000_000_000
        #expect(nanos >= 100_000_000)
    }

    // MARK: - suppresses

    @Test func suppresses_belowFloor() {
        let p = PowerProfile.defaultMapping(for: .batteryLidClosed) // floor=warn
        #expect(p.suppresses(severity: .info))
        #expect(!p.suppresses(severity: .warn))
        #expect(!p.suppresses(severity: .critical))
    }

    // MARK: - Monitor

    @Test func monitorCurrent_usesInjectedReader() async {
        let signals = PowerSignals(onAC: false, lidOpen: true, focusActive: false)
        let monitor = PowerProfileMonitor(reader: { signals })
        let p = await monitor.current()
        #expect(p.state == .batteryLidOpen)
    }

    @Test func monitorObserve_firesImmediatelyWithCurrent() async {
        let signals = PowerSignals(onAC: true, lidOpen: false, focusActive: false)
        let monitor = PowerProfileMonitor(reader: { signals })

        // Use an actor box to capture from a @Sendable callback safely.
        actor Box {
            var received: [PowerProfile] = []
            func push(_ p: PowerProfile) { received.append(p) }
            func all() -> [PowerProfile] { received }
        }
        let box = Box()
        await monitor.observe { profile in
            Task { await box.push(profile) }
        }
        // Allow the observer task to run.
        try? await Task.sleep(for: .milliseconds(50))
        let received = await box.all()
        #expect(!received.isEmpty)
        #expect(received.first?.state == .acConnectedLidClosed)
    }
}
