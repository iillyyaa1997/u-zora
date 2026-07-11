import SwiftUI
import Charts
import AppKit

/// The reorderable content blocks of the popover (the chrome — header +
/// footer — is fixed and rendered outside this set). A3a renders these from a
/// persisted, preset-based `PopoverLayout` (order + per-block visibility)
/// instead of a hard-coded order.
///
/// `Codable` (rawValue) so it serializes inside a `PopoverLayout` JSON string.
/// The layout codec tolerates an unknown raw value (a block name a newer app
/// added) by DROPPING it on decode — this enum keeps exactly the five known
/// cases, so `allCases.count == 5` and render never has to guard an unknown.
///
/// `.attention` is the unified Attention zone (A2).
enum WidgetKind: String, CaseIterable, Codable, Hashable, Sendable {
    case verdict
    case attention
    case systemOverview
    case topProcesses
    case recentActions
}

/// Live menu-bar popover. Replaces the placeholder Phase 4 dropdown
/// with a richer dashboard: active alerts, system overview tiles, top
/// processes, channel status, action buttons.
///
/// The view is generic over `PopoverDataSource` so it renders either the live
/// `UIState` or a motion `DemoDataSource` unchanged. It is driven by
/// `@ObservedObject` so SwiftUI re-renders the whole popover on each tick that
/// mutates the source. Mini-charts pull from per-metric ring buffers on the
/// same object. Each content block is a small value-driven `private struct`
/// (kept tiny for the cross-SDK view type-checker) selected by `block(_:)`.
struct PopoverView<Source: PopoverDataSource>: View {
    @ObservedObject var state: Source

