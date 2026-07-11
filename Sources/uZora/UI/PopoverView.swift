import SwiftUI
import Charts
import AppKit

/// The reorderable content blocks of the popover (the chrome — header +
/// footer — is fixed and rendered outside this set). A1 renders these in a
/// hard-coded order via `PopoverView.blockOrder`; persistence / drag-reorder
/// is a later phase — `blockOrder` is the seam.
///
/// `.attention` is the current "Active alerts" block. A1 keeps its rendering
/// byte-identical; the Attention-zone redesign is a separate later phase.
enum WidgetKind: String, CaseIterable, Hashable, Sendable {
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

    /// A1: fixed content-block order in the shipping order. The reorder /
    /// persistence seam — a later phase drives this from user config.
    private let blockOrder: [WidgetKind] = [
        .verdict, .attention, .systemOverview, .topProcesses, .recentActions,
    ]

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
                    ForEach(blockOrder, id: \.self) { kind in
                        block(kind)
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
                headline: state.verdictHeadline,
                findings: state.findings
            )
        case .attention:
            AttentionBlock(alerts: state.activeAlerts)
        case .systemOverview:
            SystemOverviewBlock(
                cpuTempLabel: state.cpuTempLabel,
                diskFreeLabel: state.diskFreeLabel,
                batteryLabel: state.batteryLabel,
                memoryLabel: state.memoryLabel,
                cpuTempHistory: state.cpuTempHistory,
                diskFreeHistory: state.diskFreeHistory,
                batteryHistory: state.batteryHistory,
                memoryHistory: state.memoryHistory
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

/// Phase 4 — the proactive-diagnosis Verdict card pinned to the TOP of the
/// popover (above the alert list; it complements, does not replace, the
/// alerts — plan D5). One line: a colored dot by level + the headline. When
/// there are findings, a chevron expands a per-finding drill-down (title +
/// likely cause + suggested action). The healthy state stays compact.
///
/// A1: value-driven (tint / headline / findings) instead of reading `state`
/// directly, so it renders from any `PopoverDataSource`.
private struct VerdictCard: View {
    let tint: Color
    let headline: String
    let findings: [Finding]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            summaryRow
            if expanded && !findings.isEmpty {
                detailList
            }
        }
        .padding(8)
        .background(tint.opacity(0.10))
        .cornerRadius(8)
    }

    /// The always-visible one-liner: dot + headline (+ chevron when there's
    /// something to drill into).
    private var summaryRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 10, height: 10)
            Text(headline)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
            Spacer()
            if !findings.isEmpty {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !findings.isEmpty { expanded.toggle() }
        }
    }

    /// The drill-down: one row per finding.
    private var detailList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(findings, id: \.id) { finding in
                FindingDetailRow(finding: finding)
            }
        }
        .padding(.top, 2)
    }
}

/// The "Active alerts" block (WidgetKind `.attention`). A1 keeps the rendering
/// byte-identical; the Attention-zone redesign is a separate later phase.
private struct AttentionBlock: View {
    let alerts: [Alert]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Active alerts", defaultValue: "Active alerts"))
                .font(.subheadline)
                .fontWeight(.semibold)
            if alerts.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(.yellow)
                    Text(String(localized: "All systems healthy", defaultValue: "All systems healthy"))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(alerts, id: \.id) { alert in
                    AlertRow(alert: alert)
                }
            }
        }
    }
}

/// System overview: a 2-column grid of four metric tiles with sparklines.
private struct SystemOverviewBlock: View {
    let cpuTempLabel: String
    let diskFreeLabel: String
    let batteryLabel: String
    let memoryLabel: String
    let cpuTempHistory: [Double]
    let diskFreeHistory: [Double]
    let batteryHistory: [Double]
    let memoryHistory: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "System overview", defaultValue: "System overview"))
                .font(.subheadline)
                .fontWeight(.semibold)
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ], spacing: 8) {
                MetricTile(
                    title: String(localized: "CPU temp", defaultValue: "CPU temp"),
                    value: cpuTempLabel,
                    sparkline: cpuTempHistory
                )
                MetricTile(
                    title: String(localized: "Disk free", defaultValue: "Disk free"),
                    value: diskFreeLabel,
                    sparkline: diskFreeHistory
                )
                MetricTile(
                    title: String(localized: "Battery", defaultValue: "Battery"),
                    value: batteryLabel,
                    sparkline: batteryHistory
                )
                MetricTile(
                    title: String(localized: "Memory", defaultValue: "Memory"),
                    value: memoryLabel,
                    sparkline: memoryHistory
                )
            }
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
