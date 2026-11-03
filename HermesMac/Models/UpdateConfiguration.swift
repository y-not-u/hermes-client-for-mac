import Foundation

struct UpdateConfiguration {
    let version: String
    let build: String
    let supportsUpdates: Bool

    init(bundleIdentifier: String?, info: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? "开发版"
        build = info["CFBundleVersion"] as? String ?? ""
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        let key = (info["SUPublicEDKey"] as? String).flatMap { Data(base64Encoded: $0) }
        supportsUpdates = bundleIdentifier == "com.hermes.mac"
            && feed?.scheme == "https" && feed?.host != nil
            && key?.count == 32 && !build.isEmpty
    }

    var displayVersion: String { build.isEmpty ? version : "\(version) (\(build))" }
}
