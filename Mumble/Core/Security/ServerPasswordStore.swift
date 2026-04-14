import Foundation
import Security

enum ServerPasswordStoreError: LocalizedError {
    case unexpectedPasswordData
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedPasswordData:
            return "The saved server password could not be decoded from the Keychain."
        case .keychainFailure(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

struct ServerPasswordStore: Sendable {
    private let serviceName: String

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.serviceName = Self.serviceName(bundleIdentifier: bundleIdentifier)
    }

    func password(for serverID: UUID) throws -> String? {
        let query = baseQuery(for: serverID).merging(
            [
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ],
            uniquingKeysWith: { _, new in new }
        )

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard
                let data = result as? Data,
                let password = String(data: data, encoding: .utf8)
            else {
                throw ServerPasswordStoreError.unexpectedPasswordData
            }

            return password
        case errSecItemNotFound:
            return nil
        default:
            throw ServerPasswordStoreError.keychainFailure(status)
        }
    }

    func savePassword(_ password: String, for serverID: UUID) throws {
        let query = baseQuery(for: serverID)
        let encodedPassword = Data(password.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: encodedPassword,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var creationQuery = query
            creationQuery[kSecValueData as String] = encodedPassword

            let creationStatus = SecItemAdd(creationQuery as CFDictionary, nil)

            guard creationStatus == errSecSuccess else {
                throw ServerPasswordStoreError.keychainFailure(creationStatus)
            }
        default:
            throw ServerPasswordStoreError.keychainFailure(updateStatus)
        }
    }

    func removePassword(for serverID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: serverID) as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ServerPasswordStoreError.keychainFailure(status)
        }
    }

    static func serviceName(bundleIdentifier: String?) -> String {
        let prefix = bundleIdentifier ?? "Mumble"
        return "\(prefix).server-password"
    }

    static func accountName(for serverID: UUID) -> String {
        serverID.uuidString.lowercased()
    }

    private func baseQuery(for serverID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: Self.accountName(for: serverID),
        ]
    }
}
