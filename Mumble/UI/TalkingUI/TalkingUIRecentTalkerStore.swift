import Foundation

struct TalkingUIVisibleEntry: Identifiable, Equatable {
    let user: MumbleUser
    let channel: MumbleChannel?
    let talkState: MumbleUserTalkState
    let isCurrentSession: Bool
    let isRetainedAfterSpeaking: Bool

    var id: UInt32 {
        user.id
    }

    var isActivelyTalking: Bool {
        talkState != .passive
    }
}

struct TalkingUIRecentTalkerStore: Equatable {
    private struct Entry: Equatable {
        var talkState: MumbleUserTalkState
        var expiresAt: Date?
        var lastUpdatedAt: Date
    }

    private var entriesBySessionID: [UInt32: Entry] = [:]

    var isEmpty: Bool {
        entriesBySessionID.isEmpty
    }

    mutating func apply(
        sessionID: UInt32,
        talkState: MumbleUserTalkState,
        now: Date = Date(),
        retentionSeconds: TimeInterval
    ) {
        if talkState == .passive {
            guard var entry = entriesBySessionID[sessionID] else {
                return
            }

            entry.talkState = .passive
            entry.expiresAt = now.addingTimeInterval(retentionSeconds)
            entry.lastUpdatedAt = now
            entriesBySessionID[sessionID] = entry
            return
        }

        entriesBySessionID[sessionID] = Entry(
            talkState: talkState,
            expiresAt: nil,
            lastUpdatedAt: now
        )
    }

    mutating func clear() {
        entriesBySessionID.removeAll()
    }

    mutating func remove(sessionID: UInt32) {
        entriesBySessionID.removeValue(forKey: sessionID)
    }

    @discardableResult
    mutating func cleanupExpired(now: Date = Date()) -> Bool {
        let originalCount = entriesBySessionID.count
        entriesBySessionID = entriesBySessionID.filter { _, entry in
            guard let expiresAt = entry.expiresAt else {
                return true
            }

            return expiresAt > now
        }

        return entriesBySessionID.count != originalCount
    }

    @discardableResult
    mutating func reconcileKnownUsers(_ users: [MumbleUser]) -> Bool {
        let knownSessionIDs = Set(users.map(\.id))
        let originalCount = entriesBySessionID.count
        entriesBySessionID = entriesBySessionID.filter { sessionID, _ in
            knownSessionIDs.contains(sessionID)
        }

        return entriesBySessionID.count != originalCount
    }

    func visibleEntries(
        users: [MumbleUser],
        channels: [MumbleChannel],
        currentSessionID: UInt32?,
        alwaysIncludeCurrentUser: Bool,
        now: Date = Date()
    ) -> [TalkingUIVisibleEntry] {
        let usersBySessionID = Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })
        let channelsByID = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })

        var visibleEntries = entriesBySessionID.compactMap { sessionID, entry -> TalkingUIVisibleEntry? in
            guard let user = usersBySessionID[sessionID], isVisible(entry, now: now) else {
                return nil
            }

            return TalkingUIVisibleEntry(
                user: user,
                channel: user.channelID.flatMap { channelsByID[$0] },
                talkState: entry.talkState,
                isCurrentSession: sessionID == currentSessionID,
                isRetainedAfterSpeaking: entry.expiresAt != nil
            )
        }

        if
            alwaysIncludeCurrentUser,
            let currentSessionID,
            visibleEntries.contains(where: { $0.user.id == currentSessionID }) == false,
            let currentUser = usersBySessionID[currentSessionID]
        {
            visibleEntries.append(
                TalkingUIVisibleEntry(
                    user: currentUser,
                    channel: currentUser.channelID.flatMap { channelsByID[$0] },
                    talkState: .passive,
                    isCurrentSession: true,
                    isRetainedAfterSpeaking: false
                )
            )
        }

        return visibleEntries.sorted(by: Self.visibleEntrySortComparator)
    }

    private func isVisible(_ entry: Entry, now: Date) -> Bool {
        guard let expiresAt = entry.expiresAt else {
            return true
        }

        return expiresAt > now
    }

    private static let visibleEntrySortComparator: (TalkingUIVisibleEntry, TalkingUIVisibleEntry) -> Bool = { lhs, rhs in
        let lhsChannelName = lhs.channel?.name ?? ""
        let rhsChannelName = rhs.channel?.name ?? ""

        if lhsChannelName.localizedStandardCompare(rhsChannelName) != .orderedSame {
            return lhsChannelName.localizedStandardCompare(rhsChannelName) == .orderedAscending
        }

        let nameComparison = lhs.user.name.localizedStandardCompare(rhs.user.name)
        if nameComparison == .orderedSame {
            return lhs.user.id < rhs.user.id
        }

        return nameComparison == .orderedAscending
    }
}
