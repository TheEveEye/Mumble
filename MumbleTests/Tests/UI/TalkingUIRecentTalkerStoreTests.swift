import Foundation
import Testing
@testable import Mumble

struct TalkingUIRecentTalkerStoreTests {
    @Test
    func activeTalkerAppearsImmediately() {
        var store = TalkingUIRecentTalkerStore()
        let now = Date(timeIntervalSinceReferenceDate: 100)

        store.apply(sessionID: 7, talkState: .talking, now: now, retentionSeconds: 5)

        let entries = store.visibleEntries(
            users: [makeUser(id: 7)],
            channels: [makeChannel(id: 1)],
            currentSessionID: nil,
            alwaysIncludeCurrentUser: false,
            now: now
        )

        #expect(entries.map(\.user.id) == [7])
        #expect(entries.first?.talkState == .talking)
    }

    @Test
    func passiveTalkerRemainsUntilConfiguredExpiry() {
        var store = TalkingUIRecentTalkerStore()
        let start = Date(timeIntervalSinceReferenceDate: 100)

        store.apply(sessionID: 7, talkState: .talking, now: start, retentionSeconds: 5)
        store.apply(sessionID: 7, talkState: .passive, now: start.addingTimeInterval(1), retentionSeconds: 5)

        let retainedEntries = store.visibleEntries(
            users: [makeUser(id: 7)],
            channels: [makeChannel(id: 1)],
            currentSessionID: nil,
            alwaysIncludeCurrentUser: false,
            now: start.addingTimeInterval(5.9)
        )
        let expiredEntries = store.visibleEntries(
            users: [makeUser(id: 7)],
            channels: [makeChannel(id: 1)],
            currentSessionID: nil,
            alwaysIncludeCurrentUser: false,
            now: start.addingTimeInterval(6.1)
        )

        #expect(retainedEntries.map(\.user.id) == [7])
        #expect(retainedEntries.first?.talkState == .passive)
        #expect(expiredEntries.isEmpty)
    }

    @Test
    func expiredTalkersAreRemovedOnCleanup() {
        var store = TalkingUIRecentTalkerStore()
        let start = Date(timeIntervalSinceReferenceDate: 100)

        store.apply(sessionID: 7, talkState: .talking, now: start, retentionSeconds: 5)
        store.apply(sessionID: 7, talkState: .passive, now: start, retentionSeconds: 5)

        let didChange = store.cleanupExpired(now: start.addingTimeInterval(5.1))
        let entries = store.visibleEntries(
            users: [makeUser(id: 7)],
            channels: [makeChannel(id: 1)],
            currentSessionID: nil,
            alwaysIncludeCurrentUser: false,
            now: start.addingTimeInterval(5.1)
        )

        #expect(didChange)
        #expect(entries.isEmpty)
        #expect(store.isEmpty)
    }

    @Test
    func repeatedTalkEventsExtendVisibility() {
        var store = TalkingUIRecentTalkerStore()
        let start = Date(timeIntervalSinceReferenceDate: 100)

        store.apply(sessionID: 7, talkState: .talking, now: start, retentionSeconds: 5)
        store.apply(sessionID: 7, talkState: .passive, now: start.addingTimeInterval(1), retentionSeconds: 5)
        store.apply(sessionID: 7, talkState: .shouting, now: start.addingTimeInterval(3), retentionSeconds: 5)
        store.apply(sessionID: 7, talkState: .passive, now: start.addingTimeInterval(4), retentionSeconds: 5)

        let entries = store.visibleEntries(
            users: [makeUser(id: 7)],
            channels: [makeChannel(id: 1)],
            currentSessionID: nil,
            alwaysIncludeCurrentUser: false,
            now: start.addingTimeInterval(8.5)
        )

        #expect(entries.map(\.user.id) == [7])
    }

