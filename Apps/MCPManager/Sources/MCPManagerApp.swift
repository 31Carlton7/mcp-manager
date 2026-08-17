import SwiftUI

@main
struct MCPManagerApp: App {
    @State private var daemon = DaemonClient()

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
            ServersView().environment(daemon)
                .frame(minWidth: 640, minHeight: 400)
        }
    }
}
