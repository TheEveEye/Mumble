import Foundation
import SwiftData

@Model
final class RecentConnection {
    @Attribute(.unique) var id: UUID
    var connectedAt: Date
    var disconnectedAt: Date?
    var wasSuccessful: Bool
    var statusMessage: String
    var serverNameSnapshot: String
    var host: String
    var port: Int
    var username: String
    var certificateFingerprintSHA256: String?
    var server: SavedServer?

    init(
        id: UUID = UUID(),
        server: SavedServer? = nil,
        connectedAt: Date = .now,
        disconnectedAt: Date? = nil,
        wasSuccessful: Bool = false,
        statusMessage: String = "",
        certificateFingerprintSHA256: String? = nil
    ) {
        self.id = id
        self.connectedAt = connectedAt
        self.disconnectedAt = disconnectedAt
        self.wasSuccessful = wasSuccessful
        self.statusMessage = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serverNameSnapshot = server?.displayName ?? ""
        self.host = server?.host ?? ""
        self.port = server?.port ?? 64738
        self.username = server?.username ?? ""
        self.certificateFingerprintSHA256 = certificateFingerprintSHA256?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.server = server
    }

    var duration: TimeInterval? {
        guard let disconnectedAt else {
            return nil
        }

        return disconnectedAt.timeIntervalSince(connectedAt)
    }

    var endpointDescription: String {
        port == 64738 ? host : "\(host):\(port)"
    }

    func markDisconnected(
        at date: Date = .now,
        wasSuccessful: Bool,
        statusMessage: String = ""
    ) {
        disconnectedAt = date
        self.wasSuccessful = wasSuccessful
        self.statusMessage = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
