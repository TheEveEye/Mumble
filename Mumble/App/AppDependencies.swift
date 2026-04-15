import Foundation

struct AppDependencies {
    let persistence: PersistenceController
    let logger: AppLogger
    let serverPasswordStore: ServerPasswordStore
    let trustedCertificateStore: TrustedCertificateStore
    let serverStatus: MumbleServerStatusService
    let channelList: MumbleChannelListService

    static func live() -> AppDependencies {
        let logger = AppLogger(category: "app")
        let serverPasswordStore = ServerPasswordStore()
        let serverStatus = MumbleServerStatusService(logger: AppLogger(category: "protocol.server-status"))

        do {
            let persistence = try PersistenceController(logger: logger)
            let trustedCertificateStore = TrustedCertificateStore(
                container: persistence.container,
                logger: AppLogger(category: "security.trusted-certificate-store")
            )
            let channelList = MumbleChannelListService(
                logger: AppLogger(category: "protocol.channel-list"),
                trustedCertificateStore: trustedCertificateStore
            )
            return AppDependencies(
                persistence: persistence,
                logger: logger,
                serverPasswordStore: serverPasswordStore,
                trustedCertificateStore: trustedCertificateStore,
                serverStatus: serverStatus,
                channelList: channelList
            )
        } catch {
            logger.error("Failed to initialize persistent dependencies: \(error.localizedDescription)")

            do {
                let persistence = try PersistenceController(inMemory: true, logger: logger)
                let trustedCertificateStore = TrustedCertificateStore(
                    container: persistence.container,
                    logger: AppLogger(category: "security.trusted-certificate-store")
                )
                let channelList = MumbleChannelListService(
                    logger: AppLogger(category: "protocol.channel-list"),
                    trustedCertificateStore: trustedCertificateStore
                )
                logger.error("Falling back to an in-memory store for this launch")
                return AppDependencies(
                    persistence: persistence,
                    logger: logger,
                    serverPasswordStore: serverPasswordStore,
                    trustedCertificateStore: trustedCertificateStore,
                    serverStatus: serverStatus,
                    channelList: channelList
                )
            } catch {
                fatalError("Failed to initialize app dependencies: \(error)")
            }
        }
    }
}
