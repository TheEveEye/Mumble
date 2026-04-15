import Foundation
import SwiftData

actor TrustedCertificateStore {
    private let container: ModelContainer
    private let logger: AppLogger

    init(container: ModelContainer, logger: AppLogger) {
        self.container = container
        self.logger = logger
    }

    func isTrusted(host: String, port: Int, fingerprintSHA256: String) throws -> Bool {
        let context = ModelContext(container)
        let certificates = try context.fetch(FetchDescriptor<TrustedCertificate>())

        guard let certificate = certificates.first(where: {
            $0.matches(host: host, port: port, fingerprintSHA256: fingerprintSHA256)
        }) else {
            return false
        }

        certificate.lastValidatedAt = .now
        try context.save()
        logger.info("Validated trusted certificate for \(certificate.endpointDescription)")
        return true
    }

    func trustCertificate(
        host: String,
        port: Int,
        fingerprintSHA256: String,
        commonName: String,
        subjectSummary: String
    ) throws {
        let context = ModelContext(container)
        let certificates = try context.fetch(FetchDescriptor<TrustedCertificate>())

        if let existingCertificate = certificates.first(where: {
            $0.matches(host: host, port: port, fingerprintSHA256: fingerprintSHA256)
        }) {
            existingCertificate.commonName = commonName.trimmingCharacters(in: .whitespacesAndNewlines)
            existingCertificate.subjectSummary = subjectSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            existingCertificate.lastValidatedAt = .now
        } else {
            context.insert(
                TrustedCertificate(
                    host: host,
                    port: port,
                    fingerprintSHA256: fingerprintSHA256,
                    commonName: commonName,
                    subjectSummary: subjectSummary,
                    firstTrustedAt: .now,
                    lastValidatedAt: .now
                )
            )
        }

        try context.save()
        logger.info("Stored trusted certificate for \(host):\(port)")
    }
}
