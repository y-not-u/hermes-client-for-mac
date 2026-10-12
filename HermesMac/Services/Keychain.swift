import Foundation
import Security

struct Credentials: Codable, Sendable {
    var sessionToken = ""
    var accessToken = ""
    var refreshToken = ""
    var provider = ""
    var expiresAt: Double = 0
}
struct KeychainError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct CredentialRequest: Codable {
    let operation: String
    let service: String
    var credentials: Credentials? = nil
}
struct CredentialResponse: Codable {
    var credentials: Credentials? = nil
    var error: String? = nil
}
enum Keychain {
    static func load(service: String) throws -> Credentials {
        #if !KEYCHAIN_HELPER
        if let response = try helper(CredentialRequest(operation: "load", service: service)) {
            guard let credentials = response.credentials else { throw KeychainError(message: "凭据组件未返回登录信息") }
            return credentials
        }
        #endif
        var query = base(service); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return try decode(status: status, data: result as? Data)
    }
    static func decode(status: OSStatus, data: Data?) throws -> Credentials {
        if status == errSecItemNotFound { return Credentials() }
        guard status == errSecSuccess else {
            throw KeychainError(message: "无法读取 Keychain 登录凭据（\(status)）。请解锁钥匙串并允许 HermesMac 凭据组件访问，然后重新连接；已保存的凭据未被删除。")
        }
        guard let data, let value = try? JSONDecoder().decode(Credentials.self, from: data) else {
            throw KeychainError(message: "Keychain 登录凭据格式无效，无法恢复；请重新登录。")
        }
        return value
    }
    static func save(_ credentials: Credentials, service: String) throws {
        #if !KEYCHAIN_HELPER
        if try helper(CredentialRequest(operation: "save", service: service, credentials: credentials)) != nil { return }
        #endif
        let data = try JSONEncoder().encode(credentials)
        let query = base(service)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = data; insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(message: "Keychain 保存失败：\(status)") }; return
        }
        guard update == errSecSuccess else { throw KeychainError(message: "Keychain 保存失败：\(update)") }
    }
    #if !KEYCHAIN_HELPER
    private static func helper(_ request: CredentialRequest) throws -> CredentialResponse? {
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "HermesCredentialHelper") else {
            // SwiftPM unit tests inject credentials and can use their own test items.
            if Bundle.main.bundleIdentifier == "com.hermes.mac" {
                throw KeychainError(message: "应用缺少凭据组件，请通过构建脚本重新构建。")
            }
            return nil
        }
        let process = Process()
        process.executableURL = executable
        let input = Pipe(); let output = Pipe()
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(try JSONEncoder().encode(request))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let response = try? JSONDecoder().decode(CredentialResponse.self, from: data) else {
            throw KeychainError(message: "凭据组件未能完成请求，登录信息仍保存在 Keychain 中。")
        }
        if let error = response.error { throw KeychainError(message: error) }
        guard process.terminationStatus == 0 else { throw KeychainError(message: "凭据组件退出异常") }
        return response
    }
    #endif
    private static func base(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.hermes.mac.credentials", kSecAttrAccount as String: service]
    }
}
