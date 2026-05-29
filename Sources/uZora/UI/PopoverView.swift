import SwiftUI
import Charts
import AppKit

/// Live menu-bar popover. Replaces the placeholder Phase 4 dropdown
/// with a richer dashboard: active alerts, system overview tiles, top
/// processes, channel status, action buttons.
///
/// The view is driven by `@ObservedObject` so SwiftUI re-renders the whole
/// popover on each EventBus tick that mutates `UIState`. Mini-charts pull
/// from per-metric ring buffers maintained on the same object.
struct PopoverView: View {
    @ObservedObject var state: UIState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    activeAlertsSection
                    systemOverviewSection
                    topProcessesSection
                }
                .padding(.horizontal, 12)
            }
            Divider().padding(.vertical, 6)
            footer
        }
        .frame(width: 400, height: 500)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sunrise.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(state.overallSeverityTint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("uZora")
                        .font(.headline)
                    Text(state.powerStateLabel)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
                Text(state.uptimeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    // MARK: - Active Alerts

    private var activeAlertsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Active alerts", defaultValue: "Active alerts"))
                .font(.subheadline)
                .fontWeight(.semibold)
            if state.activeAlerts.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(.yellow)
                    Text(String(localized: "All systems healthy", defaultValue: "All systems healthy"))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(state.activeAlerts, id: \.id) { alert in
                    AlertRow(alert: alert)
                }
            }
        }
    }

    // MARK: - System overview

    private var systemOverviewSection: some View {
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
                    value: state.cpuTempLabel,
                    sparkline: state.cpuTempHistory
                )
                MetricTile(
                    title: String(localized: "Disk free", defaultValue: "Disk free"),
                    value: state.diskFreeLabel,
                    sparkline: state.diskFreeHistory
                )
                MetricTile(
                    title: String(localized: "Battery", defaultValue: "Battery"),
                    value: state.batteryLabel,
                    sparkline: state.batteryHistory
                )
                MetricTile(
                    title: String(localized: "Memory", defaultValue: "Memory"),
                    value: state.memoryLabel,
                    sparkline: state.memoryHistory
                )
            }
        }
    }

    // MARK: - Top processes

    private var topProcessesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Top processes", defaultValue: "Top processes"))
                .font(.subheadline)
                .fontWeight(.semibold)
            if state.topCPUProcesses.isEmpty && state.topMemProcesses.isEmpty {
                Text(String(localized: "Sampling…", defaultValue: "Sampling…"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                if !state.topCPUProcesses.isEmpty {
                    Text(String(localized: "CPU", defaultValue: "CPU"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(state.topCPUProcesses.prefix(5), id: \.pid) { p in
                        ProcessRow(name: p.name, value: String(format: "%.1f%%", p.cpuPct))
                    }
                }
                if !state.topMemProcesses.isEmpty {
                    Text(String(localized: "Memory", defaultValue: "Memory"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(state.topMemProcesses.prefix(3), id: \.pid) { p in
                        ProcessRow(name: p.name, value: byteString(p.rssBytes))
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ChannelDot(label: "HTTP", on: state.httpAlive)
                ChannelDot(label: "MCP", on: state.mcpAlive)
                ChannelDot(label: "JSONL", on: state.jsonlAlive)
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

    private func byteString(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - Subviews

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
