import Foundation
import Observation

/// Owns model catalog reads, errors and stale-response protection independently of UI navigation.
@MainActor @Observable final class ModelCatalogStore {
    private(set) var catalogs: [ModelPickerContext: ModelCatalog] = [:]
    private(set) var errors: [ModelPickerContext: String] = [:]
    private(set) var loading: Set<ModelPickerContext> = []
    @ObservationIgnored private var revisions: [ModelPickerContext: UUID] = [:]

    func load(_ context: ModelPickerContext, runtimeID: String?, refresh: Bool,
              using executor: any HermesRPCExecuting) async {
        let revision = UUID()
        revisions[context] = revision; loading.insert(context); errors[context] = nil
        defer { if revisions[context] == revision { loading.remove(context) } }
        do {
            let json = try await executor.execute(.modelOptions(profile: context.profile, runtimeID: runtimeID, refresh: refresh))
            guard revisions[context] == revision else { return }
            catalogs[context] = try ModelCatalog(json)
        } catch {
            guard revisions[context] == revision else { return }
            errors[context] = error.localizedDescription
        }
    }

    func copyCatalog(from source: ModelPickerContext, to destination: ModelPickerContext) {
        catalogs[destination] = catalogs[source]
    }

    func didSwitch(_ context: ModelPickerContext, model: String, provider: String) {
        revisions[context] = UUID(); loading.remove(context)
        catalogs[context]?.model = model; catalogs[context]?.provider = provider
        errors[context] = nil
    }

    func setError(_ message: String, for context: ModelPickerContext) { errors[context] = message }

    func remove(_ context: ModelPickerContext) {
        catalogs.removeValue(forKey: context); errors.removeValue(forKey: context)
        loading.remove(context); revisions.removeValue(forKey: context)
    }

    func reset() {
        catalogs = [:]; errors = [:]; loading = []; revisions = [:]
    }
}
