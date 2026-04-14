import Foundation
import SwiftData

@MainActor
final class PersistenceController {
    let container: ModelContainer

    private let logger: AppLogger
    private let schema: Schema

    init(inMemory: Bool = false, logger: AppLogger) throws {
        self.logger = logger
        schema = Schema([
            SavedServer.self,
            RecentConnection.self,
            TrustedCertificate.self,
            AudioPreferences.self,
        ])

        if inMemory {
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
            container = try ModelContainer(for: schema, configurations: [configuration])
            logger.info("Persistence controller initialized in memory")
            return
        }

        let storeURL = try Self.makeStoreURL()

        do {
            container = try Self.makePersistentContainer(schema: schema, storeURL: storeURL)
        } catch {
            logger.error("Failed to load persistent store at \(storeURL.path): \(error.localizedDescription)")
            try Self.removeStoreArtifacts(at: storeURL)
            container = try Self.makePersistentContainer(schema: schema, storeURL: storeURL)
            logger.info("Recreated persistent store after load failure")
        }

        logger.info("Persistence controller initialized")
    }

    func ensureRequiredData(in context: ModelContext) throws {
        let descriptor = FetchDescriptor<AudioPreferences>()
        let existingPreferences = try context.fetch(descriptor)

        guard existingPreferences.isEmpty else {
            return
        }

        context.insert(AudioPreferences.defaultProfile())
        try context.save()
        logger.info("Inserted default audio preferences")
    }

    static func makeInMemory(logger: AppLogger = AppLogger(category: "tests")) throws -> PersistenceController {
        try PersistenceController(inMemory: true, logger: logger)
    }

    private static func makePersistentContainer(schema: Schema, storeURL: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL
        )

        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func makeStoreURL() throws -> URL {
        let fileManager = FileManager.default
        let applicationSupportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.kiwiapps.Mumble"
        let storeDirectory = applicationSupportDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true)

        try fileManager.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )

        return storeDirectory.appendingPathComponent("Mumble.store")
    }

    private static func removeStoreArtifacts(at storeURL: URL) throws {
        let fileManager = FileManager.default
        let paths = [
            storeURL.path,
            "\(storeURL.path)-shm",
            "\(storeURL.path)-wal",
            "\(storeURL.path)-journal",
        ]

        for path in paths where fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
    }
}
