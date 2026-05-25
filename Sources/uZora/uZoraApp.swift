import SwiftUI
import os

@main
struct uZoraApp: App {
    @State private var probeNames: [String] = []

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "app")

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 6) {
                Text("uZora — Phase 2 build")
                    .font(.headline)
                if probeNames.isEmpty {
                    Text("Probes loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Probes: \(probeNames.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 280, alignment: .leading)
                }
                Divider()
                Button("Quit uZora") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(8)
            .task {
                let registry = await ProbeRegistry.defaultPopulated()
                await registry.start()
                let names = await registry.registeredNames()
                self.probeNames = names
                log.info("uZora launched, registered \(names.count, privacy: .public) probes")
            }
        } label: {
            Image(systemName: "sunrise.fill")
        }

        Settings {
            EmptyView()
        }
    }
}
