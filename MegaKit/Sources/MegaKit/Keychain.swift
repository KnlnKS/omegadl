import Foundation
import Security

public enum Keychain {
    public static let service = "com.omegadl.session"

    public static func save(_ session: AccountSession) throws {
        let data = try JSONEncoder().encode(session)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: session.email,
        ]

        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            let insert = query.merging(update) { _, new in new }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw MegaError.keychainUnavailable
            }
        } else if status != errSecSuccess {
            throw MegaError.keychainUnavailable
        }
    }

    public static func session(email: String) -> AccountSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
            kSecReturnData as String: true,
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }

        return try? JSONDecoder().decode(AccountSession.self, from: data)
    }

    public static func remove(email: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
        ] as CFDictionary)
    }
}
