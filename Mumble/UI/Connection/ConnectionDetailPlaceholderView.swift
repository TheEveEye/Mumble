import SwiftUI

struct ConnectionDetailPlaceholderView: View {
    let server: SavedServer?
    let channels: [MumbleChannel]
    let users: [MumbleUser]
    let talkStatesBySessionID: [UInt32: MumbleUserTalkState]
    let currentSessionID: UInt32?
    let currentSessionChannelID: UInt32?
    let isLoadingChannels: Bool
    let onJoinChannel: (MumbleChannel) -> Void
    let onMoveUser: (UInt32, MumbleChannel) -> Void

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
                        talkStatesBySessionID: talkStatesBySessionID,
                        currentSessionID: currentSessionID,
                        currentSessionChannelID: currentSessionChannelID,
                        isLoadingChannels: isLoadingChannels,
                        onJoinChannel: onJoinChannel,
                        onMoveUser: onMoveUser
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
