import Foundation
import Security
import CryptoKit

// UI builds change the app's cdhash. This small executable stays unchanged and
// holds the Keychain partition; it accepts requests only from our signed app.
func authorizedParent() -> Bool {
    var own: SecCode?
    guard SecCodeCopySelf([], &own) == errSecSuccess, let own else { return false }
    var ownStatic: SecStaticCode?
    guard SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic else { return false }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(ownStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certificates.first else { return false }
    let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
    var requirement: SecRequirement?
    let rule = "identifier \"com.hermes.mac\" and certificate leaf = H\"\(fingerprint)\""
    guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess else { return false }
    var parent: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: getppid())]
    guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &parent) == errSecSuccess, let parent else { return false }
    return SecCodeCheckValidity(parent, [], requirement) == errSecSuccess
}

func respond(_ response: CredentialResponse) {
    if let data = try? JSONEncoder().encode(response) { FileHandle.standardOutput.write(data) }
}

guard authorizedParent() else {
    respond(CredentialResponse(error: "凭据组件拒绝了未授权的调用"))
    exit(1)
}
let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.count <= 65536, let request = try? JSONDecoder().decode(CredentialRequest.self, from: input) else {
    respond(CredentialResponse(error: "无效的凭据请求"))
    exit(1)
}
do {
    switch request.operation {
    case "load": respond(CredentialResponse(credentials: try Keychain.load(service: request.service)))
    case "save":
        guard let credentials = request.credentials else { throw KeychainError(message: "缺少待保存的凭据") }
        try Keychain.save(credentials, service: request.service)
        respond(CredentialResponse())
    default: throw KeychainError(message: "不支持的凭据操作")
    }
} catch {
    respond(CredentialResponse(error: error.localizedDescription))
    exit(1)
}
