import SwiftUI

struct ServersView: View {
    @Environment(DaemonClient.self) private var daemon

    var body: some View {
        Text("Servers")
            .padding()
            .onAppear { daemon.start() }
    }
}
