import SwiftUI

@main
struct uZoraApp: App {
    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 6) {
                Text("uZora — Phase 1 build")
                    .font(.headline)
                Divider()
                Button("Quit uZora") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(8)
        } label: {
            Image(systemName: "sunrise.fill")
        }

        Settings {
            EmptyView()
        }
    }
}
