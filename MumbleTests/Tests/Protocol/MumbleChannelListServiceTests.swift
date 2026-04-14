import Foundation
import Testing
@testable import Mumble

struct MumbleChannelListServiceTests {
    @Test
    func channelStateDecoderParsesNameParentAndPosition() {
        var payload = Data()
        MumbleProtobufWire.appendVarintField(1, value: 7, to: &payload)
        MumbleProtobufWire.appendVarintField(2, value: 1, to: &payload)
        MumbleProtobufWire.appendStringField(3, value: "General", to: &payload)
        MumbleProtobufWire.appendVarintField(9, value: 4, to: &payload)

        let decoded = MumbleSessionMessageDecoder.decodeChannelState(from: payload)

        #expect(decoded?.channelID == 7)
        #expect(decoded?.hasParent == true)
        #expect(decoded?.parentID == 1)
        #expect(decoded?.name == "General")
        #expect(decoded?.position == 4)
    }

    @Test
    func serverSyncDecoderReturnsWelcomeText() {
        var payload = Data()
        MumbleProtobufWire.appendVarintField(1, value: 12, to: &payload)
        MumbleProtobufWire.appendStringField(3, value: "Welcome aboard", to: &payload)

        let decoded = MumbleSessionMessageDecoder.decodeServerSync(from: payload)

        #expect(decoded?.currentSessionID == 12)
        #expect(decoded?.welcomeText == "Welcome aboard")
    }

    @Test
    func userStateDecoderParsesChannelMembershipAndStatusFlags() {
        var payload = Data()
        MumbleProtobufWire.appendVarintField(1, value: 42, to: &payload)
        MumbleProtobufWire.appendStringField(3, value: "Alysa Blueberry", to: &payload)
        MumbleProtobufWire.appendVarintField(4, value: 7, to: &payload)
        MumbleProtobufWire.appendVarintField(5, value: 3, to: &payload)
        MumbleProtobufWire.appendBoolField(6, value: true, to: &payload)
        MumbleProtobufWire.appendBoolField(8, value: true, to: &payload)
        MumbleProtobufWire.appendBoolField(9, value: true, to: &payload)

        let decoded = MumbleSessionMessageDecoder.decodeUserState(from: payload)

        #expect(decoded?.sessionID == 42)
        #expect(decoded?.name == "Alysa Blueberry")
        #expect(decoded?.registeredUserID == 7)
        #expect(decoded?.channelID == 3)
        #expect(decoded?.isServerMuted == true)
        #expect(decoded?.isSuppressed == true)
        #expect(decoded?.isSelfMuted == true)
        #expect(decoded?.isServerDeafened == nil)
    }

    @Test
    func channelTreeBuilderCreatesHierarchyWithUsers() {
        let channels = [
            MumbleChannel(id: 0, name: "Root", parentID: nil, position: 0),
            MumbleChannel(id: 3, name: "Command", parentID: 1, position: 1),
            MumbleChannel(id: 1, name: "Fleets", parentID: 0, position: 0),
            MumbleChannel(id: 2, name: "General", parentID: 0, position: 2),
        ]
        let users = [
            MumbleUser(
                id: 10,
                name: "Bravo",
                channelID: 1,
                registeredUserID: 1,
                isServerMuted: false,
                isServerDeafened: false,
                isSuppressed: false,
                isSelfMuted: false,
                isSelfDeafened: false
            ),
            MumbleUser(
                id: 11,
                name: "Alpha",
                channelID: 3,
                registeredUserID: nil,
                isServerMuted: false,
                isServerDeafened: false,
                isSuppressed: false,
                isSelfMuted: false,
                isSelfDeafened: false
            ),
        ]

        let tree = MumbleChannelTreeNode.makeTree(from: channels, users: users)

        #expect(tree.map(\.title) == ["Root"])
        #expect(tree.first?.children?.map(\.title) == ["Fleets", "General"])
        #expect(tree.first?.children?.first?.children?.map(\.title) == ["Bravo", "Command"])
        #expect(tree.first?.children?.first?.children?.last?.children?.map(\.title) == ["Alpha"])
        #expect(tree.first?.channelOccupancyStates.map(\.0) == [0, 1, 3, 2])
        #expect(tree.first?.channelOccupancyStates.map(\.1) == [true, true, true, false])
    }
}
