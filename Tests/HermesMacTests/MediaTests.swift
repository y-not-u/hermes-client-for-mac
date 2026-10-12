import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import HermesMac

private final class MediaHTTPProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responseBody = Data()
    private static var responseStatus = 200
    private static var recorded: [URLRequest] = []
    static func configure(status: Int = 200, body: Data) {
        lock.lock(); defer { lock.unlock() }
        responseStatus = status; responseBody = body; recorded = []
    }
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let status = Self.responseStatus, body = Self.responseBody
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor ImageFetchCounter {
    var count = 0
    let data: Data
    init(_ data: Data) { self.data = data }
    func fetch() async throws -> Data {
        count += 1
        try await Task.sleep(for: .milliseconds(10))
        return data
    }
}

@MainActor final class MediaTests: XCTestCase {
    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 16,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private func request(service: String = "https://media.fixture", profile: String = "financial", session: String = "stored", message: String = "message", path: String = "/home/egg/.hermes/profiles/financial/cache/scratch/main.png") -> RemoteImageRequest {
        RemoteImageRequest(conversation: ConversationKey(service: service, profile: profile, storedID: session), messageID: message, path: path)
    }
    private func client(credentials: Credentials) throws -> HermesClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MediaHTTPProtocol.self]
        return try HermesClient(address: "https://media.fixture/prefix", credentials: credentials, session: URLSession(configuration: config))
    }

    func testDirectivesPreserveOrderAndDeduplicateQuotedPaths() {
        let text = "开头\nMEDIA:/tmp/图.png\n中间 MEDIA:\"/tmp/含 空格.png\" 说明\nMEDIA:/tmp/图.png\n结尾"
        XCTAssertEqual(MediaDirective.segments(text, renderMedia: true), [
            .text("开头"), .image("/tmp/图.png"), .text("中间 "), .image("/tmp/含 空格.png"), .text(" 说明"), .text("结尾")
        ])
        XCTAssertEqual(MediaDirective.segments(text, renderMedia: false), [.text(text)])
    }

    func testCodeQuotesAndNonImagesDoNotTriggerDownloads() {
        let text = "```python\nMEDIA:/tmp/example.png\n```\n> MEDIA:/tmp/quote.png\n例子 `MEDIA:/tmp/inline.png`\nMEDIA:/tmp/report.pdf\nMEDIA:https://third-party.test/image.png\nMEDIA:/tmp/unfinished\n~~~\nMEDIA:/tmp/fenced.png\n~~~"
        let segments = MediaDirective.segments(text, renderMedia: true)
        XCTAssertFalse(segments.contains { if case .image = $0 { return true }; return false })
        XCTAssertTrue(segments.contains(.code("MEDIA:/tmp/example.png", language: "python")))
        XCTAssertTrue(segments.contains(.code("MEDIA:/tmp/fenced.png", language: "")))
        XCTAssertEqual(MediaDirective.segments("```\nMEDIA:/tmp/incomplete.png", renderMedia: true), [.code("MEDIA:/tmp/incomplete.png", language: "")])
    }

    func testDecoderRejectsMalformedOversizedAndNonImagePayloads() throws {
        let data = try png()
        XCTAssertEqual(try RemoteImageDecoder.dataURL("data:image/png;base64," + data.base64EncodedString()), data)
        for value in ["https://example.test/a.png", "data:text/html;base64,SGk=", "data:image/png;base64,", "data:image/png;base64,!notbase64!"] {
            XCTAssertThrowsError(try RemoteImageDecoder.dataURL(value))
        }
        XCTAssertThrowsError(try RemoteImageDecoder.dataURL("data:image/png;base64," + String(repeating: "A", count: ((RemoteImageDecoder.maxBytes + 2) / 3) * 4 + 4)))
        XCTAssertThrowsError(try RemoteImageDecoder.file(Data("<html>not an image</html>".utf8), url: URL(fileURLWithPath: "/tmp/a.png")))
    }

    func testAuthenticatedReadUsesStoredSessionProfileAndExactEncodedPath() async throws {
        let data = try png()
        MediaHTTPProtocol.configure(body: try JSONEncoder().encode(JSON.object(["dataUrl": .string("data:image/png;base64," + data.base64EncodedString())])))
        let client = try client(credentials: Credentials(sessionToken: "test-token"))
        let imageRequest = request(service: client.service, path: "/home/egg/.hermes/profiles/financial/cache/图 + % # ?.png")
        let result = try await client.imageData(for: imageRequest)
        XCTAssertEqual(result, data)
        let sent = try XCTUnwrap(MediaHTTPProtocol.requests.first)
        XCTAssertEqual(sent.url?.path, "/prefix/api/fs/read-data-url")
        let query = try XCTUnwrap(URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "path" }?.value, imageRequest.path)
        XCTAssertEqual(query.first { $0.name == "profile" }?.value, "financial")
        XCTAssertEqual(query.first { $0.name == "session_id" }?.value, "stored")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "test-token")
        XCTAssertNil(query.first { $0.name == "token" })
        let native = try self.client(credentials: Credentials(accessToken: "access-token", expiresAt: 9999999999))
        _ = try await native.imageData(for: imageRequest)
        XCTAssertEqual(MediaHTTPProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
    }

    func testHTTPFailuresStayFailuresAndNeverFetchOtherServices() async throws {
        let client = try client(credentials: Credentials(sessionToken: "test-token"))
        for status in [401, 403, 404, 413] {
            MediaHTTPProtocol.configure(status: status, body: Data("{\"detail\":\"Not found\"}".utf8))
            do {
                _ = try await client.imageData(for: request(service: client.service))
                XCTFail("Expected HTTP error")
            } catch let error as ClientError { XCTAssertEqual(error.httpStatus, status) }
            XCTAssertEqual(MediaHTTPProtocol.requests.count, 1)
        }
        MediaHTTPProtocol.configure(body: Data())
        do { _ = try await client.imageData(for: request(service: "https://other.fixture")); XCTFail("Expected service mismatch") }
        catch { XCTAssertTrue(MediaHTTPProtocol.requests.isEmpty) }
    }

    func testCacheCoalescesAndSurvivesRestartWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try png(), counter = ImageFetchCounter(data)
        let cache = RemoteImageCache(directory: directory)
        let imageRequest = request()
        let files = try await withThrowingTaskGroup(of: RemoteImageFile.self) { group in
            for _ in 0..<5 { group.addTask { try await cache.image(for: imageRequest) { try await counter.fetch() } } }
            var results: [RemoteImageFile] = []
            for try await file in group { results.append(file) }
            return results
        }
        let count = await counter.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(Set(files.map(\.url)).count, 1)
        XCTAssertEqual(files.first?.pixelWidth, 4); XCTAssertEqual(files.first?.pixelHeight, 3)
        let restarted = RemoteImageCache(directory: directory)
        let cached = try await restarted.image(for: imageRequest) { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(try Data(contentsOf: cached.url), data)
        XCTAssertFalse(cached.thumbnail.isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: cached.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testCacheSeparatesServicesProfilesSessionsAndMessagesAndRepairsCorruption() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try png(), counter = ImageFetchCounter(data)
        let cache = RemoteImageCache(directory: directory)
        var files: [RemoteImageFile] = []
        for imageRequest in [request(), request(service: "https://other.fixture"), request(profile: "life"), request(session: "other"), request(message: "other")] {
            files.append(try await cache.image(for: imageRequest) { try await counter.fetch() })
        }
        XCTAssertEqual(Set(files.map(\.url)).count, 5)
        try Data("corrupt".utf8).write(to: files[0].url)
        let repaired = try await cache.image(for: request()) { try await counter.fetch() }
        XCTAssertEqual(try Data(contentsOf: repaired.url), data)
        let count = await counter.count
        XCTAssertEqual(count, 6)
    }

    func testDiskCacheIsBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try png()
        let cache = RemoteImageCache(directory: directory, maxDiskBytes: data.count * 2)
        var latest: RemoteImageFile?
        for index in 0..<4 { latest = try await cache.image(for: request(message: String(index))) { data } }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(latest).url.path))
    }
}
