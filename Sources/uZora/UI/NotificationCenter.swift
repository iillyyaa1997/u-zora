import Foundation
// @preconcurrency: UNUserNotificationCenter / UNNotificationRequest gained
// Sendable + actor-isolation annotations in the macOS 26 SDK but NOT the 15
// SDK. Without this, `await center.requestAuthorization(...)` / `center.add(req)`
// from this @MainActor class compile cleanly on a 26-SDK toolchain yet fail
// with "sending 'self.center'/'req' risks causing data races" on the
// macos-15 CI runner. @preconcurrency suppresses those module-origin Sendable
// diagnostics on the older SDK and is a no-op on 26 — the idiomatic portable
// fix for cross-SDK gradual-concurrency gaps.
@preconcurrency import UserNotifications
import AppKit
import os

/// Maps `WatchdogEvent` → `UNMutableNotificationContent` and posts via the
/// user notification center. Each probe gets a category with a single
/// 1-click *reversible* action (open Activity Monitor / Disk Utility /
/// Battery Settings / System Information). Action taps are routed through
/// the `UNUserNotificationCenterDelegate` to `NSWorkspace`.
///
/// Severity → interruption level mapping:
/// - critical → `.timeSensitive` + `defaultCritical` sound
/// - warn     → `.active`         + default sound
/// - info     → (never surfaces — filtered before this layer)
///
/// `notify` is no-op for alerts below the configured banner floor; the
/// caller still has full freedom to log + record the event through the
/// other channels (JSONL/SSE/MCP).
@MainActor
public final class UZoraNotificationCenter: NSObject, @preconcurrency UNUserNotificationCenterDelegate {

    public typealias EventHandler = @MainActor @Sendable (WatchdogEvent) async -> Void

    /// Handler invoked when the user taps a real-action "Run" button in a
    /// notification. Receives the alert's probe + severity so the
    /// `ActionRunner` can resolve the mapped action(s) and run them with
    /// `trigger: .confirmed`. Wired by `uZoraApp.bootstrap`.
    public typealias RunActionHandler = @Sendable (_ probe: String, _ severity: Severity) async -> Void

    private let center: UNUserNotificationCenter
    private var categoriesInstalled: Bool = false
    /// Q10: closure that runs the confirmed action(s) for a probe/severity.
    private var runActionHandler: RunActionHandler?
    /// Q10: probes that currently have at least one mapped action — only
    /// these categories carry a "Run" button. Populated from the
    /// ActionRegistry mapping at wire time (MVP: just "disk").
    private var actionableProbes: Set<String> = []
    private let log = Logger(subsystem: "place.unicorns.uzora", category: "notifications")

    public override init() {
        self.center = UNUserNotificationCenter.current()
        super.init()
        self.center.delegate = self
    }

    /// Wire the Q10 real-action button: which probes get a "Run" action and
    /// the closure to execute it. Re-installs categories so the new action
    /// button appears. Idempotent-safe.
    public func wireRunAction(actionableProbes: Set<String>, handler: @escaping RunActionHandler) {
        self.actionableProbes = actionableProbes
        self.runActionHandler = handler
        // Force a category re-install so the "Run" buttons are registered.
        self.categoriesInstalled = false
        installCategories()
    }