    /// A3a: the resolved layout (order + per-block/per-tile visibility). A pure
    /// value passed in by the caller (`effectiveLayout(preset:layoutJSON:)`),
    /// so the view stays a pure function of `(state, layout)` — the A3b Settings
    /// preview can hand it an arbitrary layout without a live config.
    let layout: PopoverLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverHeader(
                severityTint: state.overallSeverityTint,
                powerStateLabel: state.powerStateLabel,
                uptimeLabel: state.uptimeLabel
            )
            Divider().padding(.vertical, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Render blocks in the layout's order, skipping hidden ones.
                    // Unknown kinds were already dropped during layout decode, so
                    // every `cfg.kind` here is a known `WidgetKind`.
                    ForEach(Array(layout.blocks.enumerated()), id: \.offset) { (_, cfg) in
                        if cfg.visible {
                            block(cfg.kind)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            Divider().padding(.vertical, 6)
            PopoverFooter(
                httpAlive: state.httpAlive,
                mcpAlive: state.mcpAlive,
                jsonlAlive: state.jsonlAlive
            )
        }
        .frame(width: 400, height: 500)
    }

    /// The visible System-overview tiles, in the layout's order — passed to
    /// `SystemOverviewBlock` so it draws only the enabled tiles.
    private var visibleTiles: [TileKind] {
        layout.tiles.filter { $0.visible }.map { $0.kind }
    }

    /// Render one content block, populated from `state`. The switch is the
    /// single dispatch point between `WidgetKind` and the value-driven block
    /// structs — each block gets only the concrete values it renders (not the
    /// source), so the block structs stay non-generic.
    @ViewBuilder
    private func block(_ kind: WidgetKind) -> some View {
        switch kind {
        case .verdict:
            VerdictCard(
                tint: state.verdictTint,
                headline: state.verdictHeadline
            )
        case .attention:
            AttentionBlock(
                findings: state.findings,
                alerts: state.activeAlerts
            )
        case .systemOverview:
            SystemOverviewBlock(
                tiles: visibleTiles,
                cpuTempLabel: state.cpuTempLabel,
                diskFreeLabel: state.diskFreeLabel,
                batteryLabel: state.batteryLabel,
                memPressureLevel: state.memPressureLevel,
                cpuTempHistory: state.cpuTempHistory,
                diskFreeHistory: state.diskFreeHistory,
                batteryHistory: state.batteryHistory
            )
        case .topProcesses:
            TopProcessesBlock(
                cpu: state.topCPUProcesses,
                mem: state.topMemProcesses
            )
        case .recentActions:
            RecentActionsBlock(entries: state.recentActions)
        }
    }
}

// MARK: - Chrome (fixed, outside the block switch)

/// Header: severity-tinted glyph + name + power-state pill + uptime.
private struct PopoverHeader: View {
    let severityTint: Color
    let powerStateLabel: String
    let uptimeLabel: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sunrise.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(severityTint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("uZora")
                        .font(.headline)
                    Text(powerStateLabel)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
                Text(uptimeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

/// Footer: channel status dots + Settings / Quit buttons.
private struct PopoverFooter: View {
    let httpAlive: Bool
    let mcpAlive: Bool
    let jsonlAlive: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ChannelDot(label: "HTTP", on: httpAlive)
                ChannelDot(label: "MCP", on: mcpAlive)
                ChannelDot(label: "JSONL", on: jsonlAlive)
                Spacer()
            }
            HStack {
                Button {
                    // LSUIElement apps don't auto-activate when their
                    // Settings scene opens — the window appears behind the
                    // current app. Force activation then trigger the
                    // SwiftUI Settings opener (macOS 14+).
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: {
                    Text(String(localized: "Open Settings…", defaultValue: "Open Settings…"))
                }
                Spacer()
                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text(String(localized: "Quit", defaultValue: "Quit"))
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

// MARK: - Content blocks (value-driven, selected by WidgetKind)

/// Phase 4 / A2 — the proactive-diagnosis Verdict card pinned to the TOP of
/// the popover as the ONE-LINE top summary (plan D5): a colored dot by level
/// + the headline, nothing more. The per-finding drill-down moved OUT of this
/// card into the unified Attention zone below (findings now render in full
/// there), so they are never shown twice and there is no chevron here. When
/// healthy this line is the SINGLE all-clear ("All systems healthy").
///
/// Value-driven (tint / headline) so it renders from any `PopoverDataSource`.
private struct VerdictCard: View {
    let tint: Color
    let headline: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 10, height: 10)
            Text(headline)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
            Spacer()
        }
        .padding(8)
        .background(tint.opacity(0.10))
        .cornerRadius(8)
    }
}

/// The unified "Attention" zone (WidgetKind `.attention`, plan D5 + D-C3.vi).
///
/// Findings LEAD: each `Finding` renders in full as a cause card (title +
/// explanation + optional suggested-action text) via `FindingDetailRow`.
/// Below them, "Other signals" lists the raw `activeAlerts` that NO finding
/// already explains (de-dup by `unexplainedAlerts`), so a cause isn't shown
/// twice.
///
/// Absent when healthy: with no findings AND no alerts the whole zone renders
/// `EmptyView` — this is the fix for the old DOUBLE "All systems healthy"
/// (the Verdict card above is now the single all-clear). The zone carries NO
/// healthy/empty-state text of its own.
private struct AttentionBlock: View {
    let findings: [Finding]
    let alerts: [Alert]

    var body: some View {
        if attentionZoneIsVisible(findings: findings, alerts: alerts) {
            zone
        }
    }

    private var zone: some View {
        let others = unexplainedAlerts(alerts, findings: findings)
        return VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Attention", defaultValue: "Attention"))
                .font(.subheadline)
                .fontWeight(.semibold)
            findingsList
            otherSignals(others)
        }
    }

    @ViewBuilder
    private var findingsList: some View {
        if !findings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(findings, id: \.id) { finding in
                    FindingDetailRow(finding: finding)
                }
            }
        }
    }

    @ViewBuilder
    private func otherSignals(_ others: [Alert]) -> some View {
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Other signals", defaultValue: "Other signals"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                ForEach(others, id: \.id) { alert in
                    AlertRow(alert: alert)
                }
            }
        }
    }
}

/// Whether the unified Attention zone renders anything at all. It disappears
/// (EmptyView) only when there are NO findings AND NO alerts — the all-clear
/// message then lives solely in the Verdict card. Pure + testable.
func attentionZoneIsVisible(findings: [Finding], alerts: [Alert]) -> Bool {
    !(findings.isEmpty && alerts.isEmpty)
}

