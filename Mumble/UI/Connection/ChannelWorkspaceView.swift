import SwiftUI
import UniformTypeIdentifiers

struct ChannelWorkspaceView: View {
    let server: SavedServer
    let channels: [MumbleChannel]
    let users: [MumbleUser]
    let currentSessionID: UInt32?
    let currentSessionChannelID: UInt32?
    let isLoadingChannels: Bool
    let onJoinChannel: (MumbleChannel) -> Void
    let onMoveUser: (UInt32, MumbleChannel) -> Void

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
                    channelsByID: Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) }),
                    currentSessionID: currentSessionID,
                    currentSessionChannelID: currentSessionChannelID,
                    onJoinChannel: onJoinChannel,
                    onMoveUser: onMoveUser
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private enum DraggedMumbleUserPayload {
    private static let tokenPrefix = "mumble-user:"
    static let contentType = UTType.plainText

    static func itemProvider(for sessionID: UInt32) -> NSItemProvider {
        NSItemProvider(object: NSString(string: token(for: sessionID)))
    }

    static func loadSessionIDs(
        from providers: [NSItemProvider],
        completion: @escaping ([UInt32]) -> Void
    ) {
        let relevantProviders = providers.filter {
            $0.canLoadObject(ofClass: NSString.self)
        }

        guard !relevantProviders.isEmpty else {
            completion([])
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var sessionIDs: [UInt32] = []

        for provider in relevantProviders {
            group.enter()
            provider.loadObject(ofClass: NSString.self) { object, _ in
                defer { group.leave() }

                guard
                    let token = object as? String,
                    let sessionID = sessionID(from: token)
                else {
                    return
                }

                lock.lock()
                sessionIDs.append(sessionID)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            completion(sessionIDs)
        }
    }

    private static func token(for sessionID: UInt32) -> String {
        "\(tokenPrefix)\(sessionID)"
    }

    private static func sessionID(from token: String) -> UInt32? {
        guard token.hasPrefix(tokenPrefix) else {
            return nil
        }

        return UInt32(token.dropFirst(tokenPrefix.count))
    }
}

private struct ChannelTreeView: View {
    let nodes: [MumbleChannelTreeNode]
    let channelsByID: [UInt32: MumbleChannel]
    let currentSessionID: UInt32?
    let currentSessionChannelID: UInt32?
    let onJoinChannel: (MumbleChannel) -> Void
    let onMoveUser: (UInt32, MumbleChannel) -> Void

    @State private var expansionOverrides: [UInt32: Bool] = [:]
    @State private var previousOccupancyByChannelID: [UInt32: Bool] = [:]

    private var occupancyByChannelID: [UInt32: Bool] {
        Dictionary(uniqueKeysWithValues: nodes.flatMap(\.channelOccupancyStates))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(nodes) { node in
                    ChannelTreeBranch(
                        node: node,
                        depth: 0,
                        channelsByID: channelsByID,
                        currentSessionID: currentSessionID,
                        currentSessionChannelID: currentSessionChannelID,
                        expansionOverrides: $expansionOverrides,
                        occupancyByChannelID: occupancyByChannelID,
                        onJoinChannel: onJoinChannel,
                        onMoveUser: onMoveUser
                    )
                }
            }
            .padding(.vertical, 6)
        }
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
    let depth: Int
    let channelsByID: [UInt32: MumbleChannel]
    let currentSessionID: UInt32?
    let currentSessionChannelID: UInt32?
    @Binding var expansionOverrides: [UInt32: Bool]
    let occupancyByChannelID: [UInt32: Bool]
    let onJoinChannel: (MumbleChannel) -> Void
    let onMoveUser: (UInt32, MumbleChannel) -> Void

    var body: some View {
        switch node.kind {
        case .user:
            ChannelTreeRow(
                node: node,
                depth: depth,
                channelsByID: channelsByID,
                isExpanded: nil,
                onToggleExpansion: nil,
                currentSessionChannelID: currentSessionChannelID,
                onJoinChannel: onJoinChannel,
                onMoveUser: onMoveUser
            )
            .environment(\.mumbleCurrentSessionID, currentSessionID)
        case .channel:
            if let channelID = node.channelID {
                let children = node.children ?? []
                let isExpanded = expansionOverrides[channelID] ?? occupancyByChannelID[channelID] ?? false

                VStack(alignment: .leading, spacing: 0) {
                    ChannelTreeRow(
                        node: node,
                        depth: depth,
                        channelsByID: channelsByID,
                        isExpanded: children.isEmpty ? nil : isExpanded,
                        onToggleExpansion: children.isEmpty ? nil : {
                            expansionOverrides[channelID] = !isExpanded
                        },
                        currentSessionChannelID: currentSessionChannelID,
                        onJoinChannel: onJoinChannel,
                        onMoveUser: onMoveUser
                    )
                    .environment(\.mumbleCurrentSessionID, currentSessionID)

                    if isExpanded {
                        ForEach(children) { child in
                            ChannelTreeBranch(
                                node: child,
                                depth: depth + 1,
                                channelsByID: channelsByID,
                                currentSessionID: currentSessionID,
                                currentSessionChannelID: currentSessionChannelID,
                                expansionOverrides: $expansionOverrides,
                                occupancyByChannelID: occupancyByChannelID,
                                onJoinChannel: onJoinChannel,
                                onMoveUser: onMoveUser
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct ChannelTreeRow: View {
    @Environment(\.mumbleCurrentSessionID) private var currentSessionID

    let node: MumbleChannelTreeNode
    let depth: Int
    let channelsByID: [UInt32: MumbleChannel]
    let isExpanded: Bool?
    let onToggleExpansion: (() -> Void)?
    let currentSessionChannelID: UInt32?
    let onJoinChannel: (MumbleChannel) -> Void
    let onMoveUser: (UInt32, MumbleChannel) -> Void
    @State private var isDropTargeted = false

    private var canJoinChannel: Bool {
        guard let channel = node.channel else {
            return false
        }

        return channel.id != currentSessionChannelID
    }

    var body: some View {
        HStack(spacing: 8) {
            switch node.kind {
            case .channel:
                disclosureIndicator

                Text(node.title)
                    .font(.body)
                    .lineLimit(1)
            case .user:
                indentationSpacer

                if let user = node.user {
                    UserTreeRow(user: user, isCurrentSession: user.id == currentSessionID)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 16 + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.18) : .clear)
        )
        .contextMenu {
            if let channel = node.channel {
                Button("Join Channel") {
                    onJoinChannel(channel)
                }
                .disabled(!canJoinChannel)
            }
        }
        .modifier(ChannelRowDropModifier(
            channel: dropTargetChannel,
            acceptance: dropAcceptance,
            isDropTargeted: $isDropTargeted,
            onMoveUser: onMoveUser
        ))
        .onTapGesture(count: 2) {
            guard let channel = node.channel, canJoinChannel else {
                return
            }

            onJoinChannel(channel)
        }
    }

    @ViewBuilder
    private var disclosureIndicator: some View {
        if let isExpanded, let onToggleExpansion {
            Button(action: onToggleExpansion) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
        } else {
            indentationSpacer
        }
    }

    private var indentationSpacer: some View {
        Color.clear
            .frame(width: 12, height: 12)
    }

    private var dropTargetChannel: MumbleChannel? {
        if let channel = node.channel {
            return channel
        }

        guard let user = node.user, let channelID = user.channelID else {
            return nil
        }

        return channelsByID[channelID]
    }

    private var dropAcceptance: ChannelDropAcceptance? {
        if node.channel != nil {
            return .anySession
        }

        guard node.user != nil, let currentSessionID else {
            return nil
        }

        return .specificSession(currentSessionID)
    }
}

private struct ChannelRowDropModifier: ViewModifier {
    let channel: MumbleChannel?
    let acceptance: ChannelDropAcceptance?
    @Binding var isDropTargeted: Bool
    let onMoveUser: (UInt32, MumbleChannel) -> Void

    func body(content: Content) -> some View {
        if let channel, let acceptance {
            content.onDrop(
                of: [DraggedMumbleUserPayload.contentType],
                delegate: ChannelRowDropDelegate(
                    channel: channel,
                    acceptance: acceptance,
                    isDropTargeted: $isDropTargeted,
                    onMoveUser: onMoveUser
                )
            )
        } else {
            content
        }
    }
}

private enum ChannelDropAcceptance {
    case anySession
    case specificSession(UInt32)

    func matches(_ sessionID: UInt32) -> Bool {
        switch self {
        case .anySession:
            return true
        case .specificSession(let allowedSessionID):
            return sessionID == allowedSessionID
        }
    }
}

private struct ChannelRowDropDelegate: DropDelegate {
    let channel: MumbleChannel
    let acceptance: ChannelDropAcceptance
    @Binding var isDropTargeted: Bool
    let onMoveUser: (UInt32, MumbleChannel) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [DraggedMumbleUserPayload.contentType])
    }

    func dropEntered(info: DropInfo) {
        isDropTargeted = validateDrop(info: info)
    }

    func dropExited(info: DropInfo) {
        isDropTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isDropTargeted = false

        let providers = info.itemProviders(for: [DraggedMumbleUserPayload.contentType])
        guard !providers.isEmpty else {
            return false
        }

        DraggedMumbleUserPayload.loadSessionIDs(from: providers) { sessionIDs in
            for sessionID in sessionIDs where acceptance.matches(sessionID) {
                onMoveUser(sessionID, channel)
            }
        }

        return true
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
        .onDrag {
            DraggedMumbleUserPayload.itemProvider(for: user.id)
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
    let channel: MumbleChannel?
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
                channel: nil,
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
            channel: channel,
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
