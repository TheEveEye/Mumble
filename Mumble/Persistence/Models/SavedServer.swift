import Foundation
import SwiftData

@Model
final class SavedServer {
    @Attribute(.unique) var id: UUID
    var name: String
    var folderName: String
    var host: String
    var port: Int
    var username: String
    var note: String
    var isFavorite: Bool
    var lastKnownPingMilliseconds: Int?
    var lastKnownUserCount: Int?
    var lastKnownMaximumUserCount: Int?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \RecentConnection.server)
    var recentConnections: [RecentConnection]

    init(
        id: UUID = UUID(),
        name: String = "",
        folderName: String = "",
        host: String,
        port: Int = 64738,
        username: String = "",
        note: String = "",
        isFavorite: Bool = false,
        lastKnownPingMilliseconds: Int? = nil,
        lastKnownUserCount: Int? = nil,
        lastKnownMaximumUserCount: Int? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.folderName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = max(1, min(port, 65_535))
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isFavorite = isFavorite
        self.lastKnownPingMilliseconds = Self.normalizedPing(lastKnownPingMilliseconds)
        self.lastKnownUserCount = Self.normalizedUserCount(lastKnownUserCount)
        self.lastKnownMaximumUserCount = Self.normalizedMaximumUserCount(
            lastKnownMaximumUserCount,
            userCount: lastKnownUserCount
        )
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        recentConnections = []
    }

    var displayName: String {
        name.isEmpty ? host : name
    }

    var endpointDescription: String {
        port == 64738 ? host : "\(host):\(port)"
    }

    var folderDisplayName: String {
        folderName.isEmpty ? "Servers" : folderName
    }

    var pingDisplayText: String {
        guard let lastKnownPingMilliseconds else {
            return "--"
        }

        return String(lastKnownPingMilliseconds)
    }

    var usersDisplayText: String {
        guard let lastKnownUserCount else {
            return "--"
        }

        if let lastKnownMaximumUserCount {
            return "\(lastKnownUserCount)/\(lastKnownMaximumUserCount)"
        }

        return String(lastKnownUserCount)
    }

    func update(
        name: String,
        folderName: String,
        host: String,
        port: Int,
        username: String,
        note: String,
        isFavorite: Bool
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.folderName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = max(1, min(port, 65_535))
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isFavorite = isFavorite
        updatedAt = .now
    }

    func updateServerStatistics(
        pingMilliseconds: Int?,
        userCount: Int?,
        maximumUserCount: Int?
    ) {
        lastKnownPingMilliseconds = Self.normalizedPing(pingMilliseconds)
        lastKnownUserCount = Self.normalizedUserCount(userCount)
        lastKnownMaximumUserCount = Self.normalizedMaximumUserCount(
            maximumUserCount,
            userCount: userCount
        )
    }

    private static func normalizedPing(_ pingMilliseconds: Int?) -> Int? {
        guard let pingMilliseconds else {
            return nil
        }

        return max(0, pingMilliseconds)
    }

    private static func normalizedUserCount(_ userCount: Int?) -> Int? {
        guard let userCount else {
            return nil
        }

        return max(0, userCount)
    }

    private static func normalizedMaximumUserCount(_ maximumUserCount: Int?, userCount: Int?) -> Int? {
        guard let maximumUserCount else {
            return nil
        }

        let normalizedMaximum = max(0, maximumUserCount)

        if let userCount {
            return max(normalizedMaximum, max(0, userCount))
        }

        return normalizedMaximum
    }
}
