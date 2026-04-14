import Foundation
import OSLog

struct AppLogger: Sendable {
    private let logger: Logger

    nonisolated init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "dev.kiwiapps.Mumble",
        category: String
    ) {
        logger = Logger(subsystem: subsystem, category: category)
    }

    nonisolated func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    nonisolated func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    nonisolated func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
