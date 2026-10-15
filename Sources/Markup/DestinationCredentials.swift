import Foundation
import Security

/// Each connection has its own revocable secret. Nothing is stored in defaults,
/// feedback bundles, logs, or the destination's Codable representation.
final class DestinationCredentials {
    private let service = "app.markup.destination-credentials"

    func save(_ token: String, for id: UUID) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isNewline }) else {
            throw CloudDeliveryError(message: "Enter a valid API key or token.")
        }
        let data = Data(value.utf8)
        let query = query(for: id)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrLabel] = "Markup destination"
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func token(for id: UUID) throws -> String {
        var query = query(for: id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw CloudDeliveryError(message: "This destination needs to be reconnected in Settings.")
        }
        try check(status)
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw CloudDeliveryError(message: "The saved credential could not be read. Reconnect this destination in Settings.")
        }
        return token
    }

    func remove(for id: UUID) throws {
        let status = SecItemDelete(query(for: id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func query(for id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: service,
         kSecAttrAccount: id.uuidString,
         kSecAttrSynchronizable: false]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw CloudDeliveryError(message: "Keychain could not save or access this connection (\(status)). Unlock your Mac and try again.")
        }
    }
}
