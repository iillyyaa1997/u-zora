import Testing
import Foundation
@testable import uZora

/// Regression coverage for two watchdog/boot bugs:
///
///  - P0 #3: boot doesn't reconcile persisted alerts against the current
///    config — an alert for a probe the user has since DISABLED is reloaded by
///    `loadState` (no enabled-filter), seeded into StateStore/UIState, and then
///    never ticks to clear → lingers forever.
///  - P0 #4: a watchdog *de-escalation* (critical→warn, which emits no event)
///    updated in-memory state but did NOT persist, so a restart reloaded the
///    stale HIGHER severity and seeded StateStore wrong.
@Suite("Watchdog boot-reconcile + de-escalation persistence")
struct WatchdogReconcileTests {

    private static func tempStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("uzora-watchdog-reconcile-tests")
            .appendingPathComponent("\(UUID().uuidString).json")
    }

    private static func alert(_ probe: String, _ key: String, _ sev: Severity) -> Alert {
        Alert(probe: probe, key: key, severity: sev, message: "\(probe):\(key)", details: nil, firstSeen: Date(), lastUpdated: Date())
    }

    // ========================================================================
    // MARK: - P0 #3: boot reconcile drops alerts for disabled probes
    // ========================================================================

    /// THE repro: a `disk:/` alert is persisted; "boot" with disk DISABLED
    /// (disk absent from the registered set) must (a) drop it from the
    /// watchdog snapshot AND (b) remove it from the on-disk state file so a
    /// relaunch can't resurrect it. Mirrors `reconfigure`'s dropped-probe
    /// cleanup for the cold-start path.
    @Test func bootReconcile_dropsDisabledProbeAlert_andPurgesStateFile() async throws {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Run 1: a disk alert fires and persists.
        let wd1 = Watchdog(stateURL: url)
        _ = await wd1.step(probe: "disk", currentAlerts: [Self.alert("disk", "/", .warn)])
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Simulate relaunch: a fresh watchdog loads the persisted disk alert
        // (loadState applies no enabled-filter, so it's there).
        let wd2 = Watchdog(stateURL: url)
        #expect(await wd2.snapshot()["disk:/"] != nil)

        // Boot reconcile against a registered set that DISABLES disk.
        let registered: Set<String> = ["cpu_temp", "thermal", "battery", "smart", "fan",
                                       "kernel_task", "top_cpu", "top_mem", "top_net"]
        let clears = await wd2.reconcileAgainstRegistered(registered)

        // The disk alert was synthesised-cleared…
        #expect(clears.contains(.cleared("disk:/")))
        // …gone from the in-memory snapshot…
        #expect(await wd2.snapshot()["disk:/"] == nil)

        // …and gone from the on-disk state file (a third launch can't resurrect it).
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode([String: Alert].self, from: data)
        #expect(onDisk["disk:/"] == nil)

        // A subsequent fresh watchdog confirms the alert is truly gone.
        let wd3 = Watchdog(stateURL: url)
        #expect(await wd3.snapshot()["disk:/"] == nil)
    }

    /// Reconcile must NOT touch alerts for probes that are still registered.
    @Test func bootReconcile_keepsRegisteredProbeAlerts() async {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd1 = Watchdog(stateURL: url)
        _ = await wd1.step(probe: "disk", currentAlerts: [Self.alert("disk", "/", .warn)])
        _ = await wd1.step(probe: "cpu_temp", currentAlerts: [Self.alert("cpu_temp", "package", .critical)])

        let wd2 = Watchdog(stateURL: url)
        // Disable disk only; cpu_temp stays registered.
        let clears = await wd2.reconcileAgainstRegistered(["cpu_temp"])
        #expect(clears.contains(.cleared("disk:/")))
        #expect(await wd2.snapshot()["disk:/"] == nil)
        #expect(await wd2.snapshot()["cpu_temp:package"] != nil) // preserved
    }

    /// No dropped probes → reconcile is a no-op (empty result, file untouched).
    @Test func bootReconcile_allRegistered_isNoOp() async throws {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd1 = Watchdog(stateURL: url)
        _ = await wd1.step(probe: "disk", currentAlerts: [Self.alert("disk", "/", .warn)])
        let mtime1 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        let wd2 = Watchdog(stateURL: url)
        try await Task.sleep(for: .milliseconds(30))
        let clears = await wd2.reconcileAgainstRegistered(["disk", "cpu_temp"])
        #expect(clears.isEmpty)
        // File not rewritten.
        let mtime2 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(mtime1 == mtime2)
        #expect(await wd2.snapshot()["disk:/"] != nil)
    }

    // ========================================================================
    // MARK: - P0 #4: de-escalation is persisted
    // ========================================================================

    /// THE repro: step a probe to critical (persists), then step the SAME id
    /// down to warn (a de-escalation → NO event). The persisted file must now
    /// record warn — otherwise a restart reloads critical and seeds wrong.
    /// Uses the per-probe step (the production API).
    @Test func deEscalation_perProbeStep_persistsLowerSeverity() async throws {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let wd = Watchdog(stateURL: url)
        let crit = await wd.step(probe: "cpu_temp", currentAlerts: [Self.alert("cpu_temp", "package", .critical)])
        #expect(crit.contains(.appeared(Self.alert("cpu_temp", "package", .critical))) || !crit.isEmpty)

        // De-escalate to warn: same id, lower severity → silent (no event).
        let warnEvents = await wd.step(probe: "cpu_temp", currentAlerts: [Self.alert("cpu_temp", "package", .warn)])
        #expect(warnEvents.isEmpty, "de-escalation must emit no event")

        // The on-disk file must now record WARN, not the stale critical.
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode([String: Alert].self, from: data)
        #expect(onDisk["cpu_temp:package"]?.severity == .warn)

        // And a fresh watchdog (simulating restart) reloads WARN.
        let wd2 = Watchdog(stateURL: url)
        #expect(await wd2.snapshot()["cpu_temp:package"]?.severity == .warn)
    }

    /// Same bug via the full-snapshot `step(currentAlerts:)` variant.
    @Test func deEscalation_fullSnapshotStep_persistsLowerSeverity() async throws {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let wd = Watchdog(stateURL: url)
        _ = await wd.step(currentAlerts: [Self.alert("cpu_temp", "package", .critical)])
        let warnEvents = await wd.step(currentAlerts: [Self.alert("cpu_temp", "package", .warn)])
        #expect(warnEvents.isEmpty)

        let wd2 = Watchdog(stateURL: url)
        #expect(await wd2.snapshot()["cpu_temp:package"]?.severity == .warn)
    }

    /// The idempotent-tick invariant still holds: a re-tick at the SAME
    /// severity (only lastUpdated differs) does NOT rewrite the file.
    @Test func sameSeverityReTick_doesNotRewriteFile() async throws {
        let url = Self.tempStateURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let wd = Watchdog(stateURL: url)
        _ = await wd.step(probe: "disk", currentAlerts: [Self.alert("disk", "/", .warn)])
        let mtime1 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(40))
        // Same id, same severity (new lastUpdated) → no event, no rewrite.
        let events = await wd.step(probe: "disk", currentAlerts: [Self.alert("disk", "/", .warn)])
        #expect(events.isEmpty)
        let mtime2 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(mtime1 == mtime2, "same-severity re-tick must not rewrite the state file")
    }
}
