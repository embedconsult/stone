import Foundation
import Security

/// Stores per-repository sync passwords in the iOS Keychain.
///
/// Single responsibility: keep secrets out of the repo metadata and out of
/// memory longer than needed. Keyed by the repository's UUID.
enum CredentialStore {
    private static let service = "com.stone.fossil.sync"

    /// - Returns: whether the write actually succeeded. Previously this
    ///   discarded `SecItemAdd`'s status entirely -- a failed write (e.g. no
    ///   valid code signature/keychain-access-group, which is exactly the
    ///   case for an unsigned CI/test build) looked identical to success,
    ///   silently leaving `password(for:)` returning nil forever after.
    ///   Callers that don't need to react to failure can ignore the result.
    @discardableResult
    static func setPassword(_ password: String, for repoID: UUID) -> Bool {
        let account = repoID.uuidString
        delete(for: repoID)
        guard let data = password.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
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
