import Foundation
import Security

/// Stores `Credentials` as one JSON blob in the Keychain.
struct TokenStore {
    var service = "com.AnomalousResearch.EightSleepWatch.credentials"
    var account = "eight-sleep"
    var accessGroup: String? = nil

    private var baseQuery: [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    func load() -> Credentials? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    @discardableResult
    func save(_ credentials: Credentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            let add = baseQuery.merging(attrs) { $1 }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
