import SwiftUI

struct MenuBarView: View {
    @Environment(DaemonClient.self) private var daemon

    var body: some View {
        Text("MCP Manager")
            .padding()
            .onAppear { daemon.start() }
    }
}
