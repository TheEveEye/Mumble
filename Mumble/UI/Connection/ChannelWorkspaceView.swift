import SwiftUI

struct ChannelWorkspaceView: View {
    let server: SavedServer
    let channels: [MumbleChannel]
    let users: [MumbleUser]
    let currentSessionID: UInt32?
    let isLoadingChannels: Bool

    var body: some View {
        Group {
            if channels.isEmpty {
                ChannelWorkspaceEmptyState(
                    serverName: server.displayName,
                    isLoadingChannels: isLoadingChannels
                )
            } else {
                ChannelTreeView(
                    nodes: MumbleChannelTreeNode.makeTree(from: channels, users: users),
                    currentSessionID: currentSessionID
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct ChannelTreeView: View {
    let nodes: [MumbleChannelTreeNode]
    let currentSessionID: UInt32?

    @State private var selection: MumbleChannelTreeNode.RowID?
    @State private var expansionOverrides: [UInt32: Bool] = [:]
    @State private var previousOccupancyByChannelID: [UInt32: Bool] = [:]

    private var occupancyByChannelID: [UInt32: Bool] {
        Dictionary(uniqueKeysWithValues: nodes.flatMap(\.channelOccupancyStates))
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(nodes) { node in
                ChannelTreeBranch(
                    node: node,
                    currentSessionID: currentSessionID,
                    selection: $selection,
                    expansionOverrides: $expansionOverrides,
                    occupancyByChannelID: occupancyByChannelID
                )
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            synchronizeExpansionState()
        }
        .onChange(of: occupancyByChannelID) {
            synchronizeExpansionState()
        }
    }

    private func synchronizeExpansionState() {
        for (channelID, isOccupied) in occupancyByChannelID {
            if previousOccupancyByChannelID[channelID] != isOccupied {
                expansionOverrides.removeValue(forKey: channelID)
            }
        }

        for channelID in previousOccupancyByChannelID.keys where occupancyByChannelID[channelID] == nil {
            expansionOverrides.removeValue(forKey: channelID)
        }

        previousOccupancyByChannelID = occupancyByChannelID
    }
}

private struct ChannelTreeBranch: View {
    let node: MumbleChannelTreeNode
    let currentSessionID: UInt32?
    @Binding var selection: MumbleChannelTreeNode.RowID?
    @Binding var expansionOverrides: [UInt32: Bool]
    let occupancyByChannelID: [UInt32: Bool]

    var body: some View {
        switch node.kind {
        case .user:
            ChannelTreeRow(node: node)
                .environment(\.mumbleCurrentSessionID, currentSessionID)
                .tag(node.id)
        case .channel:
            if let channelID = node.channelID, let children = node.children, !children.isEmpty {
                DisclosureGroup(isExpanded: expansionBinding(for: channelID)) {
                    ForEach(children) { child in
                        ChannelTreeBranch(
                            node: child,
                            currentSessionID: currentSessionID,
                            selection: $selection,
                            expansionOverrides: $expansionOverrides,
                            occupancyByChannelID: occupancyByChannelID
                        )
                    }
                } label: {
                    ChannelTreeRow(node: node)
                        .environment(\.mumbleCurrentSessionID, currentSessionID)
                        .tag(node.id)
                }
            } else {
                ChannelTreeRow(node: node)
                    .environment(\.mumbleCurrentSessionID, currentSessionID)
                    .tag(node.id)
            }
        }
    }

    private func expansionBinding(for channelID: UInt32) -> Binding<Bool> {
        Binding(
            get: {
                expansionOverrides[channelID] ?? occupancyByChannelID[channelID] ?? false
            },
            set: { isExpanded in
                expansionOverrides[channelID] = isExpanded
            }
        )
    }
}

private struct ChannelTreeRow: View {
    @Environment(\.mumbleCurrentSessionID) private var currentSessionID

    let node: MumbleChannelTreeNode

    var body: some View {
        HStack {
            switch node.kind {
            case .channel:
                Text(node.title)
                    .font(.body)
                    .lineLimit(1)
            case .user:
                if let user = node.user {
                    UserTreeRow(user: user, isCurrentSession: user.id == currentSessionID)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

private struct UserTreeRow: View {
    let user: MumbleUser
    let isCurrentSession: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 12)

            Text(user.name)
                .font(isCurrentSession ? .body.weight(.semibold) : .body)
                .lineLimit(1)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                ForEach(user.statusBadges) { badge in
                    Image(systemName: badge.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(badge.color)
                        .help(badge.helpText)
                }
            }
        }
    }
}

private struct MumbleCurrentSessionIDKey: EnvironmentKey {
    static let defaultValue: UInt32? = nil
}

private extension EnvironmentValues {
    var mumbleCurrentSessionID: UInt32? {
        get { self[MumbleCurrentSessionIDKey.self] }
        set { self[MumbleCurrentSessionIDKey.self] = newValue }
    }
}

private struct ChannelWorkspaceEmptyState: View {
    let serverName: String
    let isLoadingChannels: Bool

    var body: some View {
        if isLoadingChannels {
            VStack(spacing: 12) {
                ProgressView()

                Text("Loading channels from \(serverName)...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Channels Yet",
                systemImage: "rectangle.3.group",
                description: Text("Connect to a server to load its channel hierarchy.")
            )
        }
    }
}

struct MumbleChannelTreeNode: Identifiable, Hashable {
    enum RowID: Hashable {
        case channel(UInt32)
        case user(UInt32)
    }

    enum Kind: Hashable {
        case channel
        case user
    }

    let id: RowID
    let kind: Kind
    let title: String
    let user: MumbleUser?
    let channelID: UInt32?
    let containsUsersInSubtree: Bool
    let children: [MumbleChannelTreeNode]?

    var channelOccupancyStates: [(UInt32, Bool)] {
        let descendants = children?.flatMap(\.channelOccupancyStates) ?? []

        guard kind == .channel, let channelID else {
            return descendants
        }

        return [(channelID, containsUsersInSubtree)] + descendants
    }

    static func makeTree(from channels: [MumbleChannel], users: [MumbleUser]) -> [MumbleChannelTreeNode] {
        let channelsByID = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
        let usersByChannelID = Dictionary(grouping: users.compactMap { user -> (UInt32, MumbleUser)? in
            guard let channelID = user.channelID, channelsByID[channelID] != nil else {
                return nil
            }

            return (channelID, user)
        }, by: \.0)
        .mapValues { groupedUsers in
            groupedUsers
                .map(\.1)
                .sorted(by: userSortComparator)
        }
        let sortedChannels = channels.sorted(by: sortComparator)

        let rootChannels = sortedChannels.filter { channel in
            guard let parentID = channel.parentID else {
                return true
            }

            return channelsByID[parentID] == nil
        }

        return rootChannels.map {
            makeNode(from: $0, channels: sortedChannels, usersByChannelID: usersByChannelID)
        }
    }

    private static func makeNode(
        from channel: MumbleChannel,
        channels: [MumbleChannel],
        usersByChannelID: [UInt32: [MumbleUser]]
    ) -> MumbleChannelTreeNode {
        let childChannels = channels
            .filter { $0.parentID == channel.id }
            .sorted(by: sortComparator)
            .map { makeNode(from: $0, channels: channels, usersByChannelID: usersByChannelID) }
        let childUsers = (usersByChannelID[channel.id] ?? []).map { user in
            MumbleChannelTreeNode(
                id: .user(user.id),
                kind: .user,
                title: user.name,
                user: user,
                channelID: nil,
                containsUsersInSubtree: true,
                children: nil
            )
        }
        let children = childUsers + childChannels
        let containsUsersInSubtree =
            childUsers.isEmpty == false ||
            childChannels.contains(where: \.containsUsersInSubtree)

        return MumbleChannelTreeNode(
            id: .channel(channel.id),
            kind: .channel,
            title: channel.name,
            user: nil,
            channelID: channel.id,
            containsUsersInSubtree: containsUsersInSubtree,
            children: children.isEmpty ? nil : children
        )
    }

    private static let sortComparator: (MumbleChannel, MumbleChannel) -> Bool = { lhs, rhs in
        if lhs.position == rhs.position {
            let comparison = lhs.name.localizedStandardCompare(rhs.name)

            if comparison == .orderedSame {
                return lhs.id < rhs.id
            }

            return comparison == .orderedAscending
        }

        return lhs.position < rhs.position
    }

    private static let userSortComparator: (MumbleUser, MumbleUser) -> Bool = { lhs, rhs in
        let comparison = lhs.name.localizedStandardCompare(rhs.name)

        if comparison == .orderedSame {
            return lhs.id < rhs.id
        }

        return comparison == .orderedAscending
    }
}

private struct UserStatusBadge: Identifiable, Hashable {
    let id: String
    let systemImage: String
    let color: Color
    let helpText: String
}

private extension MumbleUser {
    var statusBadges: [UserStatusBadge] {
        var badges: [UserStatusBadge] = []

        if isServerMuted || isServerDeafened {
            badges.append(
                UserStatusBadge(
                    id: "server-muted",
                    systemImage: "mic.slash.fill",
                    color: .blue,
                    helpText: "Muted by server"
                )
            )
        }

        if isSuppressed {
            badges.append(
                UserStatusBadge(
                    id: "suppressed",
                    systemImage: "mic.slash.fill",
                    color: .green,
                    helpText: "Suppressed in channel"
                )
            )
        }

        if isSelfMuted || isSelfDeafened {
            badges.append(
                UserStatusBadge(
                    id: "self-muted",
                    systemImage: "mic.slash.fill",
                    color: .red,
                    helpText: "Self-muted"
                )
            )
        }

        if isServerDeafened {
            badges.append(
                UserStatusBadge(
                    id: "server-deafened",
                    systemImage: "speaker.slash.fill",
                    color: .blue,
                    helpText: "Deafened by server"
                )
            )
        }

        if isSelfDeafened {
            badges.append(
                UserStatusBadge(
                    id: "self-deafened",
                    systemImage: "speaker.slash.fill",
                    color: .red,
                    helpText: "Self-deafened"
                )
            )
        }

        if isAuthenticated {
            badges.append(
                UserStatusBadge(
                    id: "authenticated",
                    systemImage: "checkmark",
                    color: .yellow,
                    helpText: "Authenticated"
                )
            )
        }

        return badges
    }
}
