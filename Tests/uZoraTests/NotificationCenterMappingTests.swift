import Testing
import Foundation
@preconcurrency import UserNotifications  // cross-SDK Sendable gap (see NotificationCenter.swift)
@testable import uZora

@Suite("NotificationCenter event → content mapping")
struct NotificationCenterMappingTests {

    private func makeAlert(probe: String, severity: Severity, key: String = "k") -> Alert {
        Alert(
            probe: probe,
            key: key,
            severity: severity,
            message: "msg",
            details: ["pid": "42", "command": "demo", "cpu_pct": "90.5"],
            firstSeen: Date(timeIntervalSince1970: 1000),
            lastUpdated: Date(timeIntervalSince1970: 1100)
        )
    }

    @Test @MainActor func makeContent_critical_interruptionLevelAndSound() {
        let alert = makeAlert(probe: "disk", severity: .critical)
        let content = UZoraNotificationCenter.makeContent(for: alert)
        #expect(content.title == "DISK: k")
        #expect(content.body == "msg")
        #expect(content.interruptionLevel == .timeSensitive)
        #expect(content.sound == .defaultCritical)
        #expect(content.categoryIdentifier == "uzora.cat.disk")
    }

    @Test @MainActor func makeContent_warn_interruptionLevel() {
        let alert = makeAlert(probe: "top_cpu", severity: .warn)
        let content = UZoraNotificationCenter.makeContent(for: alert)
        #expect(content.interruptionLevel == .active)
        #expect(content.sound == .default)
        #expect(content.categoryIdentifier == "uzora.cat.topcpu")
    }

    @Test @MainActor func makeContent_info_passive() {
        let alert = makeAlert(probe: "fan", severity: .info)
        let content = UZoraNotificationCenter.makeContent(for: alert)
        #expect(content.interruptionLevel == .passive)
        #expect(content.sound == nil)
    }

    @Test @MainActor func actionMap_dispatchTable() {
        let cases: [(String, String, String)] = [
            ("disk", "uzora.cat.disk", "Show Disk Usage"),
            ("top_cpu", "uzora.cat.topcpu", "Open Activity Monitor"),
            ("top_mem", "uzora.cat.topmem", "Open Activity Monitor"),
            ("top_net", "uzora.cat.topnet", "Open Activity Monitor"),
            ("kernel_task", "uzora.cat.kerneltask", "Open Activity Monitor"),
            ("battery", "uzora.cat.battery", "Open Battery Settings"),
            ("cpu_temp", "uzora.cat.cputemp", "Show Thermal Report"),
            ("thermal", "uzora.cat.thermal", "Show Thermal Report"),
            ("fan", "uzora.cat.fan", "Show Thermal Report"),
            ("smart", "uzora.cat.smart", "Open System Information"),
            ("unknown_probe", "uzora.cat.generic", "Show Details"),
        ]
        for (probe, expectedCategoryID, expectedTitle) in cases {
            let entry = NotificationActionMap.lookup(probe: probe)
            #expect(entry.categoryID == expectedCategoryID, "probe=\(probe)")
            #expect(entry.actionTitle == expectedTitle, "probe=\(probe)")
        }
    }

    @Test @MainActor func actionMap_diskTargetsDiskUtility() {
        let entry = NotificationActionMap.lookup(probe: "disk")
        // Compare against the raw path (URL-encoded `absoluteString` swaps
        // spaces for `%20`; the path component is human-readable).
        #expect(entry.targetURL.path.contains("Disk Utility.app"))
    }

    @Test @MainActor func actionMap_batteryTargetsSettings() {
        let entry = NotificationActionMap.lookup(probe: "battery")
        #expect(entry.targetURL.absoluteString.hasPrefix("x-apple.systempreferences:"))
    }

    @Test @MainActor func actionMap_topCPUTargetsActivityMonitor() {
        let entry = NotificationActionMap.lookup(probe: "top_cpu")
        #expect(entry.targetURL.path.contains("Activity Monitor.app"))
    }

    @Test @MainActor func notificationID_stableAcrossEvents() {
        let alert = makeAlert(probe: "disk", severity: .warn, key: "/")
        let appeared = WatchdogEvent.appeared(alert)
        let escalated = WatchdogEvent.escalated(alert, previousSeverity: .info)
        let id1 = UZoraNotificationCenter.notificationID(for: appeared, alert: alert)
        let id2 = UZoraNotificationCenter.notificationID(for: escalated, alert: alert)
        #expect(id1 == id2, "same alert.id should produce the same UN identifier")
        #expect(id1 == "uzora.disk:/")
    }

    @Test @MainActor func makeContent_userInfo_includesActionTarget() {
        let alert = makeAlert(probe: "battery", severity: .critical)
        let content = UZoraNotificationCenter.makeContent(for: alert)
        let target = content.userInfo["action_target"] as? String
        #expect(target?.hasPrefix("x-apple.systempreferences:") == true)
        #expect(content.userInfo["probe"] as? String == "battery")
        #expect(content.userInfo["severity"] as? String == "critical")
    }

