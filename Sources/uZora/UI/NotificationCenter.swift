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

    /// B2: handler invoked when the user taps "Approve" on an LLM-requested
    /// run-approval notification. Receives the SPECIFIC action id the LLM asked
    /// for; runs THAT id via the `ActionRunner` with `trigger: .confirmed` (the
    /// same explicit-confirmation path as the alert "Run cleanup" button). Wired
    /// by `uZoraApp.bootstrap` next to `wireRunAction`.
    public typealias RunActionByIDHandler = @Sendable (_ actionID: String) async -> Void

    private let center: UNUserNotificationCenter
    private var categoriesInstalled: Bool = false
    /// Q10: closure that runs the confirmed action(s) for a probe/severity.
    private var runActionHandler: RunActionHandler?
    /// B2: closure that runs one confirmed action by id (LLM-requested approval).
    private var runActionByIDHandler: RunActionByIDHandler?
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

    /// B2: wire the LLM-requested run-approval path — the closure that runs one
    /// action by id when the user taps "Approve" on an approval notification.
    /// Re-installs categories so the approval category/button is registered.
    /// Idempotent-safe; independent of `wireRunAction`.
    public func wireRunActionByID(handler: @escaping RunActionByIDHandler) {
        self.runActionByIDHandler = handler
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

    /// B2: dedicated category + button id for an LLM-requested run-approval
    /// notification. The category carries a single "Approve" button; the tap
    /// reads the requested action id from `userInfo["approve_action_id"]` and
    /// runs THAT id via `runActionByIDHandler` (trigger `.confirmed`).
    public static let approvalCategoryID = "uzora.cat.approve"
    public static let approvalActionID = "uzora.act.approve.run"
    /// `userInfo` key carrying the specific action id an approval banner is for.
    public static let approvalActionIDKey = "approve_action_id"

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
        // B2: the LLM-requested run-approval category — a single "Approve run"
        // button (NOT foreground; approving shouldn't yank the user into the
        // app). Always installed; the tap only does anything once
        // `runActionByIDHandler` is wired.
        let approveTitle = String(localized: "Approve run", defaultValue: "Approve run")
        let approvalCategory = UNNotificationCategory(
            identifier: Self.approvalCategoryID,
            actions: [
                UNNotificationAction(
                    identifier: Self.approvalActionID,
                    title: approveTitle,
                    options: []
                )
            ],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories(categories.union([approvalCategory]))
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

    /// B2 — post an LLM-requested run-approval banner for a SPECIFIC action id.
    /// The banner carries the id in `userInfo` and offers a single "Approve"
    /// button; tapping it runs THAT id via `runActionByIDHandler`
    /// (`trigger: .confirmed`). The run happens ONLY on the tap — this method
    /// just posts the request. Returns the content (test affordance; `add` is
    /// best-effort). Called from `RESTHandlers.runAction`'s human-tap gate.
    @discardableResult
    public func requestRunApproval(actionID: String, actionName: String) async -> UNMutableNotificationContent? {
        installCategories()
        let content = Self.makeApprovalContent(actionID: actionID, actionName: actionName)
        let req = UNNotificationRequest(
            identifier: "uzora.approve.\(actionID)",
            content: content,
            trigger: nil    // deliver immediately
        )
        do {
            try await center.add(req)
        } catch {
            log.error("UN add() failed for run-approval \(actionID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        return content
    }

    /// Void-returning wrapper over `requestRunApproval` for the bridge's
    /// `approvalRequester` closure. The closure is `@Sendable` and crosses the
    /// actor boundary; the non-Sendable `UNMutableNotificationContent?` result
    /// must NOT ride back out, so this discards it here on the MainActor.
    public func postRunApproval(actionID: String, actionName: String) async {
        _ = await requestRunApproval(actionID: actionID, actionName: actionName)
    }

    /// Pure content builder for a B2 run-approval banner. Exposed (static) so
    /// tests validate the shape without a live UNUserNotificationCenter (mirrors
    /// `makeContent` / `makeFindingContent`).
    static func makeApprovalContent(actionID: String, actionName: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Approve run of \(actionName)?"
        content.body = String(
            localized: "Requested via the LLM bridge. Tap Approve to run.",
            defaultValue: "Requested via the LLM bridge. Tap Approve to run."
        )
        content.interruptionLevel = .active
        content.sound = .default
        content.categoryIdentifier = approvalCategoryID
        content.userInfo = [
            approvalActionIDKey: actionID,
        ]
        return content
    }

    /// Phase 4 — post a banner for a diagnosis `FindingEvent` using the
    /// two-track policy (see `contentIfShouldNotify`). Mirrors
    /// `notify(event:…)`: builds content via the pure decision fn, installs
    /// categories, submits the request, and returns the content (or `nil`
    /// when the event is suppressed — a no-op). Lives in this file so it
    /// inherits `@preconcurrency import UserNotifications`.
    @discardableResult
    public func notifyFinding(event: FindingEvent, config: NotificationsConfig) async -> UNMutableNotificationContent? {
        guard let content = Self.contentIfShouldNotify(findingEvent: event, config: config) else {
            return nil
        }

        installCategories()

        // Identifier: stable per finding id so a rediagnosis updates the
        // existing banner instead of stacking.
        let findingID: String
        switch event {
        case .diagnosed(let f): findingID = f.id
        case .rediagnosed(let f, _, _): findingID = f.id
        case .resolved(let id): findingID = id
        }

        let req = UNNotificationRequest(
            identifier: "uzora.finding.\(findingID)",
            content: content,
            trigger: nil    // deliver immediately
        )
        do {
            try await center.add(req)
        } catch {
            log.error("UN add() failed for finding \(findingID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        return content
    }

    /// Pure two-track finding-notification decision + content builder (plan
    /// D5 / R1). Factored out so tests validate the policy without a real
    /// UNUserNotificationCenter (mirrors `contentIfShouldBanner`).
    ///
    /// Tracks:
    ///  - **Resolved / info** → `nil` (no "all-clear" spam; info is advisory).
    ///  - **Hard track** — a `.critical` finding ALWAYS notifies, immediately
    ///    and aggressively (`.timeSensitive` + `defaultCritical` sound). No
    ///    dwell, no confidence gate — a hard critical (disk ≥90%, R1) is never
    ///    softened by the anti-cry-wolf philosophy.
    ///  - **Trend track** — a `.warn` finding notifies ONLY at `.high`
    ///    confidence (the detector's own dwell already gated time; this is the
    ///    high-confidence edge), with `.active` + default sound. `warn` at
    ///    `.low`/`.medium` confidence is SUPPRESSED (the "unnamed slowdown"
    ///    cry-wolf class) → `nil`.
    public static func contentIfShouldNotify(
        findingEvent: FindingEvent,
        config: NotificationsConfig
    ) -> UNMutableNotificationContent? {
        let finding: Finding
        switch findingEvent {
        case .resolved:
            return nil
        case .diagnosed(let f):
            finding = f
        case .rediagnosed(let f, _, _):
            finding = f
        }

        switch finding.severity {
        case .critical:
            // Hard track — always fire.
            return makeFindingContent(for: finding, interruption: .timeSensitive, sound: .defaultCritical)
        case .warn:
            // Trend track — only at the high-confidence edge.
            guard finding.confidence >= .high else { return nil }
            return makeFindingContent(for: finding, interruption: .active, sound: .default)
        case .info:
            return nil
        }
    }

    /// Pure content builder for a diagnosis `Finding`. Exposed (internal) so
    /// `contentIfShouldNotify` stays declarative; mirrors `makeContent(for:)`.
    static func makeFindingContent(
        for finding: Finding,
        interruption: UNNotificationInterruptionLevel,
        sound: UNNotificationSound?
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = finding.title
        content.body = finding.explanation
        content.interruptionLevel = interruption
        content.sound = sound
        content.categoryIdentifier = NotificationActionMap.diagnosis.categoryID
        content.userInfo = [
            "detector": finding.detector,
            "subject": finding.subject,
            "severity": finding.severity.rawValue,
            "confidence": finding.confidence.rawValue,
            "suggested_action": finding.suggestedAction ?? "",
            "action_target": NotificationActionMap.diagnosis.targetURL.absoluteString,
        ]
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

        // B2: an "Approve run" tap on an LLM-requested approval banner runs the
        // SPECIFIC action id carried in userInfo, via the confirmed run path.
        if actionID == Self.approvalActionID,
           let handler = runActionByIDHandler,
           let requestedID = userInfo[Self.approvalActionIDKey] as? String {
            Task {
                await handler(requestedID)
                completionHandler()
            }
            return
        }

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
        .diagnosis,
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

    /// Phase 4 diagnosis findings: a dedicated category so finding banners
    /// carry a "Show in Activity Monitor" action (plan D5 — v1 unfixable
    /// action = text + "Show in Activity Monitor", NO "Restart Mac" button).
    /// `probeName` is the synthetic `"diagnosis"` source — findings aren't
    /// probes, but the field keys the category and (deliberately) is NOT in
    /// `actionableProbes`, so no Q10 "Run cleanup" button is attached.
    public static let diagnosis = NotificationActionMap(
        categoryID: "uzora.cat.diagnosis",
        actionID: "uzora.act.diagnosis",
        actionTitle: String(localized: "Show in Activity Monitor", defaultValue: "Show in Activity Monitor"),
        targetURL: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
        probeName: "diagnosis"
    )
}
