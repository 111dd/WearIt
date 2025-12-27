
import Foundation
import Security

struct KeychainService {
    let service: String
    let account: String

    func save(_ value: String) throws {
        try delete() // מחיקה לפני שמירה כדי למנוע כפילויות

        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "KeychainService", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "SecItemAdd failed: \(status)"])
        }
    }

    func read() throws -> String {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "KeychainService", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "SecItemCopyMatching failed: \(status)"])
        }
        return value
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: "KeychainService", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "SecItemDelete failed: \(status)"])
        }
    }
}
