import Foundation
import SwiftData
import Testing
@testable import Mumble

@MainActor
struct PersistenceModelTests {
    @Test
    func savedServerUsesHostAsFallbackName() {
        let server = SavedServer(name: " ", host: "voice.example.com")

        #expect(server.displayName == "voice.example.com")
        #expect(server.endpointDescription == "voice.example.com")
        #expect(server.folderDisplayName == "Servers")
    }

    @Test
    func savedServerUpdateNormalizesFolderAndPort() {
        let server = SavedServer(host: "voice.example.com")

        server.update(
            name: " Team Mumble ",
            folderName: "  Community  ",
            host: " mumble.example.com ",
            port: 70_000,
            username: " oskar ",
            note: " primary ",
            isFavorite: true
        )

        #expect(server.displayName == "Team Mumble")
        #expect(server.folderDisplayName == "Community")
        #expect(server.host == "mumble.example.com")
        #expect(server.port == 65_535)
        #expect(server.username == "oskar")
        #expect(server.note == "primary")
        #expect(server.isFavorite)
    }

    @Test
    func savedServerStatisticsNormalizeForDisplay() {
        let server = SavedServer(
            host: "voice.example.com",
            lastKnownPingMilliseconds: -8,
            lastKnownUserCount: 14,
            lastKnownMaximumUserCount: 10
        )

        #expect(server.lastKnownPingMilliseconds == 0)
        #expect(server.lastKnownUserCount == 14)
        #expect(server.lastKnownMaximumUserCount == 14)
        #expect(server.pingDisplayText == "0")
        #expect(server.usersDisplayText == "14/14")
    }

    @Test
    func trustedCertificateNormalizesFingerprint() {
        let certificate = TrustedCertificate(
            host: "voice.example.com",
            fingerprintSHA256: "AA:BB CC"
        )

        #expect(certificate.fingerprintSHA256 == "aabbcc")
        #expect(certificate.matches(host: "VOICE.EXAMPLE.COM", port: 64738, fingerprintSHA256: "aa:bb:cc"))
    }

    @Test
    func trustedCertificateStorePersistsAcceptedCertificates() async throws {
        let controller = try PersistenceController.makeInMemory()
        let store = TrustedCertificateStore(
            container: controller.container,
            logger: AppLogger(category: "tests.trusted-certificate-store")
        )

        #expect(try await store.isTrusted(host: "voice.example.com", port: 64738, fingerprintSHA256: "ab:cd") == false)

        try await store.trustCertificate(
            host: "voice.example.com",
            port: 64738,
            fingerprintSHA256: "ab:cd",
            commonName: "Voice Example",
            subjectSummary: "Voice Example"
        )

        #expect(try await store.isTrusted(host: "VOICE.EXAMPLE.COM", port: 64738, fingerprintSHA256: "AB CD"))

        let context = ModelContext(controller.container)
        let certificates = try context.fetch(FetchDescriptor<TrustedCertificate>())
        #expect(certificates.count == 1)
        #expect(certificates.first?.commonName == "Voice Example")
        #expect(certificates.first?.lastValidatedAt != nil)
    }

    @Test
    func audioPreferencesClampPersistedValues() {
        let preferences = AudioPreferences(
            inputVolume: -2.0,
            outputVolume: 3.5,
            voiceActivationThreshold: 1.5
        )

        #expect(preferences.inputVolume == 0.0)
        #expect(preferences.outputVolume == 2.0)
        #expect(preferences.voiceActivationThreshold == 1.0)
    }

    @Test
    func audioPreferencesNormalizePushToTalkHotkeys() {
        let preferences = AudioPreferences(
            localPushToTalkKey: "  AB ",
            shoutPushToTalkKey: " \n"
        )

        let parsedLocalHotkey = MumbleHotkey.parse(preferences.localPushToTalkKey)

        #expect(parsedLocalHotkey?.displayName == "A")
        #expect(preferences.shoutPushToTalkKey.isEmpty)
    }

    @Test
    func recentConnectionTracksDurationAfterDisconnect() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(42)
        let server = SavedServer(host: "voice.example.com", port: 64739)
        let connection = RecentConnection(server: server, connectedAt: start)

        connection.markDisconnected(at: end, wasSuccessful: true)

        #expect(connection.endpointDescription == "voice.example.com:64739")
        #expect(connection.duration == 42)
        #expect(connection.wasSuccessful)
    }

    @Test
    func persistenceBootstrapsDefaultAudioPreferencesOnce() throws {
        let controller = try PersistenceController.makeInMemory()
        let context = ModelContext(controller.container)

        try controller.ensureRequiredData(in: context)
        try controller.ensureRequiredData(in: context)

        let preferences = try context.fetch(FetchDescriptor<AudioPreferences>())
        #expect(preferences.count == 1)
        #expect(preferences.first?.profileName == "Default")
    }

    @Test
    func savedServerRoundTripsThroughSwiftData() throws {
        let controller = try PersistenceController.makeInMemory()
        let context = ModelContext(controller.container)
        let server = SavedServer(name: "Primary", folderName: "Community", host: "voice.example.com", username: "oskar")
        context.insert(server)
        try context.save()

        let fetchedServers = try context.fetch(FetchDescriptor<SavedServer>())

        #expect(fetchedServers.count == 1)
        #expect(fetchedServers.first?.displayName == "Primary")
        #expect(fetchedServers.first?.folderDisplayName == "Community")
        #expect(fetchedServers.first?.username == "oskar")
    }
}
