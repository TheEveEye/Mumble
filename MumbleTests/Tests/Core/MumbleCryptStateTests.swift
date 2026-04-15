import Foundation
import Testing
@testable import Mumble

struct MumbleCryptStateTests {
    @Test
    func cryptStateRoundTripsEncryptedPacket() {
        let key = Data(0..<16)
        let clientNonce = Data(repeating: 0x55, count: 16)
        let serverNonce = Data(repeating: 0xAA, count: 16)
        let plaintext = Data("voice-packet".utf8)

        var encryptor = MumbleCryptState()
        var decryptor = MumbleCryptState()

        let encryptorConfigured = encryptor.setKey(key: key, clientNonce: clientNonce, serverNonce: serverNonce)
        let decryptorConfigured = decryptor.setKey(key: key, clientNonce: serverNonce, serverNonce: clientNonce)

        #expect(encryptorConfigured)
        #expect(decryptorConfigured)

        let encryptedPacket = encryptor.encrypt(plaintext)
        let decryptedPacket = encryptedPacket.flatMap { decryptor.decrypt($0) }

        #expect(decryptedPacket == plaintext)
    }

    @Test
    func cryptStateRejectsReplayPackets() {
        let key = Data(0..<16)
        let clientNonce = Data(repeating: 0x10, count: 16)
        let serverNonce = Data(repeating: 0x20, count: 16)
        let plaintext = Data("voice-packet".utf8)

        var encryptor = MumbleCryptState()
        var decryptor = MumbleCryptState()

        let encryptorConfigured = encryptor.setKey(key: key, clientNonce: clientNonce, serverNonce: serverNonce)
        let decryptorConfigured = decryptor.setKey(key: key, clientNonce: serverNonce, serverNonce: clientNonce)

        #expect(encryptorConfigured)
        #expect(decryptorConfigured)

        guard let encryptedPacket = encryptor.encrypt(plaintext) else {
            Issue.record("Expected encrypted packet")
            return
        }

        #expect(decryptor.decrypt(encryptedPacket) == plaintext)
        #expect(decryptor.decrypt(encryptedPacket) == nil)
    }
}