    /// Request authorization (banner, sound, alert). Idempotent — the
    /// system caches the user's first answer; this call returns immediately
    /// on subsequent launches.
    public func requestAuthorization() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            log.info("UN authorization granted=\(granted, privacy: .public)")
        } catch {
            log.warning("UN authorization request failed: \(String(describing: error), privacy: .public)")
        }
        installCategories()
    }

    /// Stable identifier prefix for the Q10 real-action "Run" button. The
    /// per-probe id is `uzora.act.run.<probe>` so the delegate can tell a
    /// "Run cleanup" tap from the legacy "open a tool" tap.
    public static let runActionIDPrefix = "uzora.act.run."

    /// Build categories for each probe. Each carries the legacy "open a
    /// tool" action; probes with at least one mapped Q10 action ALSO carry a
    /// "Run cleanup" real-action button (Q7).
    private func installCategories() {
        guard !categoriesInstalled else { return }
        categoriesInstalled = true
        let runTitle = String(localized: "Run cleanup", defaultValue: "Run cleanup")
        let categories: Set<UNNotificationCategory> = Set(
            NotificationActionMap.allCategories.map { entry in
                var actions: [UNNotificationAction] = [
                    UNNotificationAction(
                        identifier: entry.actionID,
                        title: entry.actionTitle,
                        options: [.foreground]
                    )
                ]
                // Add the real-action "Run" button only for probes that have
                // a mapped, runnable action (MVP: disk). The button itself is
                // NOT foreground — running cleanup shouldn't yank the user
                // into the app — and the actual policy gating (reversibility +
                // audit) happens in the ActionRunner with trigger=confirmed.
                if actionableProbes.contains(entry.probeName) {
                    actions.append(
                        UNNotificationAction(
                            identifier: Self.runActionIDPrefix + entry.probeName,
                            title: runTitle,
                            options: []
                        )
                    )
                }
                return UNNotificationCategory(
                    identifier: entry.categoryID,
                    actions: actions,
                    intentIdentifiers: [],
                    options: []
                )
            }
        )
        center.setNotificationCategories(categories)
    }

    /// Build a `UNNotificationRequest` for an event and submit it.
    /// Returns the constructed content (test affordance — `add` is best-
    /// effort with the system; tests assert on the content shape).
    @discardableResult
    public func notify(event: WatchdogEvent, config: NotificationsConfig, focusActive: Bool = false) async -> UNMutableNotificationContent? {
        guard let content = Self.contentIfShouldBanner(event: event, config: config, focusActive: focusActive) else {
            return nil
        }

        installCategories()

        let alertID: String
        switch event {
        case .appeared(let a): alertID = a.id
        case .escalated(let a, _): alertID = a.id
        case .cleared(let id): alertID = id
        }

        let req = UNNotificationRequest(
            identifier: "uzora.\(alertID)",
            content: content,
            trigger: nil    // deliver immediately
        )
        do {
            try await center.add(req)
        } catch {
            log.error("UN add() failed for \(alertID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        return content
    }

    /// Pure filter + content builder, factored out so tests can validate
    /// the full mapping without instantiating UNUserNotificationCenter
    /// (which requires a bundle proxy unavailable under `swift test`).
    public static func contentIfShouldBanner(
        event: WatchdogEvent,
        config: NotificationsConfig,
        focusActive: Bool
    ) -> UNMutableNotificationContent? {
        let alert: Alert? = {
            switch event {
            case .appeared(let a): return a
            case .escalated(let a, _): return a
            case .cleared: return nil
            }
        }()
        guard let alert else { return nil }
        guard alert.severity >= config.bannerSeverityFloor else { return nil }
        if config.respectFocus, focusActive, alert.severity == .warn {
            return nil
        }
        return makeContent(for: alert)
    }

    /// Pure content builder. Exposed for unit testing.
    public static func makeContent(for alert: Alert) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(alert.probe.uppercased()): \(alert.key)"
        content.body = alert.message
        switch alert.severity {
        case .critical:
            content.interruptionLevel = .timeSensitive
            content.sound = .defaultCritical
        case .warn:
            content.interruptionLevel = .active
            content.sound = .default
        case .info:
            content.interruptionLevel = .passive
            content.sound = nil
        }
        let category = NotificationActionMap.lookup(probe: alert.probe)
        content.categoryIdentifier = category.categoryID
        content.userInfo = [
            "probe": alert.probe,
            "key": alert.key,
            "severity": alert.severity.rawValue,
            "action_target": category.targetURL.absoluteString,
        ]
        return content
    }

    /// Stable identifier — same alert.id reuses the slot so a re-escalation
    /// updates the pre-existing banner instead of stacking.
    public static func notificationID(for event: WatchdogEvent, alert: Alert) -> String {
        "uzora.\(alert.id)"
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even while uZora is foregrounded.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Handle a tap on a notification action button.
    ///
    /// - The Q10 "Run cleanup" real-action (`uzora.act.run.<probe>`) routes to
    ///   the `runActionHandler` with the alert's probe + severity, which runs
    ///   the mapped action(s) through the ActionRunner with
    ///   `trigger: .confirmed` (the user explicitly clicked).
    /// - Any other action (legacy "open a tool" + the default body tap) opens
    ///   the category's target URL.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionID = response.actionIdentifier

        if actionID.hasPrefix(Self.runActionIDPrefix), let handler = runActionHandler {
            let probe = (userInfo["probe"] as? String)
                ?? String(actionID.dropFirst(Self.runActionIDPrefix.count))
            let severity = (userInfo["severity"] as? String).flatMap { Severity(rawValue: $0) } ?? .warn
            Task {
                await handler(probe, severity)
                completionHandler()
            }
            return
        }

        if let urlString = userInfo["action_target"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}

/// Per-probe categorisation: each probe maps to a category ID, a single
/// action ID, an action button title, and the URL that's opened on tap.
public struct NotificationActionMap: Sendable {
    public let categoryID: String
    public let actionID: String
    public let actionTitle: String
    public let targetURL: URL
    /// The probe name this category is for — used to attach the Q10 "Run"
    /// real-action button to the right categories + resolve the action(s)
    /// on tap.
    public let probeName: String

    public static let allCategories: [NotificationActionMap] = [
        .disk, .topCPU, .topMem, .topNet, .kernelTask,
        .battery, .cpuTemp, .thermal, .fan, .smart,
    ]

    /// Resolve a category by probe name. Falls back to a generic
    /// "open uZora" entry if the probe name is unknown.
    public static func lookup(probe: String) -> NotificationActionMap {
        switch probe {
        case "disk": return .disk
        case "top_cpu": return .topCPU
        case "top_mem": return .topMem
        case "top_net": return .topNet
        case "kernel_task": return .kernelTask
        case "battery": return .battery
        case "cpu_temp": return .cpuTemp
        case "thermal": return .thermal
        case "fan": return .fan
        case "smart": return .smart
        default: return .generic
        }
    }

    // MARK: - Static entries
    //
    // Action URLs:
    // - System Settings panes: `x-apple.systempreferences:<bundle-id>` URLs
    // - Bundled utilities: `file://` paths under /System/Applications/Utilities
    //   (Activity Monitor, Disk Utility, System Information all live there)

    public static let disk = NotificationActionMap(
        categoryID: "uzora.cat.disk",
        actionID: "uzora.act.disk",
        actionTitle: String(localized: "Show Disk Usage", defaultValue: "Show Disk Usage"),
        targetURL: URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"),
        probeName: "disk"
    )
    public static let topCPU = NotificationActionMap(
        categoryID: "uzora.cat.topcpu",
        actionID: "uzora.act.topcpu",
        actionTitle: String(localized: "Open Activity Monitor", defaultValue: "Open Activity Monitor"),
        targetURL: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
        probeName: "top_cpu"
    )
    public static let topMem = NotificationActionMap(
        categoryID: "uzora.cat.topmem",
        actionID: "uzora.act.topmem",
        actionTitle: String(localized: "Open Activity Monitor", defaultValue: "Open Activity Monitor"),
        targetURL: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
        probeName: "top_mem"
    )
    public static let topNet = NotificationActionMap(
        categoryID: "uzora.cat.topnet",
        actionID: "uzora.act.topnet",
        actionTitle: String(localized: "Open Activity Monitor", defaultValue: "Open Activity Monitor"),
        targetURL: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
        probeName: "top_net"
    )
    public static let kernelTask = NotificationActionMap(
        categoryID: "uzora.cat.kerneltask",
        actionID: "uzora.act.kerneltask",
        actionTitle: String(localized: "Open Activity Monitor", defaultValue: "Open Activity Monitor"),
        targetURL: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
        probeName: "kernel_task"
    )
    public static let battery = NotificationActionMap(
        categoryID: "uzora.cat.battery",
        actionID: "uzora.act.battery",
        actionTitle: String(localized: "Open Battery Settings", defaultValue: "Open Battery Settings"),
        targetURL: URL(string: "x-apple.systempreferences:com.apple.preference.battery")!,
        probeName: "battery"
    )
    public static let cpuTemp = NotificationActionMap(
        categoryID: "uzora.cat.cputemp",
        actionID: "uzora.act.cputemp",
        actionTitle: String(localized: "Show Thermal Report", defaultValue: "Show Thermal Report"),
        targetURL: URL(fileURLWithPath: "/System/Applications/Utilities/System Information.app"),
        probeName: "cpu_temp"
    )
    public static let thermal = NotificationActionMap(
        categoryID: "uzora.cat.thermal",
        actionID: "uzora.act.thermal",
        actionTitle: String(localized: "Show Thermal Report", defaultValue: "Show Thermal Report"),
        targetURL: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
        probeName: "thermal"
    )
    public static let fan = NotificationActionMap(
        categoryID: "uzora.cat.fan",
        actionID: "uzora.act.fan",
        actionTitle: String(localized: "Show Thermal Report", defaultValue: "Show Thermal Report"),
        targetURL: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
        probeName: "fan"
    )
    public static let smart = NotificationActionMap(
        categoryID: "uzora.cat.smart",
        actionID: "uzora.act.smart",
        actionTitle: String(localized: "Open System Information", defaultValue: "Open System Information"),
        targetURL: URL(fileURLWithPath: "/System/Applications/Utilities/System Information.app"),
        probeName: "smart"
    )
    public static let generic = NotificationActionMap(
        categoryID: "uzora.cat.generic",
        actionID: "uzora.act.generic",
        actionTitle: String(localized: "Show Details", defaultValue: "Show Details"),
        targetURL: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
        probeName: "generic"
    )
}
