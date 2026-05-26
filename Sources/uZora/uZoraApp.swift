import SwiftUI
import os

@main
struct uZoraApp: App {
    @State private var probeNames: [String] = []
    @State private var recentEvents: [EventRow] = []
    @State private var powerStateLabel: String = "—"

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "app")

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 6) {
                Text("uZora — Phase 3 build")
                    .font(.headline)
                Text("Power: \(powerStateLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if probeNames.isEmpty {
                    Text("Probes loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Probes: \(probeNames.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 320, alignment: .leading)
                }
                Divider()
                if recentEvents.isEmpty {
                    Text("No watchdog events yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Recent events:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(recentEvents) { row in
                        Text(row.text)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 320, alignment: .leading)
                    }
                }
                Divider()
                Button("Quit uZora") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(8)
            .task {
                await bootstrap()
            }
        } label: {
            Image(systemName: "sunrise.fill")
        }

        Settings {
            EmptyView()
        }
    }

    @MainActor
    private func bootstrap() async {
        let registry = await ProbeRegistry.defaultPopulated()
        let powerMonitor = PowerProfileMonitor()
        let watchdog = Watchdog()
        let eventBus = EventBus()

        // Wire eventBus → UI history (max 5 entries) + logger + console.
        await eventBus.attachLoggerSink()
        await eventBus.attachConsoleSink()
        await eventBus.subscribe { event in
            Task { @MainActor in
                let row = EventRow(text: format(event))
                self.recentEvents.append(row)
                if self.recentEvents.count > 5 {
                    self.recentEvents.removeFirst(self.recentEvents.count - 5)
                }
            }
        }

        // Wire powerMonitor → registry & UI label.
        await powerMonitor.observe { profile in
            Task {
                await registry.updatePowerProfile(profile)
            }
            Task { @MainActor in
                self.powerStateLabel = profile.state.rawValue
            }
        }
        await powerMonitor.start()

        await registry.start(watchdog: watchdog, eventBus: eventBus)
        let names = await registry.registeredNames()
        self.probeNames = names

        log.info("uZora launched, registered \(names.count, privacy: .public) probes, scheduler running")
    }
}

private struct EventRow: Identifiable {
    let id = UUID()
    let text: String
}

private func format(_ event: WatchdogEvent) -> String {
    switch event {
    case .appeared(let alert):
        return "▲ \(alert.id) [\(alert.severity.rawValue)]"
    case .escalated(let alert, let prev):
        return "↑ \(alert.id) \(prev.rawValue)→\(alert.severity.rawValue)"
    case .cleared(let id):
        return "✓ \(id) cleared"
    }
}
