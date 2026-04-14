import Foundation
import SwiftData

@Model
final class TrustedCertificate {
    @Attribute(.unique) var id: UUID
    var host: String
    var port: Int
    var fingerprintSHA256: String
    var commonName: String
    var subjectSummary: String
    var firstTrustedAt: Date
    var lastValidatedAt: Date?

    init(
        id: UUID = UUID(),
        host: String,
        port: Int = 64738,
        fingerprintSHA256: String,
        commonName: String = "",
        subjectSummary: String = "",
        firstTrustedAt: Date = .now,
        lastValidatedAt: Date? = nil
    ) {
        self.id = id
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = max(1, min(port, 65_535))
        self.fingerprintSHA256 = Self.normalizeFingerprint(fingerprintSHA256)
        self.commonName = commonName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subjectSummary = subjectSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.firstTrustedAt = firstTrustedAt
        self.lastValidatedAt = lastValidatedAt
    }

    var endpointDescription: String {
        port == 64738 ? host : "\(host):\(port)"
    }

    func matches(host: String, port: Int, fingerprintSHA256: String) -> Bool {
        self.host.caseInsensitiveCompare(host) == .orderedSame &&
        self.port == port &&
        self.fingerprintSHA256 == Self.normalizeFingerprint(fingerprintSHA256)
    }

    static func normalizeFingerprint(_ fingerprint: String) -> String {
        fingerprint
            .lowercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