/// De-dup for the unified Attention zone (plan D-C3.vi): drop the raw alerts a
/// finding already explains, so the same cause is not shown twice (once as a
/// finding card, once as a raw alert under "Other signals").
///
/// An alert is "explained" — and hidden — ONLY on a confident, EXACT match:
/// some finding's non-empty `subject` equals the alert's `probe` OR its `key`
/// verbatim (whitespace-trimmed). Anything short of that — a partial/substring
/// overlap, a case difference, an empty identifier — is treated as AMBIGUOUS
/// and the alert is SHOWN (fail-safe: never hide a signal we're unsure about).
func unexplainedAlerts(_ alerts: [Alert], findings: [Finding]) -> [Alert] {
    // Confident-match keys: the non-empty finding subjects.
    let explained = Set(
        findings
            .map { $0.subject.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    )
    if explained.isEmpty { return alerts }
    return alerts.filter { alert in
        let probe = alert.probe.trimmingCharacters(in: .whitespaces)
        let key = alert.key.trimmingCharacters(in: .whitespaces)
        let isExplained = explained.contains(probe) || explained.contains(key)
        return !isExplained
    }
}

/// System overview: a 2-column grid of the layout's ENABLED tiles, in the
/// layout's order (A3a). `cpuTemp` / `diskFree` / `battery` are sparkline
/// `MetricTile`s; the `memPressureLevel` tile is the mem-pressure LEVEL
/// indicator (D6) — the CORRECT memory signal, not used%. The used%
/// `memoryLabel`/`memoryHistory` are kept in the data source for a later
/// opt-in catalog tile (A4) and are simply no longer read here.
///
/// When `tiles` is empty (every tile hidden) the whole section — header
/// included — renders nothing, so no orphan "System overview" title shows.
private struct SystemOverviewBlock: View {
    let tiles: [TileKind]
    let cpuTempLabel: String
    let diskFreeLabel: String
    let batteryLabel: String
    let memPressureLevel: Int?
    let cpuTempHistory: [Double]
    let diskFreeHistory: [Double]
    let batteryHistory: [Double]

    var body: some View {
        if !tiles.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "System overview", defaultValue: "System overview"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ], spacing: 8) {
                    ForEach(Array(tiles.enumerated()), id: \.offset) { (_, kind) in
                        tile(kind)
                    }
                }
            }
        }
    }

    /// One tile, selected by `TileKind`. Each case is a small value-driven
    /// leaf so the grid stays inside the cross-SDK view type-checker budget.
    @ViewBuilder
    private func tile(_ kind: TileKind) -> some View {
        switch kind {
        case .cpuTemp:
            MetricTile(
                title: String(localized: "CPU temp", defaultValue: "CPU temp"),
                value: cpuTempLabel,
                sparkline: cpuTempHistory
            )
        case .diskFree:
            MetricTile(
                title: String(localized: "Disk free", defaultValue: "Disk free"),
                value: diskFreeLabel,
                sparkline: diskFreeHistory
            )
        case .battery:
            MetricTile(
                title: String(localized: "Battery", defaultValue: "Battery"),
                value: batteryLabel,
                sparkline: batteryHistory
            )
        case .memPressureLevel:
            MemPressureTile(level: memPressureLevel)
        }
    }
}

