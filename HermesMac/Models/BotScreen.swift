import Foundation
import CryptoKit

struct BotScreenKey: Hashable {
    let service: String
    let profile: String
}

struct BotScreenLease: Equatable {
    let holder: String
    let viewerHash: String
    let since: Double
    let reason: String
    let epoch: Double
    init(_ json: JSON) {
        holder = json["holder"].string; viewerHash = json["viewer_hash"].string
        since = json["since"].number; reason = json["reason"].string; epoch = json["epoch"].number
    }
    func heldBy(_ viewerID: String) -> Bool {
        guard holder == "human", !viewerID.isEmpty else { return false }
        let hash = SHA256.hash(data: Data(viewerID.utf8)).map { String(format: "%02x", $0) }.joined()
        return viewerHash == String(hash.prefix(12))
    }
}

struct BotScreenStatus: Equatable {
    let profileKey: String
    let supported: Bool
    let installed: Bool
    let running: Bool
    let missing: [String]
    let blocker: String?
    let installCommand: String?
    let geometry: String
    let placement: String
    var lease: BotScreenLease
    init(_ json: JSON) {
        profileKey = json["profile_key"].string
        supported = json["supported"].bool; installed = json["installed"].bool; running = json["running"].bool
        missing = json["missing"].array.map(\.string)
        blocker = json["blocker"].string.isEmpty ? nil : json["blocker"].string
        installCommand = json["install_command"].string.isEmpty ? nil : json["install_command"].string
        geometry = json["geometry"].string; placement = json["placement"].string
        lease = BotScreenLease(json["lease"])
    }
}

struct BotScreenViewerConnection: Equatable {
    let id: UUID
    let websocketURL: URL

    // The gateway supplied path is constrained to its known endpoint and keeps a reverse-proxy prefix.
    static func make(baseURL: URL, observe: JSON) throws -> Self {
        let ticket = observe["ticket"].string
        guard !ticket.isEmpty, !observe["viewer_id"].string.isEmpty,
              observe["path"].string == "/api/display/ws",
              var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme), parts.host != nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw ClientError(message: "服务返回了无效桌面票据或地址")
        }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = (parts.path.isEmpty ? "" : "/" + parts.path) + "/api/display/ws"
        parts.queryItems = [URLQueryItem(name: "display_ticket", value: ticket)]
        guard let url = parts.url else { throw ClientError(message: "无效桌面地址") }
        return Self(id: UUID(), websocketURL: url)
    }
}
