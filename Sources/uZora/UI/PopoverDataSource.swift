import SwiftUI

/// The exact read surface the menu-bar popover blocks consume.
///
/// `PopoverView` is generic over this protocol so it can render either the
/// live `UIState` (production) or a `DemoDataSource` (motion demo / manual
/// verification) with **no behavior change** — every widget stays
/// value-driven and both sources share the tint/label mapping below.
///
/// The protocol is `@MainActor` to match `UIState` (a `@MainActor` class):
/// SwiftUI reads these on the main actor and `@Published` mutations happen
/// there too. It refines `ObservableObject` so `@ObservedObject var state:
/// Source` re-renders the popover on each tick that mutates a published field.
///
/// Note: `@ObservedObject` needs a concrete/generic `ObservableObject`, not an
/// existential — call sites therefore use `PopoverView<UIState>` /
/// `PopoverView<DemoDataSource>` (type inferred), never `any PopoverDataSource`.
@MainActor
protocol PopoverDataSource: ObservableObject {
    // Header chrome.
    var powerStateLabel: String { get }
    var overallSeverity: Severity? { get }
    var startedAt: Date { get }

    // Verdict card.
    var verdict: VerdictLevel { get }
    var verdictHeadline: String { get }
    var findings: [Finding] { get }

    // Attention zone (== the current "Active alerts" block; the redesign of
    // this block lands in a later phase — A1 keeps the current rendering).
    var activeAlerts: [Alert] { get }

    // System overview tiles.
    var cpuTempLabel: String { get }
    var diskFreeLabel: String { get }
    var batteryLabel: String { get }
    var memoryLabel: String { get }
    var cpuTempHistory: [Double] { get }
    var diskFreeHistory: [Double] { get }
    var batteryHistory: [Double] { get }
    var memoryHistory: [Double] { get }

    // Top processes.
    var topCPUProcesses: [UIState.ProcessSnap] { get }
    var topMemProcesses: [UIState.ProcessSnap] { get }

    // Recent actions.
    var recentActions: [AuditLog.Entry] { get }

    // Channel status (footer).
    var httpAlive: Bool { get }
    var mcpAlive: Bool { get }
    var jsonlAlive: Bool { get }

    // Shared computed surface. Declared as requirements so a concrete source
    // MAY override them (UIState keeps its own identical impls, unchanged),
    // but the default implementations below are the single shared mapping the
    // protocol layer — and `DemoDataSource` — reuse. Kept in sync with
    // UIState's copies by `PopoverRenderTests`.
    var uptimeLabel: String { get }
    var overallSeverityTint: Color { get }
    var verdictTint: Color { get }
}

extension PopoverDataSource {
    var uptimeLabel: String { popoverUptimeLabel(since: startedAt) }
    var overallSeverityTint: Color { popoverSeverityTint(overallSeverity) }
    var verdictTint: Color { popoverVerdictTint(verdict) }
}

// MARK: - Shared tint / label mapping

/// Menu-bar / header tint for the raw-probe overall severity.
/// none=gray, info=blue, warn=yellow, critical=red. Single source of truth
/// reused by `DemoDataSource` (via the protocol-extension default) and
/// asserted against `UIState.overallSeverityTint` in tests.
func popoverSeverityTint(_ severity: Severity?) -> Color {
    switch severity {
    case .some(.critical): return .red
    case .some(.warn):     return .yellow
    case .some(.info):     return .blue
    case .none:            return .gray
    }
}

/// Verdict-card dot / badge tint. good=green, watch=blue, degraded=orange,
/// problem=red (plan D5).
func popoverVerdictTint(_ verdict: VerdictLevel) -> Color {
    switch verdict {
    case .good:     return .green
    case .watch:    return .blue
    case .degraded: return .orange
    case .problem:  return .red
    }
}

/// Header uptime label ("uptime 12s" / "uptime 5m" / "uptime 2h").
func popoverUptimeLabel(since started: Date, now: Date = Date()) -> String {
    let elapsed = Int(now.timeIntervalSince(started))
    if elapsed < 60 { return "uptime \(elapsed)s" }
    let mins = elapsed / 60
    if mins < 60 { return "uptime \(mins)m" }
    let hours = mins / 60
    return "uptime \(hours)h"
}

// MARK: - Live conformance

/// Zero-behavior-change conformance: `UIState` already declares every member
/// (the published fields plus its own `uptimeLabel` / `overallSeverityTint` /
/// `verdictTint`, which shadow the protocol defaults — same outputs). Kept in
/// this file so `uZoraApp.swift` needs no edit for the conformance itself.
extension UIState: PopoverDataSource {}
