import Foundation
import Security

/// The signed-in account's session, kept as the service's only Keychain item.
public struct Keychain: Sendable {
    public static let standard = Keychain(service: "com.omegadl.session")

    let service: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    public func save(_ session: AccountSession) throws {
        let update: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(session),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(update) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MegaError.keychainUnavailable }
    }

    @concurrent
    public func session() async -> AccountSession? {
        var result: CFTypeRef?
        guard SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(AccountSession.self, from: data)
    }

    public func remove() {
        SecItemDelete(query as CFDictionary)
    }
}
