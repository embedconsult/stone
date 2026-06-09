import Foundation
import Security

/// Stores per-repository sync passwords in the iOS Keychain.
///
/// Single responsibility: keep secrets out of the repo metadata and out of
/// memory longer than needed. Keyed by the repository's UUID.
enum CredentialStore {
    private static let service = "com.stone.fossil.sync"

    static func setPassword(_ password: String, for repoID: UUID) {
        let account = repoID.uuidString
        delete(for: repoID)
        guard let data = password.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func password(for repoID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: repoID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for repoID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: repoID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
