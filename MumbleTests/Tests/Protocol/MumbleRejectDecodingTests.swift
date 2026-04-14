import Foundation
import Testing
@testable import Mumble

struct MumbleRejectDecodingTests {
    @Test
    func rejectDecoderParsesWrongServerPasswordTypeAndReason() {
        var payload = Data()
        MumbleProtobufWire.appendVarintField(1, value: MumbleRejectType.wrongServerPassword.rawValue, to: &payload)
        MumbleProtobufWire.appendStringField(2, value: "Wrong password", to: &payload)

        let decoded = MumbleSessionMessageDecoder.decodeReject(from: payload)

        #expect(decoded?.type == .wrongServerPassword)
        #expect(decoded?.reason == "Wrong password")
    }
}
