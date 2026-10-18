import Foundation

struct ModelPickerContext: Hashable {
    let service: String
    let profile: String
    let sessionID: String?
}

struct ModelChoice: Hashable, Identifiable {
    let provider: String
    let model: String
    var id: String { provider + ":" + model }
    // Hermes uses whitespace splitting, not shell parsing: quotes are literal.
    var switchValue: String { "\(model) --provider \(provider) --session" }
    var switchValueGlobal: String { "\(model) --provider \(provider)" }
}

extension ModelChoice {
    /// Parse a `GET /api/config` response (`{"fallback_providers": [{provider, model, ...}]}`) into an ordered chain.
    static func parseFallbackList(_ json: JSON) -> [ModelChoice] {
        let list = json["fallback_providers"].array.isEmpty ? json["fallbacks"].array : json["fallback_providers"].array
        return list.compactMap { entry in
            let provider = entry["provider"].string
            let model = entry["model"].string
            guard !provider.isEmpty, !model.isEmpty else { return nil }
            return ModelChoice(provider: provider, model: model)
        }
    }
}

struct ModelProvider: Identifiable {
    let id: String
    let name: String
    let choices: [ModelChoice]
    let unavailable: Set<String>
}

struct ModelCatalog {
    let providers: [ModelProvider]
    var model: String
    var provider: String
    init(_ json: JSON) throws {
        guard case .array = json["providers"] else {
            throw ClientError(message: "服务未返回模型列表，请检查 Hermes 版本")
        }
        model = json["model"].string; provider = json["provider"].string
        var seen: Set<String> = []
        providers = json["providers"].array.compactMap { row in
            let slug = row["slug"].string
            guard !slug.isEmpty, row["authenticated"] != .bool(false), seen.insert(slug).inserted else { return nil }
            var models: Set<String> = []
            let choices = row["models"].array.map(\.string).filter { !$0.isEmpty && models.insert($0).inserted }
                .map { ModelChoice(provider: slug, model: $0) }
            guard !choices.isEmpty else { return nil }
            return ModelProvider(id: slug, name: row["name"].string.isEmpty ? slug : row["name"].string,
                                 choices: choices, unavailable: Set(row["unavailable_models"].array.map(\.string)))
        }
    }
}

struct ModelSwitchConfirmation: Identifiable {
    let id = UUID()
    let key: ConversationKey
    let choice: ModelChoice
    let message: String
}
