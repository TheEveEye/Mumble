import SwiftUI
import UniformTypeIdentifiers

struct ChannelWorkspaceView: View {
    let server: SavedServer
    let channels: [MumbleChannel]
    let users: [MumbleUser]
    let talkStatesBySessionID: [UInt32: MumbleUserTalkState]
    let currentSessionID: UInt32?
    let currentSessionChannelID: UInt32?
    let isLoadingChannels: Bool
    let onJoinChannel: (MumbleChannel) -> Void
    let onMoveUser: (UInt32, MumbleChannel) -> Void
    @State private var treeState = ChannelWorkspaceTreeState.empty

    var body: some View {
        Group {
            if channels.isEmpty {
                ChannelWorkspaceEmptyState(
                    serverName: server.displayName,
                    isLoadingChannels: isLoadingChannels
                )
            } else {
                ChannelTreeView(
                    nodes: treeState.nodes,
                    channelsByID: treeState.channelsByID,
                    occupancyByChannelID: treeState.occupancyByChannelID,
                    talkStatesBySessionID: talkStatesBySessionID,
                    linkedChannelIDsForCurrentSession: treeState.linkedChannelIDsForCurrentSession,
                    currentSessionID: currentSessionID,
                    currentSessionChannelID: currentSessionChannelID,
                    onJoinChannel: onJoinChannel,
                    onMoveUser: onMoveUser
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            rebuildTreeNodes()
        }
        .onChange(of: channels) {
            rebuildTreeNodes()
        }
        .onChange(of: users) {
            rebuildTreeNodes()
        }
        .onChange(of: currentSessionChannelID) {
            rebuildTreeNodes()
        }
    }

    private func rebuildTreeNodes() {
        let channelsByID = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
        let linkedChannelIDsForCurrentSession = channelsByID
            .linkedClosure(startingAt: currentSessionChannelID)
            .subtracting(currentSessionChannelID.map { [$0] } ?? [])
        let nodes = MumbleChannelTreeNode.makeTree(from: channels, users: users)

        treeState = ChannelWorkspaceTreeState(
            nodes: nodes,
            channelsByID: channelsByID,
            occupancyByChannelID: Dictionary(uniqueKeysWithValues: nodes.flatMap(\.channelOccupancyStates)),
            linkedChannelIDsForCurrentSession: linkedChannelIDsForCurrentSession
        )
    }
}

private struct ChannelWorkspaceTreeState: Equatable {
    static let empty = ChannelWorkspaceTreeState(
        nodes: [],
        channelsByID: [:],
        occupancyByChannelID: [:],
        linkedChannelIDsForCurrentSession: []
    )

    let nodes: [MumbleChannelTreeNode]
    let channelsByID: [UInt32: MumbleChannel]
    let occupancyByChannelID: [UInt32: Bool]
    let linkedChannelIDsForCurrentSession: Set<UInt32>
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
    let occupancyByChannelID: [UInt32: Bool]
    let talkStatesBySessionID: [UInt32: MumbleUserTalkState]
    let linkedChannelIDsForCurrentSession: Set<UInt32>
    let currentSessionID: UInt32?
    let currentSessionChannelID: UInt32?
    let onJoinChannel: (MumbleChannel) -> Void
    let onMoveUser: (UInt32, MumbleChannel) -> Void

    @State private var expansionOverrides: [UInt32: Bool] = [:]
    @State private var previousOccupancyByChannelID: [UInt32: Bool] = [:]

    @State private var visibleRows: [ChannelTreeVisibleRow] = []

    var body: some View {
        List {
            ForEach(visibleRows) { row in
                ChannelTreeRow(
                    row: row,
                    channelsByID: channelsByID,
                    talkStatesBySessionID: talkStatesBySessionID,
                    linkedChannelIDsForCurrentSession: linkedChannelIDsForCurrentSession,
                    onToggleExpansion: row.isExpanded.map { isExpanded in
                        {
                            if let channelID = row.channelID {
                                setExpanded(!isExpanded, for: channelID)
                            }
                        }
                    },
                    currentSessionChannelID: currentSessionChannelID,
                    onJoinChannel: onJoinChannel,
                    onMoveUser: onMoveUser
                )
                .environment(\.mumbleCurrentSessionID, currentSessionID)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color(nsColor: .textBackgroundColor))
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 20)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            synchronizeExpansionState()
            rebuildVisibleRows()
        }
        .onChange(of: nodes) {
            rebuildVisibleRows()
        }
        .onChange(of: expansionOverrides) {
            rebuildVisibleRows()
        }
        .onChange(of: occupancyByChannelID) {
            synchronizeExpansionState()
            rebuildVisibleRows()
        }
    }

    private func setExpanded(_ isExpanded: Bool, for channelID: UInt32) {
        var transaction = Transaction()
        transaction.animation = nil

        withTransaction(transaction) {
            expansionOverrides[channelID] = isExpanded
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

    private func rebuildVisibleRows() {
        visibleRows = ChannelTreeVisibleRow.makeVisibleRows(
            from: nodes,
            expansionOverrides: expansionOverrides,
            occupancyByChannelID: occupancyByChannelID
        )
    }
}

private struct ChannelTreeRow: View {
    @Environment(\.mumbleCurrentSessionID) private var currentSessionID

    let row: ChannelTreeVisibleRow
    let channelsByID: [UInt32: MumbleChannel]
    let talkStatesBySessionID: [UInt32: MumbleUserTalkState]
    let linkedChannelIDsForCurrentSession: Set<UInt32>
    let onToggleExpansion: (() -> Void)?
    let currentSessionChannelID: UInt32?
    let onJoinChannel: (MumbleChannel) -> Void
    let onMoveUser: (UInt32, MumbleChannel) -> Void
    @State private var isDropTargeted = false

    private var canJoinChannel: Bool {
        guard let channel = row.channel else {
            return false
        }

        return channel.id != currentSessionChannelID
    }

    var body: some View {
        HStack(spacing: 8) {
            switch row.kind {
            case .channel:
                disclosureIndicator

                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.body)
                        .lineLimit(1)

                    if let channel = row.channel, linkedChannelIDsForCurrentSession.contains(channel.id) {
                        Image(systemName: "link")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(red: 0.43, green: 0.78, blue: 1.0))
                            .help(channelLinkHelpText(for: channel))
                    }
                }
                .onTapGesture(count: 2) {
                    guard let channel = row.channel, canJoinChannel else {
                        return
                    }

                    onJoinChannel(channel)
                }
            case .user:
                indentationSpacer

                if let user = row.user {
                    UserTreeRow(
                        user: user,
                        userDisplayRole: row.userDisplayRole ?? .member,
                        talkState: talkStatesBySessionID[user.id] ?? .passive,
                        isCurrentSession: user.id == currentSessionID
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 16 + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.18) : .clear)
        )
        .contextMenu {
            if let channel = row.channel {
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
    }

    @ViewBuilder
    private var disclosureIndicator: some View {
        if let isExpanded = row.isExpanded, let onToggleExpansion {
            Button(action: onToggleExpansion) {
                ZStack {
                    Rectangle()
                        .fill(.clear)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                }
                .frame(width: 24, height: 12)
                .contentShape(Rectangle())
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
        if let channel = row.channel {
            return channel
        }

        guard row.user != nil, let channelID = row.channelID else {
            return nil
        }

        return channelsByID[channelID]
    }

    private var dropAcceptance: ChannelDropAcceptance? {
        if row.channel != nil {
            return .anySession
        }

        guard row.user != nil, let currentSessionID else {
            return nil
        }

        return .specificSession(currentSessionID)
    }

    private func channelLinkHelpText(for channel: MumbleChannel) -> String {
        let linkedCount = channel.linkedChannelIDs.count
        if linkedCount == 1 {
            return "Linked to 1 channel"
        }

        return "Linked to \(linkedCount) channels"
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
    let userDisplayRole: MumbleChannelTreeNode.UserDisplayRole
    let talkState: MumbleUserTalkState
    let isCurrentSession: Bool

    var body: some View {
        HStack(spacing: 8) {
            indicatorImage
                .foregroundStyle(talkState.indicatorColor(for: userDisplayRole))
                .help(talkState.helpText(for: userDisplayRole))
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

    @ViewBuilder
    private var indicatorImage: some View {
        switch userDisplayRole {
        case .listener:
            Image(systemName: "ear.fill")
                .font(.system(size: 12, weight: .semibold))
        case .member:
            switch talkState {
            case .passive:
                Image(systemName: "person.fill")
                    .font(.system(size: 12, weight: .semibold))
            case .talking, .whispering, .shouting, .channelListening:
                Image("person.radiowaves.left.and.right.fill")
                    .renderingMode(.template)
                    .font(.system(size: 12, weight: .semibold))
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

struct ChannelTreeVisibleRow: Identifiable, Hashable {
    let id: MumbleChannelTreeNode.RowID
    let kind: MumbleChannelTreeNode.Kind
    let title: String
    let channel: MumbleChannel?
    let user: MumbleUser?
    let userDisplayRole: MumbleChannelTreeNode.UserDisplayRole?
    let channelID: UInt32?
    let depth: Int
    let isExpanded: Bool?

    static func makeVisibleRows(
        from nodes: [MumbleChannelTreeNode],
        expansionOverrides: [UInt32: Bool],
        occupancyByChannelID: [UInt32: Bool]
    ) -> [ChannelTreeVisibleRow] {
        var rows: [ChannelTreeVisibleRow] = []
        rows.reserveCapacity(nodes.count)

        for node in nodes {
            appendVisibleRows(
                from: node,
                depth: 0,
                expansionOverrides: expansionOverrides,
                occupancyByChannelID: occupancyByChannelID,
                rows: &rows
            )
        }

        return rows
    }

    private static func appendVisibleRows(
        from node: MumbleChannelTreeNode,
        depth: Int,
        expansionOverrides: [UInt32: Bool],
        occupancyByChannelID: [UInt32: Bool],
        rows: inout [ChannelTreeVisibleRow]
    ) {
        let children = node.children ?? []
        let isExpanded: Bool? = {
            guard node.kind == .channel, let channelID = node.channelID, children.isEmpty == false else {
                return nil
            }

            return expansionOverrides[channelID] ?? occupancyByChannelID[channelID] ?? false
        }()

        rows.append(
            ChannelTreeVisibleRow(
                id: node.id,
                kind: node.kind,
                title: node.title,
                channel: node.channel,
                user: node.user,
                userDisplayRole: node.userDisplayRole,
                channelID: node.channelID,
                depth: depth,
                isExpanded: isExpanded
            )
        )

        guard isExpanded == true else {
            return
        }

        for child in children {
            appendVisibleRows(
                from: child,
                depth: depth + 1,
                expansionOverrides: expansionOverrides,
                occupancyByChannelID: occupancyByChannelID,
                rows: &rows
            )
        }
    }
}

struct MumbleChannelTreeNode: Identifiable, Hashable {
    enum RowID: Hashable {
        case channel(UInt32)
        case user(sessionID: UInt32, channelID: UInt32, role: UserDisplayRole)
    }

    enum Kind: Hashable {
        case channel
        case user
    }

    enum UserDisplayRole: Hashable {
        case member
        case listener
    }

    let id: RowID
    let kind: Kind
    let title: String
    let channel: MumbleChannel?
    let user: MumbleUser?
    let userDisplayRole: UserDisplayRole?
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
        let childrenByParentID = Dictionary(grouping: channels.compactMap { channel -> (UInt32, MumbleChannel)? in
            guard let parentID = channel.parentID, channelsByID[parentID] != nil else {
                return nil
            }

            return (parentID, channel)
        }, by: \.0)
        .mapValues { childChannels in
            childChannels
                .map(\.1)
                .sorted(by: sortComparator)
        }
        let usersByChannelID = Dictionary(grouping: users.flatMap { user -> [(UInt32, ChannelUserPlacement)] in
            var placements: [(UInt32, ChannelUserPlacement)] = []

            if let channelID = user.channelID, channelsByID[channelID] != nil {
                placements.append((channelID, ChannelUserPlacement(user: user, role: .member)))
            }

            for channelID in user.listeningChannelIDs where channelsByID[channelID] != nil {
                placements.append((channelID, ChannelUserPlacement(user: user, role: .listener)))
            }

            return placements
        }, by: \.0)
        .mapValues { groupedUsers in
            groupedUsers
                .map(\.1)
                .sorted(by: userPlacementSortComparator)
        }
        let sortedChannels = channels.sorted(by: sortComparator)
        let rootChannels = sortedChannels.filter { channel in
            guard let parentID = channel.parentID else {
                return true
            }

            return channelsByID[parentID] == nil
        }

        return rootChannels.map {
            makeNode(
                from: $0,
                childrenByParentID: childrenByParentID,
                usersByChannelID: usersByChannelID
            )
        }
    }

    private static func makeNode(
        from channel: MumbleChannel,
        childrenByParentID: [UInt32: [MumbleChannel]],
        usersByChannelID: [UInt32: [ChannelUserPlacement]]
    ) -> MumbleChannelTreeNode {
        let childChannels = (childrenByParentID[channel.id] ?? [])
            .map {
                makeNode(
                    from: $0,
                    childrenByParentID: childrenByParentID,
                    usersByChannelID: usersByChannelID
                )
            }
        let childUsers = (usersByChannelID[channel.id] ?? []).map { placement in
            MumbleChannelTreeNode(
                id: .user(sessionID: placement.user.id, channelID: channel.id, role: placement.role),
                kind: .user,
                title: placement.user.name,
                channel: nil,
                user: placement.user,
                userDisplayRole: placement.role,
                channelID: channel.id,
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
            userDisplayRole: nil,
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

    private static let userPlacementSortComparator: (ChannelUserPlacement, ChannelUserPlacement) -> Bool = { lhs, rhs in
        if lhs.role != rhs.role {
            return lhs.role == .member
        }

        let comparison = lhs.user.name.localizedStandardCompare(rhs.user.name)

        if comparison == .orderedSame {
            return lhs.user.id < rhs.user.id
        }

        return comparison == .orderedAscending
    }
}

private struct ChannelUserPlacement: Hashable {
    let user: MumbleUser
    let role: MumbleChannelTreeNode.UserDisplayRole
}

private struct UserStatusBadge: Identifiable, Hashable {
    let id: String
    let systemImage: String
    let color: Color
    let helpText: String
}

private extension MumbleUserTalkState {
    func indicatorColor(for userDisplayRole: MumbleChannelTreeNode.UserDisplayRole) -> Color {
        switch userDisplayRole {
        case .listener:
            return .gray
        case .member:
            switch self {
            case .passive:
                return .green
            case .talking:
                return .blue
            case .shouting:
                return .blue
            case .whispering:
                return .yellow
            case .channelListening:
                return .gray
            }
        }
    }

    func helpText(for userDisplayRole: MumbleChannelTreeNode.UserDisplayRole) -> String {
        switch userDisplayRole {
        case .listener:
            return "Listening to this channel"
        case .member:
            switch self {
            case .passive:
                return "Idle"
            case .talking:
                return "Talking"
            case .shouting:
                return "Shouting"
            case .whispering:
                return "Whispering"
            case .channelListening:
                return "Talking via channel listener"
            }
        }
    }
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