/// Top processes: up to 5 by CPU%, up to 3 by resident memory.
private struct TopProcessesBlock: View {
    let cpu: [UIState.ProcessSnap]
    let mem: [UIState.ProcessSnap]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Top processes", defaultValue: "Top processes"))
                .font(.subheadline)
                .fontWeight(.semibold)
            if cpu.isEmpty && mem.isEmpty {
                Text(String(localized: "Sampling…", defaultValue: "Sampling…"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                if !cpu.isEmpty {
                    Text(String(localized: "CPU", defaultValue: "CPU"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(cpu.prefix(5), id: \.pid) { p in
                        ProcessRow(name: p.name, value: String(format: "%.1f%%", p.cpuPct))
                    }
                }
                if !mem.isEmpty {
                    Text(String(localized: "Memory", defaultValue: "Memory"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(mem.prefix(3), id: \.pid) { p in
                        ProcessRow(name: p.name, value: popoverByteString(p.rssBytes))
                    }
                }
            }
        }
    }
}

/// Recent actions (Q10): the last few audit entries, newest first.
private struct RecentActionsBlock: View {
    let entries: [AuditLog.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entries.isEmpty {
                Text(String(localized: "Recent actions", defaultValue: "Recent actions"))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                ForEach(Array(entries.suffix(3).reversed().enumerated()), id: \.offset) { (_, entry) in
                    HStack(spacing: 6) {
                        Image(systemName: recentIcon(entry))
                            .foregroundStyle(recentColor(entry))
                            .font(.caption2)
                            .frame(width: 12)
                        Text(entry.actionID)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(recentTrailing(entry))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func recentIcon(_ e: AuditLog.Entry) -> String {
        if e.error != nil { return "xmark.circle.fill" }
        if e.policyDecision.hasPrefix("deny") { return "hand.raised.fill" }
        if e.skipped { return "minus.circle.fill" }
        return "checkmark.circle.fill"
    }
    private func recentColor(_ e: AuditLog.Entry) -> Color {
        if e.error != nil { return .red }
        if e.policyDecision.hasPrefix("deny") { return .orange }
        if e.skipped { return .secondary }
        return .green
    }
    private func recentTrailing(_ e: AuditLog.Entry) -> String {
        if e.policyDecision.hasPrefix("deny") { return String(localized: "blocked", defaultValue: "blocked") }
        if e.error != nil { return String(localized: "failed", defaultValue: "failed") }
        if e.skipped { return "—" }
        let mb = Double(e.freedBytes) / 1_048_576.0
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
}

/// MB/GB formatter for the top-processes resident-memory column.
private func popoverByteString(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576.0
    if mb >= 1024 {
        return String(format: "%.1f GB", mb / 1024)
    }
    return String(format: "%.0f MB", mb)
}

// MARK: - Leaf subviews (unchanged)

/// One finding in the Verdict drill-down: title, likely cause, optional
/// suggested action. Body is intentionally small (cross-SDK view type-check).
private struct FindingDetailRow: View {
    let finding: Finding

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(finding.title)
                .font(.caption)
                .fontWeight(.medium)
            Text(finding.explanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            actionLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var actionLine: some View {
        if let action = finding.suggestedAction, !action.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                Text(action)
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .lineLimit(2)
            }
            .padding(.top, 1)
        }
    }
}

private struct AlertRow: View {
    let alert: Alert

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: severityIcon)
                .foregroundStyle(severityColor)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(alert.probe):\(alert.key)")
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                    Text(relativeTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(alert.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    private var severityIcon: String {
        switch alert.severity {
        case .critical: return "exclamationmark.octagon.fill"
        case .warn:     return "exclamationmark.triangle.fill"
        case .info:     return "info.circle.fill"
        }
    }

    private var severityColor: Color {
        switch alert.severity {
        case .critical: return .red
        case .warn:     return .orange
        case .info:     return .blue
        }
    }

    private var relativeTime: String {
        let seconds = Int(Date().timeIntervalSince(alert.firstSeen))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let sparkline: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if sparkline.count > 1 {
                Chart {
                    ForEach(Array(sparkline.enumerated()), id: \.offset) { (idx, val) in
                        LineMark(
                            x: .value("t", idx),
                            y: .value("v", val)
                        )
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 20)
                .foregroundStyle(.tint)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 20)
                    .cornerRadius(3)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }
}

/// The default Memory tile (D6): a 3-state memory-pressure LEVEL indicator —
/// a colored dot (green/amber/red) + a level word (normal/warn/critical) — in
/// the Memory slot instead of a used% sparkline. Same footprint as
/// `MetricTile` so the 2×2 grid stays even. `level` is the persisted
/// `mem_pressure_level` ordinal (0/1/2); nil ⇒ not yet sampled (gray "—").
private struct MemPressureTile: View {
    let level: Int?

    var body: some View {
        let tint = memPressureColor(level)
        return VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Memory", defaultValue: "Memory"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                Text(memPressureLabel(level))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Rectangle()
                .fill(tint.opacity(0.25))
                .frame(height: 20)
                .cornerRadius(3)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }
}

private struct ProcessRow: View {
    let name: String
    let value: String

    var body: some View {
        HStack {
            Text(name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(value)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct ChannelDot: View {
    let label: String
    let on: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(on ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
