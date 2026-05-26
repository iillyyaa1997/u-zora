import SwiftUI
import AppKit
import os

@main
struct uZoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContents(state: appDelegate.uiState)
        } label: {
            Image(systemName: "sunrise.fill")
        }

        Settings {
            EmptyView()
        }
    }
}

/// SwiftUI view bound to `AppDelegate.uiState`. Hosts the menu-bar
/// dropdown rows.
private struct MenuContents: View {
    @ObservedObject var state: UIState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("uZora — Phase 4 build")
                .font(.headline)
            Text("Power: \(state.powerStateLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(state.bridgeLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if state.probeNames.isEmpty {
                Text("Probes loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Probes: \(state.probeNames.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .leading)
            }
            Divider()
            if state.recentEventTexts.isEmpty {
                Text("No watchdog events yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Recent events:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(state.recentEventTexts, id: \.self) { row in
                    Text(row)
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
    }
}

/// Observable UI state. Lives on the AppDelegate so it survives view
/// recomposition and so the bootstrap can run at `applicationDidFinishLaunching`
/// regardless of whether the menu has been opened.
@MainActor
public final class UIState: ObservableObject {
    @Published public var probeNames: [String] = []
    @Published public var recentEventTexts: [String] = []
    @Published public var powerStateLabel: String = "—"
    @Published public var bridgeLabel: String = "bridge starting…"
}

/// AppDelegate driving the Phase 1+ probe pipeline and Phase 4 channels.
/// Bootstrap runs at `applicationDidFinishLaunching` so the HTTP server
/// is bound regardless of whether the user clicks the menu bar icon.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    public let uiState: UIState

    public override init() {
        self.uiState = UIState()
        super.init()
    }

    private let log = Logger(subsystem: "place.unicorns.uzora", category: "app")
    private var host: ChannelHost?
    private var registry: ProbeRegistry?
    private var bus: EventBus?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await self.bootstrap()
        }
    }

    @MainActor
    private func bootstrap() async {
        let registry = await ProbeRegistry.defaultPopulated()
        let powerMonitor = PowerProfileMonitor()
        let watchdog = Watchdog()
        let eventBus = EventBus()
        let stateStore = StateStore()
        self.registry = registry
        self.bus = eventBus

        let jsonlSink: JSONLEventSink?
        do {
            jsonlSink = try JSONLEventSink()
        } catch {
            log.error("JSONLEventSink init failed: \(String(describing: error), privacy: .public)")
            jsonlSink = nil
        }

        // Seed the probe inventory in the state store.
        let names = await registry.registeredNames()
        let inventory: [StateStore.ProbeInfo] = names.map { name in
            StateStore.ProbeInfo(name: name, pollIntervalSeconds: 0, lastRunAt: nil)
        }
        await stateStore.setProbes(inventory)
        uiState.probeNames = names

        // EventBus → logger + console + UI mirror.
        await eventBus.attachLoggerSink()
        await eventBus.attachConsoleSink()

        let weakState = uiState
        await eventBus.subscribe { [weak weakState] event in
            let text = AppDelegate.format(event)
            Task { @MainActor in
                guard let weakState else { return }
                weakState.recentEventTexts.append(text)
                if weakState.recentEventTexts.count > 5 {
                    weakState.recentEventTexts.removeFirst(weakState.recentEventTexts.count - 5)
                }
            }
        }

        // Bring up the four-channel bridge.
        let portEnv = ProcessInfo.processInfo.environment["UZORA_HTTP_PORT"].flatMap { UInt16($0) }
        let port = portEnv ?? 39842
        if let jsonlSink {
            let host = ChannelHost(port: port, state: stateStore, jsonl: jsonlSink, eventBus: eventBus)
            do {
                try await host.start()
                let bound = await host.boundPort()
                uiState.bridgeLabel = "bridge: http://127.0.0.1:\(bound)"
                self.host = host
            } catch {
                uiState.bridgeLabel = "bridge: failed (\(error))"
                log.error("ChannelHost start failed: \(String(describing: error), privacy: .public)")
            }
        }

        // PowerMonitor → registry + state-store + UI label.
        let uiStateRef = uiState
        await powerMonitor.observe { profile in
            Task {
                await registry.updatePowerProfile(profile)
                await stateStore.updatePowerState(profile.state.rawValue)
            }
            Task { @MainActor in
                uiStateRef.powerStateLabel = profile.state.rawValue
            }
        }
        await powerMonitor.start()

        await registry.start(watchdog: watchdog, eventBus: eventBus)
        log.info("uZora launched, registered \(names.count, privacy: .public) probes, bridge on :\(port, privacy: .public)")
    }

    public func applicationWillTerminate(_ notification: Notification) {
        let h = self.host
        let r = self.registry
        Task {
            await h?.stop()
            await r?.stop()
        }
    }

    nonisolated static func format(_ event: WatchdogEvent) -> String {
        switch event {
        case .appeared(let alert):
            return "▲ \(alert.id) [\(alert.severity.rawValue)]"
        case .escalated(let alert, let prev):
            return "↑ \(alert.id) \(prev.rawValue)→\(alert.severity.rawValue)"
        case .cleared(let id):
            return "✓ \(id) cleared"
        }
    }
}
