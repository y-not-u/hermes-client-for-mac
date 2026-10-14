import XCTest
@testable import HermesMac

@MainActor final class ExtensibilityTests: XCTestCase {
    private final class RecordingDefaults: UserDefaults {
        var writes: [String] = []
        override func set(_ value: Any?, forKey defaultName: String) {
            writes.append(defaultName)
            super.set(value, forKey: defaultName)
        }
    }

    func testLegacyLocalStateMigratesAllDraftsAndSupportsDeletion() throws {
        let suite = "HermesMacTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = LocalState.draftKey(profile: "中文", session: "session")
        var legacy = ServiceState()
        legacy.selectedProfile = "中文"; legacy.profileOrder = ["中文"]
        legacy.lastSession["中文"] = "session"; legacy.drafts[key] = "草稿"
        let service = "https://host/base.with.dots"
        defaults.set(try JSONEncoder().encode([service: legacy, "other": legacy]), forKey: "serviceState")
        let local = LocalState(defaults: defaults)
        XCTAssertNil(defaults.data(forKey: "serviceState"))
        XCTAssertEqual(local.state(service), legacy)
        XCTAssertEqual(LocalState(defaults: defaults).state("other"), legacy)
        local.update(service) { $0.drafts.removeValue(forKey: key) }
        let restored = LocalState(defaults: defaults)
        XCTAssertNil(restored.state(service).drafts[key])
        XCTAssertEqual(restored.state("other").drafts[key], "草稿")
        XCTAssertEqual(restored.state(service).selectedProfile, "中文")
    }

    func testTypingWritesOnlyChangedDraftAndSkipsUnchangedState() throws {
        let suite = "HermesMacTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(RecordingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = LocalState(defaults: defaults)
        local.update("a") { $0.selectedProfile = "p"; $0.drafts["first"] = "one"; $0.drafts["second"] = "two" }
        local.update("b") { $0.drafts["first"] = "other service" }
        defaults.writes = []
        local.setDraft("edited", for: "first", service: "a")
        XCTAssertEqual(defaults.writes.count, 1)
        XCTAssertTrue(defaults.writes.first?.contains(".draft.") == true)
        defaults.writes = []
        local.setDraft("edited", for: "first", service: "a")
        XCTAssertTrue(defaults.writes.isEmpty)
        let restored = LocalState(defaults: defaults)
        XCTAssertEqual(restored.state("a").drafts["first"], "edited")
        XCTAssertEqual(restored.state("a").drafts["second"], "two")
        XCTAssertEqual(restored.state("b").drafts["first"], "other service")
    }

    private final class DeferredRPC: HermesRPCExecuting {
        var pending: [CheckedContinuation<JSON, Error>] = []
        func execute(_ request: HermesRPCRequest) async throws -> JSON {
            try await withCheckedThrowingContinuation { pending.append($0) }
        }
    }

    private func catalog(_ model: String) -> JSON {
        .object(["providers": .array([]), "model": .string(model)])
    }

    func testCatalogLatestReadWinsAndResetInvalidatesInFlightRead() async {
        let models = ModelCatalogStore()
        let rpc = DeferredRPC()
        let context = ModelPickerContext(service: "local", profile: "a", sessionID: "stored")
        let first = Task { await models.load(context, runtimeID: "runtime", refresh: false, using: rpc) }
        while rpc.pending.count < 1 { await Task.yield() }
        let second = Task { await models.load(context, runtimeID: "runtime", refresh: true, using: rpc) }
        while rpc.pending.count < 2 { await Task.yield() }
        rpc.pending[1].resume(returning: catalog("new"))
        await second.value
        rpc.pending[0].resume(throwing: ClientError(message: "stale failure"))
        await first.value
        XCTAssertEqual(models.catalogs[context]?.model, "new")
        XCTAssertNil(models.errors[context]); XCTAssertFalse(models.loading.contains(context))
        let third = Task { await models.load(context, runtimeID: "runtime", refresh: false, using: rpc) }
        while rpc.pending.count < 3 { await Task.yield() }
        models.reset()
        rpc.pending[2].resume(returning: catalog("old connection"))
        await third.value
        XCTAssertTrue(models.catalogs.isEmpty); XCTAssertTrue(models.loading.isEmpty)
    }

    func testModelMutationInvalidatesPendingRead() async {
        let models = ModelCatalogStore()
        let rpc = DeferredRPC()
        let context = ModelPickerContext(service: "local", profile: "a", sessionID: "stored")
        let initial = Task { await models.load(context, runtimeID: nil, refresh: false, using: rpc) }
        while rpc.pending.count < 1 { await Task.yield() }
        rpc.pending[0].resume(returning: catalog("initial")); await initial.value
        let refresh = Task { await models.load(context, runtimeID: nil, refresh: true, using: rpc) }
        while rpc.pending.count < 2 { await Task.yield() }
        models.didSwitch(context, model: "selected", provider: "provider")
        rpc.pending[1].resume(returning: catalog("stale")); await refresh.value
        XCTAssertEqual(models.catalogs[context]?.model, "selected")
        XCTAssertEqual(models.catalogs[context]?.provider, "provider")
        XCTAssertFalse(models.loading.contains(context))
    }
}
