import XCTest
import Observation
@testable import HermesMac

@MainActor final class SessionListTests: XCTestCase {
    func testPinsPersistAndStayAboveNewerRowsWithoutChangingPagination() throws {
        let name = "HermesPins-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppStore(local: LocalState(defaults: defaults))
        let recent = SessionSummary(id: "recent", title: "Recent")
        let old = SessionSummary(id: "old", title: "Old")
        store.sessions["a"] = [recent, old]
        let changed = expectation(description: "Pinning updates the visible list")
        withObservationTracking { _ = store.displayedSessions(profile: "a") }
            onChange: { changed.fulfill() }
        store.toggleSessionPin(old, profile: "a")
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(store.displayedSessions(profile: "a").map(\.id), ["old", "recent"])
        XCTAssertEqual(store.sessions["a"], [recent, old])
        XCTAssertFalse(store.isSessionPinned("old", profile: "b"))
        let restored = AppStore(local: LocalState(defaults: defaults))
        XCTAssertTrue(restored.isSessionPinned("old", profile: "a"))
        // Pinned rows survive refresh/restart even outside the first server page.
        restored.sessions["a"] = [recent]
        XCTAssertEqual(restored.displayedSessions(profile: "a").map(\.id), ["old", "recent"])
        restored.address = "http://another-service"
        XCTAssertFalse(restored.isSessionPinned("old", profile: "a"))
        restored.address = store.address
        restored.toggleSessionPin(old, profile: "a")
        XCTAssertEqual(restored.displayedSessions(profile: "a"), [recent])
        XCTAssertFalse(AppStore(local: LocalState(defaults: defaults)).isSessionPinned("old", profile: "a"))
    }

    func testSearchOnlyPinsMatchingResultsAndUsesFreshSummaries() {
        let name = "HermesPinSearch-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppStore(local: LocalState(defaults: defaults))
        let old = SessionSummary(id: "old", title: "Old")
        let other = SessionSummary(id: "other", title: "Other")
        store.toggleSessionPin(old, profile: "a")
        store.toggleSessionPin(other, profile: "a")
        let fresh = SessionSummary(id: "old", title: "Renamed")
        store.search = "Renamed"
        store.sessions["a"] = [fresh]
        XCTAssertEqual(store.displayedSessions(profile: "a"), [fresh])
        store.search = ""
        XCTAssertEqual(store.displayedSessions(profile: "a"), [other, fresh])
        store.sessions["a"] = [fresh, other]
        store.toggleSessionPin(old, profile: "a")
        store.toggleSessionPin(other, profile: "a")
        XCTAssertEqual(store.displayedSessions(profile: "a"), [fresh, other])
    }

    func testMetadataBeforePinningStillDecodes() throws {
        let data = Data(#"{"profileOrder":["a"],"selectedProfile":"a","lastSession":{"a":"old"},"drafts":{"draft":"text"}}"#.utf8)
        let state = try JSONDecoder().decode(ServiceState.self, from: data)
        XCTAssertEqual(state.selectedProfile, "a")
        XCTAssertEqual(state.lastSession["a"], "old")
        XCTAssertEqual(state.drafts["draft"], "text")
        XCTAssertNil(state.pinnedSessions)
    }

    func testBackgroundRowsObserveIndependentReplyCompletionAndUncertainty() throws {
        let name = "HermesSessionList-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppStore(local: LocalState(defaults: defaults))
        store.selectedProfile = "profile"
        store.selectedSession = "first"
        let first = Conversation(key: ConversationKey(service: store.service, profile: "profile", storedID: "first"))
        let second = Conversation(key: ConversationKey(service: store.service, profile: "profile", storedID: "second"))
        first.generating = true
        second.generating = true
        store.conversations[first.key] = first
        store.conversations[second.key] = second
        // Identical stored IDs in another service/profile must not override the row.
        let foreignService = Conversation(key: ConversationKey(service: "other-service", profile: "profile", storedID: "first"))
        let foreignProfile = Conversation(key: ConversationKey(service: store.service, profile: "other-profile", storedID: "first"))
        foreignService.uncertain = true
        foreignProfile.uncertain = true
        store.conversations[foreignService.key] = foreignService
        store.conversations[foreignProfile.key] = foreignProfile

        XCTAssertEqual(SessionReplyStatus.status(for: "first", in: store), .answering)
        XCTAssertEqual(SessionReplyStatus.status(for: "second", in: store), .answering)
        XCTAssertEqual(SessionReplyStatus.status(for: "missing", in: store), .idle)
        let firstChanged = expectation(description: "Selected row observes reply completion")
        withObservationTracking {
            _ = SessionReplyStatus.status(for: "first", in: store)
        } onChange: { firstChanged.fulfill() }
        first.generating = false
        wait(for: [firstChanged], timeout: 1)
        XCTAssertEqual(SessionReplyStatus.status(for: "first", in: store), .idle)
        XCTAssertEqual(SessionReplyStatus.status(for: "second", in: store), .answering)

        let backgroundChanged = expectation(description: "Background row observes uncertainty")
        withObservationTracking {
            _ = SessionReplyStatus.status(for: "second", in: store)
        } onChange: { backgroundChanged.fulfill() }
        second.uncertain = true
        wait(for: [backgroundChanged], timeout: 1)
        XCTAssertTrue(second.generating)
        XCTAssertEqual(SessionReplyStatus.status(for: "second", in: store), .uncertain)
        second.uncertain = false
        second.generating = false
        XCTAssertEqual(SessionReplyStatus.status(for: "second", in: store), .idle)
    }

    func testUnreadCompletionMarksRowUntilViewedOrNewReplyBegins() throws {
        let name = "HermesUnreadRow-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppStore(local: LocalState(defaults: defaults))
        store.selectedProfile = "profile"
        let conversation = Conversation(key: ConversationKey(service: store.service, profile: "profile", storedID: "background"))
        store.conversations[conversation.key] = conversation
        conversation.begin("question")
        conversation.apply(type: "message.complete", payload: .object(["text": .string("answer")]), visible: false)
        XCTAssertEqual(SessionReplyStatus.status(for: "background", in: store), .unread)
        let changed = expectation(description: "Viewing the reply updates its row")
        withObservationTracking {
            _ = SessionReplyStatus.status(for: "background", in: store)
        } onChange: { changed.fulfill() }
        conversation.unread = false
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(SessionReplyStatus.status(for: "background", in: store), .idle)
        conversation.unread = true
        conversation.begin("next question")
        XCTAssertEqual(SessionReplyStatus.status(for: "background", in: store), .answering)
        conversation.apply(type: "message.complete", payload: .object(["text": .string("visible answer")]), visible: true)
        XCTAssertEqual(SessionReplyStatus.status(for: "background", in: store), .idle)
    }

}
