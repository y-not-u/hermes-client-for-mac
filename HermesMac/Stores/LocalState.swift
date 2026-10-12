import Foundation
struct ServiceState: Codable {
    var profileOrder: [String] = []
    var selectedProfile = ""
    var lastSession: [String: String] = [:]
    var drafts: [String: String] = [:]
}
@MainActor final class LocalState {
    private let defaults: UserDefaults
    private var services: [String: ServiceState]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        services = (defaults.data(forKey: "serviceState").flatMap { try? JSONDecoder().decode([String: ServiceState].self, from: $0) }) ?? [:]
    }
    var address: String {
        get { defaults.string(forKey: "serviceAddress") ?? "http://127.0.0.1:9119" }
        set { defaults.set(newValue, forKey: "serviceAddress") }
    }
    func state(_ service: String) -> ServiceState { services[service] ?? ServiceState() }
    func update(_ service: String, _ change: (inout ServiceState) -> Void) {
        var value = state(service); change(&value); services[service] = value
        if let data = try? JSONEncoder().encode(services) { defaults.set(data, forKey: "serviceState") }
    }
    static func draftKey(profile: String, session: String?) -> String { profile + "\u{001f}" + (session ?? "new") }
}

/// Shared, durable typography preference for conversation content and composing.
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
