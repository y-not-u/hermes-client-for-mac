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
