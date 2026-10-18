import Foundation
import Observation
struct ServiceState: Codable, Equatable {
    var profileOrder: [String] = []
    var selectedProfile = ""
    var lastSession: [String: String] = [:]
    var drafts: [String: String] = [:]
    // Optional so metadata written before pinning was introduced still decodes.
    var pinnedSessions: [String: [SessionSummary]]?
}
@MainActor @Observable final class LocalState {
    private let defaults: UserDefaults
    private var services: [String: ServiceState] = [:]
    private static let storagePrefix = "serviceState.v2."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Migrate the old aggregate once, preserving every service and draft.
        if let data = defaults.data(forKey: "serviceState"),
           let legacy = try? JSONDecoder().decode([String: ServiceState].self, from: data) {
            for (service, value) in legacy {
                update(service) { $0 = value }
            }
            defaults.removeObject(forKey: "serviceState")
        }
    }

    private static func storageKey(_ service: String) -> String {
        storagePrefix + Data(service.utf8).base64EncodedString() + "."
    }

    var address: String {
        get { defaults.string(forKey: "serviceAddress") ?? "http://127.0.0.1:9119" }
        set { defaults.set(newValue, forKey: "serviceAddress") }
    }
    func state(_ service: String) -> ServiceState {
        if let cached = services[service] { return cached }
        let prefix = Self.storageKey(service)
        var value = defaults.data(forKey: prefix + "metadata")
            .flatMap { try? JSONDecoder().decode(ServiceState.self, from: $0) } ?? ServiceState()
        let draftPrefix = prefix + "draft."
        for (key, text) in defaults.dictionaryRepresentation() where key.hasPrefix(draftPrefix) {
            guard let text = text as? String,
                  let data = Data(base64Encoded: String(key.dropFirst(draftPrefix.count))),
                  let draftKey = String(data: data, encoding: .utf8) else { continue }
            value.drafts[draftKey] = text
        }
        services[service] = value
        return value
    }

    /// Hot path for keystrokes: avoid copying/diffing every draft in the service.
    func setDraft(_ text: String, for key: String, service: String) {
        guard state(service).drafts[key] != text else { return }
        services[service]?.drafts[key] = text
        defaults.set(text, forKey: Self.storageKey(service) + "draft." + Data(key.utf8).base64EncodedString())
    }

    func update(_ service: String, _ change: (inout ServiceState) -> Void) {
        let old = state(service)
        var value = old
        change(&value)
        guard value != old else { return }
        services[service] = value
        let prefix = Self.storageKey(service)
        var metadata = value; metadata.drafts = [:]
        var oldMetadata = old; oldMetadata.drafts = [:]
        if metadata != oldMetadata, let data = try? JSONEncoder().encode(metadata) {
            defaults.set(data, forKey: prefix + "metadata")
        }
        // Typing writes only the changed draft string, without encoding other drafts.
        for key in Set(old.drafts.keys).union(value.drafts.keys) where old.drafts[key] != value.drafts[key] {
            let storageKey = prefix + "draft." + Data(key.utf8).base64EncodedString()
            if let text = value.drafts[key] { defaults.set(text, forKey: storageKey) }
            else { defaults.removeObject(forKey: storageKey) }
        }
    }
    static func draftKey(profile: String, session: String?) -> String { profile + "\u{001f}" + (session ?? "new") }
}

/// Shared, durable typography preference for session lists, conversation content, and composing.
enum ChatTypography {
    static let key = "chatFontSize"
    static let defaultSize = 13.5
    static let range = 11.0...24.0

    static func size(_ value: Double) -> CGFloat {
        CGFloat(value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : defaultSize)
    }

    static func scaled(_ base: CGFloat, for value: Double) -> CGFloat {
        base * size(value) / CGFloat(defaultSize)
    }
}
