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

    // Attention zone (A2 unified: findings lead, then unexplained raw alerts as
    // "Other signals"; `AttentionBlock` consumes `findings` + `activeAlerts`).
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

    // A4a expanded-catalog tiles (opt-in, default-OFF): GPU%, cores-pinned,
    // swap-in rate, kernel_task CPU%. The memory-used% tile reuses
    // `memoryLabel`/`memoryHistory` above, so it needs no new member.
    var gpuLabel: String { get }
    var coresPinnedLabel: String { get }
    var swapInLabel: String { get }
    var kernelTaskLabel: String { get }
    var gpuHistory: [Double] { get }
    var coresPinnedHistory: [Double] { get }
    var swapInHistory: [Double] { get }
    var kernelTaskHistory: [Double] { get }

    // Memory-pressure LEVEL (D6) — the CORRECT memory signal for the default
    // Memory tile (0 normal / 1 warn / 2 critical, the `mem_pressure_level`
    // ordinal from `system_signals`). `nil` until first sampled. The used%
    // `memoryLabel`/`memoryHistory` above stay in the protocol for a later
    // opt-in catalog tile (A4) — they are just no longer the default tile.
    var memPressureLevel: Int? { get }

    // Top processes.
    var topCPUProcesses: [UIState.ProcessSnap] { get }
    var topMemProcesses: [UIState.ProcessSnap] { get }

    // A4b expanded catalog (opt-in, default-OFF). `sevenDayHistory` is the
    // 7-day CPU-temperature series bucketed to ~hourly averages (the
    // `sevenDayChart` block); `topNetProcesses` is the top-network-talkers list
    // (the `topNet` block), sampled off a 60s cadence via nettop.
    var sevenDayHistory: [Double] { get }
    var topNetProcesses: [UIState.NetSnap] { get }

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

/// Memory-pressure LEVEL tile color (D6). The level is the persisted
/// `mem_pressure_level` ordinal: 0 normal → green, 1 warn → orange (amber),
/// 2+ critical → red. `nil` / unknown → gray (not yet sampled). Single source
/// of truth reused by the tile view and asserted in tests.
func memPressureColor(_ level: Int?) -> Color {
    switch level {
    case .some(0):            return .green
    case .some(1):            return .orange
    case .some(let l) where l >= 2: return .red
    default:                  return .gray
    }
}

/// Human label for the memory-pressure LEVEL ordinal (0/1/2). `nil` / unknown
/// → em dash. Pairs with `memPressureColor`.
func memPressureLabel(_ level: Int?) -> String {
    switch level {
    case .some(0):            return String(localized: "normal", defaultValue: "normal")
    case .some(1):            return String(localized: "warn", defaultValue: "warn")
    case .some(let l) where l >= 2: return String(localized: "critical", defaultValue: "critical")
    default:                  return "—"
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