    @Test
    func disconnectedUnknownUsersAreRemovedDuringReconciliation() {
        var store = TalkingUIRecentTalkerStore()
        let now = Date(timeIntervalSinceReferenceDate: 100)

        store.apply(sessionID: 7, talkState: .talking, now: now, retentionSeconds: 5)

        let didChange = store.reconcileKnownUsers([makeUser(id: 8)])
        let entries = store.visibleEntries(
            users: [makeUser(id: 8)],
            channels: [makeChannel(id: 1)],
            currentSessionID: nil,
            alwaysIncludeCurrentUser: false,
            now: now
        )

        #expect(didChange)
        #expect(entries.isEmpty)
    }

    @Test
    func removedTalkerNoLongerAppears() {
        var store = TalkingUIRecentTalkerStore()
        let now = Date(timeIntervalSinceReferenceDate: 100)

        store.apply(sessionID: 7, talkState: .talking, now: now, retentionSeconds: 5)
        store.remove(sessionID: 7)

        let entries = store.visibleEntries(
            users: [makeUser(id: 7)],
            channels: [makeChannel(id: 1)],
            currentSessionID: 7,
            alwaysIncludeCurrentUser: false,
            now: now
        )

        #expect(entries.isEmpty)
    }

    @Test
    func optionalLocalUserVisibilityInsertsCurrentUserWhenIdle() {
        let store = TalkingUIRecentTalkerStore()
        let now = Date(timeIntervalSinceReferenceDate: 100)

        let entries = store.visibleEntries(
            users: [makeUser(id: 7)],
            channels: [makeChannel(id: 1)],
            currentSessionID: 7,
            alwaysIncludeCurrentUser: true,
            now: now
        )

        #expect(entries.map(\.user.id) == [7])
        #expect(entries.first?.talkState == .passive)
        #expect(entries.first?.isCurrentSession == true)
        #expect(entries.first?.isActivelyTalking == false)
    }

    @Test
    func activeTalkerEntryReportsActivelyTalking() {
        var store = TalkingUIRecentTalkerStore()
        let now = Date(timeIntervalSinceReferenceDate: 100)

        store.apply(sessionID: 7, talkState: .talking, now: now, retentionSeconds: 5)

        let entries = store.visibleEntries(
            users: [makeUser(id: 7)],
            channels: [makeChannel(id: 1)],
            currentSessionID: 7,
            alwaysIncludeCurrentUser: true,
            now: now
        )

        #expect(entries.first?.isActivelyTalking == true)
    }

    @Test
    func talkingUISnapshotExpandsColumnsWhenCrowded() {
        let snapshot = TalkingUISnapshot(
            entries: (1 ... 12).map { id in
                TalkingUIVisibleEntry(
                    user: makeUser(id: UInt32(id)),
                    channel: makeChannel(id: 1),
                    talkState: .talking,
                    isCurrentSession: false,
                    isRetainedAfterSpeaking: false
                )
            },
            fontSizePercentage: 100,
            automaticallyExpandsWidth: true,
            columnCount: 1
        )

        #expect(snapshot.preferredAutoExpandedColumnCount(forContentHeight: 120) > 1)
    }

    @Test
    func talkingUISnapshotReturnsSingleColumnWhenNotCrowded() {
        let snapshot = TalkingUISnapshot(
            entries: (1 ... 2).map { id in
                TalkingUIVisibleEntry(
                    user: makeUser(id: UInt32(id)),
                    channel: makeChannel(id: 1),
                    talkState: .talking,
                    isCurrentSession: false,
                    isRetainedAfterSpeaking: false
                )
            },
            fontSizePercentage: 100,
            automaticallyExpandsWidth: true,
            columnCount: 1
        )

        #expect(snapshot.preferredAutoExpandedColumnCount(forContentHeight: 260) == 1)
    }

    private func makeChannel(id: UInt32) -> MumbleChannel {
        MumbleChannel(
            id: id,
            name: "Root",
            parentID: nil,
            position: 0,
            linkedChannelIDs: []
        )
    }

    private func makeUser(id: UInt32, channelID: UInt32 = 1) -> MumbleUser {
        MumbleUser(
            id: id,
            name: "User \(id)",
            channelID: channelID,
            listeningChannelIDs: [],
            registeredUserID: nil,
            isServerMuted: false,
            isServerDeafened: false,
            isSuppressed: false,
            isSelfMuted: false,
            isSelfDeafened: false
        )
    }
}
