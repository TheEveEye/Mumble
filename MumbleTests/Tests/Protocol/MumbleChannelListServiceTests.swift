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
    func userCanTransmitVoiceOnlyWhenNoMuteOrSuppressionFlagIsSet() {
        #expect(makeUser(id: 1, name: "Ready", channelID: 1).canTransmitVoice)

        var serverMutedUser = makeUser(id: 2, name: "Server Muted", channelID: 1)
        serverMutedUser.isServerMuted = true
        #expect(serverMutedUser.canTransmitVoice == false)

        var serverDeafenedUser = makeUser(id: 3, name: "Server Deafened", channelID: 1)
        serverDeafenedUser.isServerDeafened = true
        #expect(serverDeafenedUser.canTransmitVoice == false)

        var suppressedUser = makeUser(id: 4, name: "Suppressed", channelID: 1)
        suppressedUser.isSuppressed = true
        #expect(suppressedUser.canTransmitVoice == false)

        var selfMutedUser = makeUser(id: 5, name: "Self Muted", channelID: 1)
        selfMutedUser.isSelfMuted = true
        #expect(selfMutedUser.canTransmitVoice == false)

        var selfDeafenedUser = makeUser(id: 6, name: "Self Deafened", channelID: 1)
        selfDeafenedUser.isSelfDeafened = true
        #expect(selfDeafenedUser.canTransmitVoice == false)
    }

    @Test
    func userRemoveDecoderParsesActorReasonAndBan() {
        var payload = Data()
        MumbleProtobufWire.appendVarintField(1, value: 42, to: &payload)
        MumbleProtobufWire.appendVarintField(2, value: 7, to: &payload)
        MumbleProtobufWire.appendStringField(3, value: "AFK in briefing", to: &payload)
        MumbleProtobufWire.appendBoolField(4, value: true, to: &payload)

        let decoded = MumbleSessionMessageDecoder.decodeUserRemove(from: payload)

        #expect(decoded?.sessionID == 42)
        #expect(decoded?.actorSessionID == 7)
        #expect(decoded?.reason == "AFK in briefing")
        #expect(decoded?.isBan == true)
    }

    @Test
    func joinChannelPacketEncodesSessionAndDestinationChannel() {
        let payload = MumbleSessionPayloads.joinChannelPacket(sessionID: 42, channelID: 7)

        let decoded = MumbleSessionMessageDecoder.decodeUserState(from: payload)

        #expect(decoded?.sessionID == 42)
        #expect(decoded?.channelID == 7)
    }

    @Test
    func textMessagePacketEncodesChannelTargetAndMessage() {
        let payload = MumbleSessionPayloads.textMessagePacket(
            channelIDs: [7],
            message: "Ready"
        )

        let fields = decodeTopLevelFields(from: payload)

        #expect(fields.varints[2] == nil)
        #expect(fields.varints[3] == [7])
        #expect(fields.varints[4] == nil)
        #expect(fields.bytes[5]?.first.map { String(decoding: $0, as: UTF8.self) } == "Ready")
    }

    @Test
    func textMessagePacketEncodesUserTargetAndTreeTarget() {
        let userPayload = MumbleSessionPayloads.textMessagePacket(
            sessionIDs: [42],
            message: "Private"
        )
        let treePayload = MumbleSessionPayloads.textMessagePacket(
            treeIDs: [9],
            message: "Tree"
        )

        let userFields = decodeTopLevelFields(from: userPayload)
        let treeFields = decodeTopLevelFields(from: treePayload)

        #expect(userFields.varints[2] == [42])
        #expect(userFields.bytes[5]?.first.map { String(decoding: $0, as: UTF8.self) } == "Private")
        #expect(treeFields.varints[4] == [9])
        #expect(treeFields.bytes[5]?.first.map { String(decoding: $0, as: UTF8.self) } == "Tree")
    }

    @Test
    func textMessageDecoderParsesActorTargetsAndBody() {
        var payload = Data()
        MumbleProtobufWire.appendVarintField(1, value: 42, to: &payload)
        MumbleProtobufWire.appendVarintField(2, value: 12, to: &payload)
        MumbleProtobufWire.appendVarintField(3, value: 7, to: &payload)
        MumbleProtobufWire.appendVarintField(4, value: 9, to: &payload)
        MumbleProtobufWire.appendStringField(5, value: "<strong>Hello</strong>", to: &payload)

        let decoded = MumbleSessionMessageDecoder.decodeTextMessage(from: payload)

        #expect(decoded?.actorSessionID == 42)
        #expect(decoded?.sessionIDs == [12])
        #expect(decoded?.channelIDs == [7])
        #expect(decoded?.treeIDs == [9])
        #expect(decoded?.message == "<strong>Hello</strong>")
        #expect(decoded?.scope == .tree)
    }

    @Test
    func chatFormatterEscapesPlainTextForHtmlTransport() {
        let escaped = MumbleChatMessageFormatter.htmlEscapedPlainText(
            "<b>Alpha & \"Bravo\"</b>\r\nIt's ready"
        )

        #expect(escaped == "&lt;b&gt;Alpha &amp; &quot;Bravo&quot;&lt;/b&gt;<br>It&#39;s ready")
    }

    @Test
    func chatTargetResolverUsesSelectedUserWhenAvailable() {
        let channels = [MumbleChannel(id: 7, name: "General", parentID: nil, position: 0, linkedChannelIDs: [])]
        let users = [
            makeUser(id: 1, name: "Me", channelID: 7),
            makeUser(id: 2, name: "Bravo", channelID: 7),
        ]

        let resolved = MumbleChatTargetResolver.resolve(
            selection: .user(2),
            currentSessionID: 1,
            currentChannelID: 7,
            channels: channels,
            users: users
        )

        #expect(resolved == MumbleResolvedChatTarget.user(users[1]))
    }

    @Test
    func chatTargetResolverUsesSelectedChannelWhenAvailable() {
        let channels = [
            MumbleChannel(id: 7, name: "General", parentID: nil, position: 0, linkedChannelIDs: []),
            MumbleChannel(id: 9, name: "Command", parentID: nil, position: 1, linkedChannelIDs: []),
        ]
        let users = [makeUser(id: 1, name: "Me", channelID: 7)]

        let resolved = MumbleChatTargetResolver.resolve(
            selection: .channel(9),
            currentSessionID: 1,
            currentChannelID: 7,
            channels: channels,
            users: users
        )

        #expect(resolved == MumbleResolvedChatTarget.channel(channels[1]))
    }

    @Test
    func chatTargetResolverFallsBackToCurrentChannelForCurrentUserOrMissingSelection() {
        let channels = [MumbleChannel(id: 7, name: "General", parentID: nil, position: 0, linkedChannelIDs: [])]
        let users = [makeUser(id: 1, name: "Me", channelID: 7)]

        let currentUserSelection = MumbleChatTargetResolver.resolve(
            selection: .user(1),
            currentSessionID: 1,
            currentChannelID: 7,
            channels: channels,
            users: users
        )
        let missingSelection = MumbleChatTargetResolver.resolve(
            selection: nil,
            currentSessionID: 1,
            currentChannelID: 7,
            channels: channels,
            users: users
        )

        #expect(currentUserSelection == MumbleResolvedChatTarget.channel(channels[0]))
        #expect(missingSelection == MumbleResolvedChatTarget.channel(channels[0]))
    }

    @Test
    func selfMuteDeafStatePacketEncodesMutedOnlyWithoutSessionID() {
        let payload = MumbleSessionPayloads.selfMuteDeafStatePacket(
            isSelfMuted: true,
            isSelfDeafened: false
        )

        let fields = decodeTopLevelFields(from: payload)

        #expect(fields.varints[1] == nil)
        #expect(fields.varints[9] == [1])
        #expect(fields.varints[10] == [0])
    }

    @Test
    func selfMuteDeafStatePacketEncodesUnmutedAndUndeafenedWithoutSessionID() {
        let payload = MumbleSessionPayloads.selfMuteDeafStatePacket(
            isSelfMuted: false,
            isSelfDeafened: false
        )

        let fields = decodeTopLevelFields(from: payload)

        #expect(fields.varints[1] == nil)
        #expect(fields.varints[9] == [0])
        #expect(fields.varints[10] == [0])
    }

    @Test
    func selfMuteDeafStatePacketEncodesMutedAndDeafenedWithoutSessionID() {
        let payload = MumbleSessionPayloads.selfMuteDeafStatePacket(
            isSelfMuted: true,
            isSelfDeafened: true
        )

        let fields = decodeTopLevelFields(from: payload)

        #expect(fields.varints[1] == nil)
        #expect(fields.varints[9] == [1])
        #expect(fields.varints[10] == [1])
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
    func linkedChannelVoiceTargetPacketEncodesLinkedChannelRegistration() {
        let payload = MumbleSessionPayloads.linkedChannelVoiceTargetPacket(channelID: 63)

        let topLevelFields = decodeTopLevelFields(from: payload)
        #expect(topLevelFields.varints[1] == [UInt64(MumbleSessionPayloads.linkedChannelVoiceTargetID)])

        guard let targetPayload = topLevelFields.bytes[2]?.first else {
            Issue.record("Expected nested voice target payload")
            return
        }

        let targetFields = decodeTopLevelFields(from: targetPayload)
        #expect(targetFields.varints[2] == [63])
        #expect(targetFields.varints[4] == [1])
    }

    @Test
    func localChannelVoiceTargetPacketEncodesChannelWithoutLinkedFlag() {
        let payload = MumbleSessionPayloads.localChannelVoiceTargetPacket(channelID: 63)

        let topLevelFields = decodeTopLevelFields(from: payload)
        #expect(topLevelFields.varints[1] == [UInt64(MumbleSessionPayloads.localChannelVoiceTargetID)])

        guard let targetPayload = topLevelFields.bytes[2]?.first else {
            Issue.record("Expected nested voice target payload")
            return
        }

        let targetFields = decodeTopLevelFields(from: targetPayload)
        #expect(targetFields.varints[2] == [63])
        #expect(targetFields.varints[4] == nil)
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
    func channelTreeVisibleRowsFlattenExpandedBranches() {
        let channels = [
            MumbleChannel(id: 0, name: "Root", parentID: nil, position: 0, linkedChannelIDs: []),
            MumbleChannel(id: 1, name: "Fleets", parentID: 0, position: 0, linkedChannelIDs: []),
            MumbleChannel(id: 2, name: "General", parentID: 0, position: 2, linkedChannelIDs: []),
            MumbleChannel(id: 3, name: "Command", parentID: 1, position: 1, linkedChannelIDs: []),
        ]
        let users = [
            makeUser(id: 10, name: "Bravo", channelID: 1),
            makeUser(id: 11, name: "Alpha", channelID: 3),
        ]
        let tree = MumbleChannelTreeNode.makeTree(from: channels, users: users)
        let occupancyByChannelID = Dictionary(uniqueKeysWithValues: tree.flatMap(\.channelOccupancyStates))

        let defaultRows = ChannelTreeVisibleRow.makeVisibleRows(
            from: tree,
            expansionOverrides: [:],
            occupancyByChannelID: occupancyByChannelID
        )
        #expect(defaultRows.map(\.title) == ["Root", "Fleets", "Bravo", "Command", "Alpha", "General"])
        #expect(defaultRows.map(\.depth) == [0, 1, 2, 2, 3, 1])

        let collapsedRows = ChannelTreeVisibleRow.makeVisibleRows(
            from: tree,
            expansionOverrides: [1: false],
            occupancyByChannelID: occupancyByChannelID
        )
        #expect(collapsedRows.map(\.title) == ["Root", "Fleets", "General"])
    }

    @Test
    func channelTreeBuilderHandlesLargeFlatHierarchy() {
        var channels = [
            MumbleChannel(id: 0, name: "Root", parentID: nil, position: 0, linkedChannelIDs: [])
        ]
        channels.append(
            contentsOf: (1...2_000).map {
                MumbleChannel(id: UInt32($0), name: "Channel \($0)", parentID: 0, position: $0, linkedChannelIDs: [])
            }
        )
        let users = (1...1_000).map {
            makeUser(id: UInt32($0), name: "User \($0)", channelID: UInt32($0 * 2))
        }

        let tree = MumbleChannelTreeNode.makeTree(from: channels, users: users)

        #expect(tree.map(\.title) == ["Root"])
        #expect(tree.first?.children?.count == 2_000)
        #expect(tree.first?.containsUsersInSubtree == true)
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

    private func makeUser(id: UInt32, name: String, channelID: UInt32) -> MumbleUser {
        MumbleUser(
            id: id,
            name: name,
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

    private func decodeTopLevelFields(from payload: Data) -> (varints: [UInt64: [UInt64]], bytes: [UInt64: [Data]]) {
        let slice = payload[...]
        var index = slice.startIndex
        var varints: [UInt64: [UInt64]] = [:]
        var bytes: [UInt64: [Data]] = [:]

        while index < slice.endIndex {
            guard let key = MumbleProtobufWire.decodeVarint(from: slice, index: &index) else {
                Issue.record("Failed to decode field key")
                break
            }

            let fieldNumber = key >> 3
            let wireType = key & 0x07

            switch wireType {
            case 0:
                guard let value = MumbleProtobufWire.decodeVarint(from: slice, index: &index) else {
                    Issue.record("Failed to decode varint field \(fieldNumber)")
                    return (varints, bytes)
                }

                varints[fieldNumber, default: []].append(value)
            case 2:
                guard let value = MumbleProtobufWire.decodeLengthDelimited(from: slice, index: &index) else {
                    Issue.record("Failed to decode bytes field \(fieldNumber)")
                    return (varints, bytes)
                }

                bytes[fieldNumber, default: []].append(value)
            default:
                guard MumbleProtobufWire.skipField(wireType: wireType, payload: slice, index: &index) else {
                    Issue.record("Failed to skip unsupported field \(fieldNumber)")
                    return (varints, bytes)
                }
            }
        }

        return (varints, bytes)
    }
}
