import Foundation
import Testing
@testable import Mumble

struct MumbleServerStatusServiceTests {
    @Test
    func legacyPingRequestUsesExtendedPingLayout() {
        let timestamp: UInt64 = 0x01_23_45_67_89_AB_CD_EF

        let packet = MumbleLegacyPingPacket.makeExtendedPingRequest(timestamp: timestamp)

        #expect(packet.count == 12)
        #expect(packet.prefix(4).allSatisfy { $0 == 0 })
        #expect(packet.suffix(8).elementsEqual([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]))
    }

    @Test
    func legacyPingResponseParsesExtendedServerInformation() {
        let response = Data([
            0x01, 0x02, 0x03, 0x04,
            0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
            0x00, 0x00, 0x00, 0x2A,
            0x00, 0x00, 0x13, 0x88,
            0x00, 0x00, 0xFA, 0x00,
        ])

        let parsed = MumbleLegacyPingPacket.parseResponse(response)

        #expect(parsed?.timestamp == 0x11_12_13_14_15_16_17_18)
        #expect(parsed?.userCount == 42)
        #expect(parsed?.maximumUserCount == 5_000)
        #expect(parsed?.maximumBandwidthPerUser == 64_000)
    }

    @Test
    func legacyPingResponseParsesMinimalPingReply() {
        let response = Data([
            0x00, 0x00, 0x00, 0x00,
            0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11,
        ])

        let parsed = MumbleLegacyPingPacket.parseResponse(response)

        #expect(parsed?.timestamp == 0xAA_BB_CC_DD_EE_FF_00_11)
        #expect(parsed?.userCount == nil)
        #expect(parsed?.maximumUserCount == nil)
    }

    @Test
    func protobufPingRequestUsesPingHeaderAndExtendedInformationFlag() {
        let timestamp: UInt64 = 321

        let packet = MumbleProtobufPingPacket.makeExtendedPingRequest(timestamp: timestamp)

        #expect(packet == Data([0x01, 0x08, 0xC1, 0x02, 0x10, 0x01]))
    }

    @Test
    func protobufPingResponseParsesExtendedServerInformation() {
        let response = Data([
            0x01,
            0x08, 0x96, 0x01,
            0x18, 0x8A, 0xBF, 0xE6, 0xE9, 0x0F,
            0x20, 0x2A,
            0x28, 0xB8, 0x27,
            0x30, 0x80, 0xF4, 0x03,
        ])

        let parsed = MumbleProtobufPingPacket.parseResponse(response)

        #expect(parsed?.timestamp == 150)
        #expect(parsed?.userCount == 42)
        #expect(parsed?.maximumUserCount == 5_048)
        #expect(parsed?.maximumBandwidthPerUser == 64_000)
    }
}
