import SwiftUI

@main
struct MCPManagerApp: App {
    @State private var daemon = DaemonClient()
    /// One instance for the whole app: the Settings toggle and the main window's nudge are two
    /// views of the same login-item record, and a second object would let them disagree.
    @State private var startup = StartupSettings()

    var body: some Scene {
        // The label is built at launch, unlike the popover's content, so it is what starts the
        // connection — and it can show the service's health without the user opening anything.
        MenuBarExtra {
            MenuBarView().environment(daemon)
        } label: {
            MenuBarLabel().environment(daemon)
        }
        .menuBarExtraStyle(.window)

        // Not presented at launch: with MenuBarExtra first and LSUIElement set, macOS leaves this
        // scene closed until `openWindow(id: "main")` asks for it (verified — see Task 15 notes).
        Window("MCP Manager", id: "main") {
            MainWindowView().environment(daemon).environment(startup)
                .frame(minWidth: 820, minHeight: 520)
                .containerBackground(.thinMaterial, for: .window)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 560)

        Settings {
            SettingsView().environment(daemon).environment(startup)
        }
    }
}
