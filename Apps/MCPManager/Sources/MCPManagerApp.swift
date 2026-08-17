import SwiftUI

@main
struct MCPManagerApp: App {
    @State private var daemon = DaemonClient()

    var body: some Scene {
        MenuBarExtra("MCP Manager", systemImage: "powerplug") {
            MenuBarView().environment(daemon)
        }
        .menuBarExtraStyle(.window)

        Window("MCP Manager", id: "main") {
            ServersView().environment(daemon)
                .frame(minWidth: 640, minHeight: 400)
        }
    }
}