    /// B2: the LLM-requested run-approval banner names the action, uses the
    /// approval category, and carries the SPECIFIC action id in userInfo so the
    /// "Approve" tap runs THAT id via the confirmed path.
    @Test @MainActor func makeApprovalContent_carriesActionID_andCategory() {
        let content = UZoraNotificationCenter.makeApprovalContent(
            actionID: "prune_apfs_snapshots",
            actionName: "Prune local APFS snapshots"
        )
        #expect(content.title.contains("Prune local APFS snapshots"))
        #expect(content.categoryIdentifier == UZoraNotificationCenter.approvalCategoryID)
        #expect(content.userInfo[UZoraNotificationCenter.approvalActionIDKey] as? String == "prune_apfs_snapshots")
    }

    /// Table-test that mirrors the README documentation: each probe maps to
    /// a single, deterministic action button label.
    @Test @MainActor func actionMap_completeProbeCoverage() {
        let expected: [String: String] = [
            "disk":         "Show Disk Usage",
            "top_cpu":      "Open Activity Monitor",
            "top_mem":      "Open Activity Monitor",
            "top_net":      "Open Activity Monitor",
            "kernel_task":  "Open Activity Monitor",
            "battery":      "Open Battery Settings",
            "cpu_temp":     "Show Thermal Report",
            "thermal":      "Show Thermal Report",
            "fan":          "Show Thermal Report",
            "smart":        "Open System Information",
        ]
        for (probe, title) in expected {
            let entry = NotificationActionMap.lookup(probe: probe)
            #expect(entry.actionTitle == title, "probe=\(probe)")
        }
    }
}

@Suite("NotificationCenter banner-floor + Focus filtering")
struct NotificationFilterTests {

    private func makeAlert(severity: Severity, probe: String = "disk") -> Alert {
        Alert(
            probe: probe,
            key: "k",
            severity: severity,
            message: "msg",
            details: nil,
            firstSeen: Date(),
            lastUpdated: Date()
        )
    }

    // Use the pure static decision function so tests don't need a real
    // UNUserNotificationCenter instance (unavailable under `swift test`
    // without an app bundle).

    @Test @MainActor func warn_belowFloor_isFiltered() {
        let config = NotificationsConfig(bannerSeverityFloor: .critical, respectFocus: false)
        let event = WatchdogEvent.appeared(makeAlert(severity: .warn))
        let content = UZoraNotificationCenter.contentIfShouldBanner(event: event, config: config, focusActive: false)
        #expect(content == nil, "warn below critical floor must be suppressed")
    }

    @Test @MainActor func critical_atOrAboveFloor_passes() {
        let config = NotificationsConfig(bannerSeverityFloor: .warn, respectFocus: false)
        let event = WatchdogEvent.appeared(makeAlert(severity: .critical))
        let content = UZoraNotificationCenter.contentIfShouldBanner(event: event, config: config, focusActive: false)
        #expect(content?.interruptionLevel == .timeSensitive)
    }

    @Test @MainActor func warn_duringFocus_isSuppressedWhenRespectFocusOn() {
        let config = NotificationsConfig(bannerSeverityFloor: .warn, respectFocus: true)
        let event = WatchdogEvent.appeared(makeAlert(severity: .warn))
        let content = UZoraNotificationCenter.contentIfShouldBanner(event: event, config: config, focusActive: true)
        #expect(content == nil)
    }

    @Test @MainActor func critical_duringFocus_pierces() {
        let config = NotificationsConfig(bannerSeverityFloor: .warn, respectFocus: true)
        let event = WatchdogEvent.appeared(makeAlert(severity: .critical))
        let content = UZoraNotificationCenter.contentIfShouldBanner(event: event, config: config, focusActive: true)
        #expect(content != nil)
        #expect(content?.interruptionLevel == .timeSensitive)
    }

    @Test @MainActor func cleared_isNeverBannered() {
        let config = NotificationsConfig(bannerSeverityFloor: .info, respectFocus: false)
        let event = WatchdogEvent.cleared("disk:/")
        let content = UZoraNotificationCenter.contentIfShouldBanner(event: event, config: config, focusActive: false)
        #expect(content == nil)
    }

    @Test @MainActor func warn_atFloor_passesWhenRespectFocusOff() {
        let config = NotificationsConfig(bannerSeverityFloor: .warn, respectFocus: false)
        let event = WatchdogEvent.appeared(makeAlert(severity: .warn))
        let content = UZoraNotificationCenter.contentIfShouldBanner(event: event, config: config, focusActive: true)
        #expect(content?.interruptionLevel == .active)
    }

    @Test @MainActor func info_neverBannerAtCriticalFloor() {
        let config = NotificationsConfig(bannerSeverityFloor: .critical, respectFocus: false)
        let event = WatchdogEvent.appeared(makeAlert(severity: .info))
        let content = UZoraNotificationCenter.contentIfShouldBanner(event: event, config: config, focusActive: false)
        #expect(content == nil)
    }

    @Test @MainActor func escalatedEvent_alsoBanners() {
        let config = NotificationsConfig(bannerSeverityFloor: .warn, respectFocus: false)
        let event = WatchdogEvent.escalated(makeAlert(severity: .critical), previousSeverity: .warn)
        let content = UZoraNotificationCenter.contentIfShouldBanner(event: event, config: config, focusActive: false)
        #expect(content?.interruptionLevel == .timeSensitive)
    }
}
