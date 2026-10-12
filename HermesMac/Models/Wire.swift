import Foundation

// Open JSON values deliberately tolerate new event fields without losing known data.
enum JSON: Codable, Equatable, Sendable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSON].self) { self = .object(v) }
        else { self = .array(try c.decode([JSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> JSON { if case .object(let o) = self { return o[key] ?? .null }; return .null }
    var string: String { if case .string(let v) = self { return v }; return "" }
    var array: [JSON] { if case .array(let v) = self { return v }; return [] }
    var bool: Bool { if case .bool(let v) = self { return v }; return false }
    var number: Double { if case .number(let v) = self { return v }; return 0 }
    var pretty: String { guard let data = try? JSONEncoder.pretty.encode(self) else { return "" }; return String(decoding: data, as: UTF8.self) }
}
extension JSONEncoder {
    static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
struct Profile: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let displayName: String
    let description: String
    init(_ json: JSON) { name = json["name"].string; displayName = json["display_name"].string.isEmpty ? name : json["display_name"].string; description = json["description"].string }
}
struct SessionSummary: Identifiable, Equatable {
    let id: String
    var title: String
    let preview: String
    init(_ json: JSON) { id = json["id"].string; title = json["title"].string.isEmpty ? "未命名会话" : json["title"].string; preview = json["preview"].string }
    init(id: String, title: String) { self.id = id; self.title = title; preview = "" }
}
struct Message: Identifiable, Equatable {
    let id: String
    let role: String
    var text: String
    var deliveryStatus: String?
    init(id: String = UUID().uuidString, role: String, text: String) { self.id = id; self.role = role; self.text = text }
    init(_ json: JSON) {
        let row = json["_row_id"] == .null ? json["id"] : json["_row_id"]
        id = row.string.isEmpty ? (row == .null ? UUID().uuidString : "row-" + String(row.number)) : row.string
        role = json["role"].string
        let content = json["display_content"] == .null ? json["content"] : json["display_content"]
        text = content.string.isEmpty ? (content.array.isEmpty ? json["text"].string : content.array.map { $0["text"].string }.joined()) : content.string
    }
    static func visibleHistory(_ rows: [JSON]) -> [Message] {
        rows.filter {
            $0["display_kind"].string != "hidden" && ($0["role"].string == "user" || $0["role"].string == "assistant")
        }
            .map(Message.init)
            .filter { !$0.text.isEmpty }
    }
}
struct ToolCall: Identifiable { let id: String; let name: String; var details: String; var complete = false }
struct ToolActivity: Identifiable {
    let id: String
    var afterMessageID: String?
    var tools: [ToolCall]
}
enum ConversationEntry: Identifiable {
    case message(Message)
    case tools(ToolActivity)

    var id: String {
        switch self {
        case .message(let message): return "message-" + message.id
        case .tools(let activity): return "tools-" + activity.id
        }
    }
}
struct Approval: Identifiable { let id: String; let params: JSON }
struct ConversationKey: Hashable, Codable, Sendable { let service: String; let profile: String; let storedID: String }
struct ClientError: LocalizedError { let message: String; var retryable = false; var httpStatus: Int? = nil; var rpcCode: Int? = nil; var errorDescription: String? { message } }
