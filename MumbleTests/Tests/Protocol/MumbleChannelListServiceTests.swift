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
        MumbleProtobufWire.appendVarintField(4, value: 8, to: &payload)
        MumbleProtobufWire.appendVarintField(6, value: 9, to: &payload)
        MumbleProtobufWire.appendVarintField(7, value: 10, to: &payload)
        MumbleProtobufWire.appendVarintField(9, value: 4, to: &payload)

        let decoded = MumbleSessionMessageDecoder.decodeChannelState(from: payload)

        #expect(decoded?.channelID == 7)
        #expect(decoded?.hasParent == true)
        #expect(decoded?.parentID == 1)
        #expect(decoded?.name == "General")
        #expect(decoded?.position == 4)
        #expect(decoded?.links == [8])
        #expect(decoded?.linksAdded == [9])
        #expect(decoded?.linksRemoved == [10])
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
    func joinChannelPacketEncodesSessionAndDestinationChannel() {
        let payload = MumbleSessionPayloads.joinChannelPacket(sessionID: 42, channelID: 7)

        let decoded = MumbleSessionMessageDecoder.decodeUserState(from: payload)

        #expect(decoded?.sessionID == 42)
        #expect(decoded?.channelID == 7)
    }

    @Test
    func cryptSetupPacketEncodesClientNonceForUdpHandshake() {
        let nonce = Data(repeating: 0xAB, count: 16)

        let payload = MumbleSessionPayloads.cryptSetupPacket(clientNonce: nonce)
        let decoded = MumbleSessionMessageDecoder.decodeCryptSetup(from: payload)

        #expect(decoded?.key == nil)
        #expect(decoded?.clientNonce == nonce)
        #expect(decoded?.serverNonce == nil)
    }

    @Test
    func channelTreeBuilderCreatesHierarchyWithUsers() {
        let channels = [
            MumbleChannel(id: 0, name: "Root", parentID: nil, position: 0, linkedChannelIDs: []),
            MumbleChannel(id: 3, name: "Command", parentID: 1, position: 1, linkedChannelIDs: [2]),
            MumbleChannel(id: 1, name: "Fleets", parentID: 0, position: 0, linkedChannelIDs: []),
            MumbleChannel(id: 2, name: "General", parentID: 0, position: 2, linkedChannelIDs: [3]),
        ]
        let users = [
            MumbleUser(
                id: 10,
                name: "Bravo",
                channelID: 1,
                listeningChannelIDs: [],
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
                listeningChannelIDs: [],
                registeredUserID: nil,
                isServerMuted: false,
                isServerDeafened: false,
                isSuppressed: false,
                isSelfMuted: false,
                isSelfDeafened: false
            ),
        ]

        let tree = MumbleChannelTreeNode.makeTree(from: channels, users: users)

        #expect(tree.map { $0.title } == ["Root"])
        #expect(tree.first?.children?.map { $0.title } == ["Fleets", "General"])
        #expect(tree.first?.children?.first?.children?.map { $0.title } == ["Bravo", "Command"])
        #expect(tree.first?.children?.first?.children?.last?.children?.map { $0.title } == ["Alpha"])
        #expect(tree.first?.children?.last?.channel?.isLinked == true)
        #expect(tree.first?.children?.first?.children?.last?.channel?.isLinked == true)
        #expect(tree.first?.channelOccupancyStates.map(\.0) == [0, 1, 3, 2])
        #expect(tree.first?.channelOccupancyStates.map(\.1) == [true, true, true, false])
    }

    @Test
    func linkedChannelClosureIncludesTransitiveLinks() {
        let channelsByID: [UInt32: MumbleChannel] = [
            10: MumbleChannel(id: 10, name: "A", parentID: nil, position: 0, linkedChannelIDs: [20]),
            20: MumbleChannel(id: 20, name: "B", parentID: nil, position: 1, linkedChannelIDs: [10, 30]),
            30: MumbleChannel(id: 30, name: "C", parentID: nil, position: 2, linkedChannelIDs: [20]),
            40: MumbleChannel(id: 40, name: "D", parentID: nil, position: 3, linkedChannelIDs: []),
        ]

        #expect(channelsByID.linkedClosure(startingAt: 10) == Set<UInt32>([10, 20, 30]))
        #expect(channelsByID.linkedClosure(startingAt: 30) == Set<UInt32>([10, 20, 30]))
        #expect(channelsByID.linkedClosure(startingAt: 40) == Set<UInt32>([40]))
    }

    @Test
    func reconnectPolicyUsesBoundedExponentialBackoff() {
        #expect(MumbleReconnectPolicy.maximumAttempts == 5)
        #expect(MumbleReconnectPolicy.delay(forAttempt: 1) == 1)
        #expect(MumbleReconnectPolicy.delay(forAttempt: 2) == 2)
        #expect(MumbleReconnectPolicy.delay(forAttempt: 3) == 4)
        #expect(MumbleReconnectPolicy.delay(forAttempt: 4) == 8)
        #expect(MumbleReconnectPolicy.delay(forAttempt: 5) == 15)
        #expect(MumbleReconnectPolicy.delay(forAttempt: 6) == 15)
    }
}
