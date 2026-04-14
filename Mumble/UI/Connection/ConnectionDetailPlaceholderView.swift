import SwiftUI

struct ConnectionDetailPlaceholderView: View {
    let server: SavedServer?
    let channels: [MumbleChannel]
    let users: [MumbleUser]
    let currentSessionID: UInt32?
    let isLoadingChannels: Bool

    var body: some View {
        Group {
            if server == nil {
                ContentUnavailableView(
                    "Open Connect",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Use the connect button in the toolbar to choose a saved server.")
                )
            } else {
                if let server {
                    ChannelWorkspaceView(
                        server: server,
                        channels: channels,
                        users: users,
                        currentSessionID: currentSessionID,
                        isLoadingChannels: isLoadingChannels
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
