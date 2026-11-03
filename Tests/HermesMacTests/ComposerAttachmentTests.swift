import XCTest
import AppKit
@testable import HermesMac

@MainActor final class ComposerAttachmentTests: XCTestCase {
    private func board() -> NSPasteboard { NSPasteboard.withUniqueName() }
    private func image() throws -> ComposerAttachment {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try ComposerAttachment(name: "image.png", data: XCTUnwrap(bitmap.representation(using: .png, properties: [:])), mimeType: "image/png")
    }

    func testPastedImageDoesNotReplaceTextAndDisabledEditorRejectsIt() throws {
        let pasteboard = board(); defer { pasteboard.releaseGlobally() }
        let attachment = try image()
        pasteboard.setData(attachment.data, forType: .png)
        let editor = SubmitTextView()
        editor.string = "文字草稿"
        var received: [ComposerAttachment] = []
        editor.onPasteAttachments = { received += $0 }
        editor.paste(from: pasteboard)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.data, attachment.data)
        XCTAssertEqual(editor.string, "文字草稿")
        XCTAssertTrue(editor.readablePasteboardTypes.contains(.png))
        XCTAssertTrue(editor.readSelection(from: pasteboard, type: .png))
        XCTAssertEqual(received.count, 2)
        editor.isEditable = false
        editor.paste(from: pasteboard)
        XCTAssertEqual(received.count, 2)
    }

    func testFinderFilesTakePrecedenceAndFoldersAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("含 空格.txt")
        try Data("content".utf8).write(to: file)
        let pasteboard = board(); defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([file as NSURL])
        let attachments = try ComposerAttachment.read(from: pasteboard)
        XCTAssertEqual(attachments.map(\.name), ["含 空格.txt"])
        XCTAssertEqual(attachments.first?.data, Data("content".utf8))
        pasteboard.clearContents(); pasteboard.writeObjects([directory as NSURL])
        XCTAssertThrowsError(try ComposerAttachment.read(from: pasteboard))
    }

    func testTextPasteboardIsNotAnAttachmentAndTIFFConvertsToPNG() throws {
        let pasteboard = board(); defer { pasteboard.releaseGlobally() }
        pasteboard.setString("ordinary text", forType: .string)
        XCTAssertTrue(try ComposerAttachment.read(from: pasteboard).isEmpty)
        let source = try image()
        pasteboard.clearContents()
        pasteboard.setData(try XCTUnwrap(NSImage(data: source.data)?.tiffRepresentation), forType: .tiff)
        let pasted = try XCTUnwrap(ComposerAttachment.read(from: pasteboard).first)
        XCTAssertEqual(pasted.mimeType, "image/png")
        XCTAssertNotNil(NSImage(data: pasted.data))
    }

    func testAttachmentSizeLimitAndConversationIsolation() throws {
        XCTAssertThrowsError(try ComposerAttachment(name: "large", data: Data(count: ComposerAttachment.maxBytes + 1), mimeType: "application/octet-stream"))
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppStore(local: LocalState(defaults: defaults))
        store.connected = true; store.selectedProfile = "a"
        store.addAttachments([try image()])
        XCTAssertTrue(store.canSend)
        store.selectedProfile = "b"
        XCTAssertTrue(store.draftAttachments.isEmpty)
        store.selectedProfile = "a"
        XCTAssertEqual(store.draftAttachments.count, 1)
        store.addAttachments(try (0..<8).map { _ in try image() })
        XCTAssertEqual(store.draftAttachments.count, 1)
        store.removeAttachment(try XCTUnwrap(store.draftAttachments.first?.id))
        XCTAssertFalse(store.canSend)
        store.addAttachments([try image()])
        store.address = "https://another-service.fixture"
        XCTAssertTrue(store.draftAttachments.isEmpty)
    }

    private func fixture(_ body: [String: JSON], address: String) async throws -> JSON {
        var request = URLRequest(url: try XCTUnwrap(URL(string: address + "/__test")))
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(JSON.object(body))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(JSON.self, from: data)
    }

    private func connectedStore() async throws -> (AppStore, HermesClient, UserDefaults, String, String) {
        let address = ProcessInfo.processInfo.environment["HERMES_TEST_SERVER"] ?? ""
        guard !address.isEmpty else { throw XCTSkip("Run script/test.sh") }
        _ = try await fixture(["action": .string("reset")], address: address)
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let local = LocalState(defaults: defaults); local.address = address
        let client = try HermesClient(address: address, credentials: Credentials(sessionToken: "fixture-token"))
        let store = AppStore(local: local, makeClient: { _ in client })
        await store.connect()
        XCTAssertTrue(store.connected)
        return (store, client, defaults, name, address)
    }

    func testImageAndFileUploadBeforePromptAndAttachmentOnlySend() async throws {
        let (store, client, defaults, name, address) = try await connectedStore()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        let img = try image()
        let file = try ComposerAttachment(name: "report.txt", data: Data("report".utf8), mimeType: "text/plain")
        store.addAttachments([img, file])
        XCTAssertTrue(store.canSend)
        await store.send()
        let report = try await fixture(["action": .string("inspect")], address: address)
        let requests = report["requests"].array.filter { ["image.attach_bytes", "file.attach", "prompt.submit"].contains($0["method"].string) }
        XCTAssertEqual(requests.map { $0["method"].string }, ["image.attach_bytes", "file.attach", "prompt.submit"])
        XCTAssertEqual(requests[0]["params"]["content_base64"].string, img.data.base64EncodedString())
        XCTAssertEqual(requests[1]["params"]["data_url"].string, "data:text/plain;base64," + file.data.base64EncodedString())
        XCTAssertTrue(requests[2]["params"]["text"].string.contains("@file:\"uploads/report.txt\""))
        XCTAssertTrue(store.draftAttachments.isEmpty)
        store.addAttachments([img])
        XCTAssertFalse(store.canSend, "Attachments must wait for the active turn to complete")
    }

    func testPartialUploadFailureRetainsDraftAndDetachesStagedImage() async throws {
        let (store, client, defaults, name, address) = try await connectedStore()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        _ = try await fixture(["action": .string("configure"), "attachment_error": .string("file.attach")], address: address)
        store.draft = "keep me"
        store.addAttachments([try image(), try ComposerAttachment(name: "a.txt", data: Data([1]), mimeType: "text/plain")])
        await store.send()
        XCTAssertEqual(store.draft, "keep me")
        XCTAssertEqual(store.draftAttachments.count, 2)
        XCTAssertFalse(store.sendingAttachments)
        XCTAssertNotNil(store.error)
        let report = try await fixture(["action": .string("inspect")], address: address)
        let methods = report["requests"].array.map { $0["method"].string }
        XCTAssertTrue(methods.contains("image.detach"))
        XCTAssertFalse(methods.contains("prompt.submit"))
    }
    func testNavigationDuringUploadKeepsNewDraftAndTargetsOriginalSession() async throws {
        let (store, client, defaults, name, address) = try await connectedStore()
        defer { client.disconnect(); defaults.removePersistentDomain(forName: name) }
        _ = try await fixture(["action": .string("configure"), "attachment_delay": .number(0.15)], address: address)
        store.draft = "original"
        store.addAttachments([try image()])
        let send = Task { await store.send() }
        let deadline = Date().addingTimeInterval(3)
        while store.selectedSession == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let originalSession = try XCTUnwrap(store.selectedSession)
        store.newSession()
        store.draft = "new draft"
        let other = try ComposerAttachment(name: "other.txt", data: Data([2]), mimeType: "text/plain")
        store.addAttachments([other])
        await send.value
        XCTAssertNil(store.selectedSession)
        XCTAssertEqual(store.draft, "new draft")
        XCTAssertEqual(store.draftAttachments.map(\.id), [other.id])
        let report = try await fixture(["action": .string("inspect")], address: address)
        let requests = report["requests"].array
        let imageRuntime = try XCTUnwrap(requests.first { $0["method"].string == "image.attach_bytes" })["params"]["session_id"].string
        let prompt = try XCTUnwrap(requests.first { $0["method"].string == "prompt.submit" })
        XCTAssertEqual(prompt["params"]["session_id"].string, imageRuntime)
        XCTAssertTrue(prompt["params"]["text"].string.contains("original"))
        await store.openSession(originalSession)
        XCTAssertTrue(store.draftAttachments.isEmpty)
        XCTAssertTrue(store.draft.isEmpty)
    }

}
