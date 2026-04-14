import Foundation
import Testing
@testable import Mumble

struct ServerPasswordStoreTests {
    @Test
    func serviceNameUsesBundleIdentifierWhenAvailable() {
        let serviceName = ServerPasswordStore.serviceName(bundleIdentifier: "com.example.Mumble")

        #expect(serviceName == "com.example.Mumble.server-password")
    }

    @Test
    func accountNameUsesStableServerIdentifier() {
        let serverID = UUID(uuidString: "B8657F1B-2CE4-477B-BB9B-C6F6B3078EA5")!

        #expect(ServerPasswordStore.accountName(for: serverID) == "b8657f1b-2ce4-477b-bb9b-c6f6b3078ea5")
    }
}
