import Foundation
import Security

struct Credentials: Codable, Sendable {
    var sessionToken = ""
    var accessToken = ""
    var refreshToken = ""
    var provider = ""
    var expiresAt: Double = 0
}
enum Keychain {
    static func load(service: String) -> Credentials {
        var query = base(service); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, let value = try? JSONDecoder().decode(Credentials.self, from: data) else { return Credentials() }
        return value
    }
    static func save(_ credentials: Credentials, service: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let query = base(service)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = data; insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw ClientError(message: "Keychain 保存失败：\(status)") }; return
        }
        guard update == errSecSuccess else { throw ClientError(message: "Keychain 保存失败：\(update)") }
    }
    private static func base(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.hermes.mac.credentials", kSecAttrAccount as String: service]
    }
}
