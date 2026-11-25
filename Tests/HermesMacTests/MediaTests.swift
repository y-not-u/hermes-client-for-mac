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

private actor ConcurrentImageFetches {
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var count = 0

    func fetch(_ data: Data, fails: Bool) async throws -> Data {
        active += 1; count += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(30))
        if fails { throw URLError(.networkConnectionLost) }
        return data
    }
}

@MainActor final class MediaTests: XCTestCase {
    private func png(width: Int = 4, height: Int = 3) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private func request(service: String = "https://media.fixture", profile: String = "financial", session: String = "stored", message: String = "message", path: String = "/home/egg/.hermes/profiles/financial/cache/scratch/main.png") -> RemoteImageRequest {
        RemoteImageRequest(conversation: ConversationKey(service: service, profile: profile, storedID: session), messageID: message, path: path)
    }
    private func fileRequest(service: String, profile: String = "financial", session: String = "stored", message: String = "message", path: String = "/home/egg/.hermes/exports/openbot/openbot.lan.crt") -> RemoteFileRequest {
        RemoteFileRequest(conversation: ConversationKey(service: service, profile: profile, storedID: session), messageID: message, path: path)
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
        XCTAssertEqual(MediaDirective.segments("MEDIA:`/tmp/含 空格.png`", renderMedia: true), [.image("/tmp/含 空格.png")])
    }

    func testCodeQuotesAndRemoteURLsDoNotBecomeCards() {
        let text = "```python\nMEDIA:/tmp/example.png\n```\n> MEDIA:/tmp/quote.png\n例子 `MEDIA:/tmp/inline.png`\nMEDIA:/tmp/report.pdf\nMEDIA:https://third-party.test/image.png\n~~~\nMEDIA:/tmp/fenced.png\n~~~"
        let segments = MediaDirective.segments(text, renderMedia: true)
        XCTAssertFalse(segments.contains { if case .image = $0 { return true }; return false })
        XCTAssertTrue(segments.contains(.code("MEDIA:/tmp/example.png", language: "python")))
        XCTAssertTrue(segments.contains(.code("MEDIA:/tmp/fenced.png", language: "")))
        XCTAssertTrue(segments.contains(.file("/tmp/report.pdf")))
        XCTAssertTrue(segments.contains(.text("MEDIA:https://third-party.test/image.png")))
        XCTAssertEqual(MediaDirective.segments("```\nMEDIA:/tmp/incomplete.png", renderMedia: true), [.code("MEDIA:/tmp/incomplete.png", language: "")])
    }

    func testMarkdownImagesResolveServerPathsAndDeduplicateMediaDirectives() {
        let text = """
        趋势 ![小红书黄金讨论折线图](/home/egg/projects/xhs-gold-index/gold-discussion.png) 如图
        MEDIA:/home/egg/projects/xhs-gold-index/gold-discussion.png
        ![带空格](<~/charts/图 表.PNG> "标题")
        ![带括号](/tmp/chart(1).png)
        """
        XCTAssertEqual(MediaDirective.segments(text, renderMedia: true), [
            .text("趋势 "), .image("/home/egg/projects/xhs-gold-index/gold-discussion.png"), .text(" 如图"),
            .image("~/charts/图 表.PNG"), .image("/tmp/chart(1).png")
        ])
        XCTAssertEqual(MediaDirective.segments(text, renderMedia: false), [.text(text)])
    }

    func testMarkdownImagesIgnoreExamplesAndUnsupportedDestinations() {
        let text = #"""
        > ![引用](/tmp/quote.png)
            ![缩进](/tmp/indent.png)
        `![行内代码](/tmp/inline.png)`
        `` ` ![行内代码](/tmp/multitick.png) ``
        \![转义](/tmp/escaped.png)
        ![外部](https://third-party.test/image.png)
        ![外部](//third-party.test/image.png)
        ![外部](/%2Fthird-party.test/image.png)
        ![相对](images/chart.png)
        ![文件](/tmp/report.pdf)
        [普通链接](/tmp/chart.png)
        ![尚未输出完整](/tmp/incomplete.png
        """#
        XCTAssertEqual(MediaDirective.segments(text, renderMedia: true), [.text(text)])
        XCTAssertEqual(MediaDirective.segments("```md\n![代码](/tmp/fenced.png)\n```", renderMedia: true), [
            .code("![代码](/tmp/fenced.png)", language: "md")
        ])
    }

    func testNonImageDirectivesBecomeDownloadCards() {
        let text = "证书\nMEDIA:/home/egg/.hermes/exports/openbot/openbot.lan.crt\nMEDIA:'/tmp/含 空格.zip'\nMEDIA:/tmp/图.png\nMEDIA:~/exports/dump.bin 说明"
        XCTAssertEqual(MediaDirective.segments(text, renderMedia: true), [
            .text("证书"),
            .file("/home/egg/.hermes/exports/openbot/openbot.lan.crt"),
            .file("/tmp/含 空格.zip"),
            .image("/tmp/图.png"),
            .file("~/exports/dump.bin"), .text(" 说明")
        ])
        XCTAssertEqual(MediaDirective.segments("MEDIA:/home/egg/.hermes/exports/openbot/openbot.lan.crt", renderMedia: false),
                       [.text("MEDIA:/home/egg/.hermes/exports/openbot/openbot.lan.crt")])
        XCTAssertEqual(MediaDirective.segments("MEDIA:/tmp/x.crt\nMEDIA:/tmp/x.crt", renderMedia: true), [.file("/tmp/x.crt")])
    }

    func testFileDecoderAcceptsAnyMimeAndRejectsMalformedPayloads() throws {
        let payload = Data("-----BEGIN CERTIFICATE-----".utf8)
        XCTAssertEqual(try RemoteFileDecoder.dataURL("data:application/x-x509-ca-cert;base64," + payload.base64EncodedString()), payload)
        XCTAssertEqual(try RemoteFileDecoder.dataURL("data:application/octet-stream;base64,"), Data())
        for value in ["https://example.test/a.crt", "data:text/plain,SGk=", "data:text/plain;base64,!bad!"] {
            XCTAssertThrowsError(try RemoteFileDecoder.dataURL(value))
        }
        XCTAssertThrowsError(try RemoteFileDecoder.dataURL("data:application/octet-stream;base64," + String(repeating: "A", count: ((RemoteFileDecoder.maxBytes + 2) / 3) * 4 + 4)))
        XCTAssertEqual(RemoteFileDecoder.suggestedName(for: "/home/egg/.hermes/exports/openbot/openbot.lan.crt"), "openbot.lan.crt")
        XCTAssertEqual(RemoteFileDecoder.suggestedName(for: "/tmp/folder/"), "folder")
        XCTAssertEqual(RemoteFileDecoder.suggestedName(for: "/"), "download")
    }

    func testFileDownloadUsesAuthenticatedReadAndRejectsEmptyPayload() async throws {
        let payload = Data("-----BEGIN CERTIFICATE-----".utf8)
        MediaHTTPProtocol.configure(body: try JSONEncoder().encode(JSON.object(["dataUrl": .string("data:application/x-x509-ca-cert;base64," + payload.base64EncodedString())])))
        let client = try client(credentials: Credentials(sessionToken: "test-token"))
        let attachment = fileRequest(service: client.service)
        let downloaded = try await client.fileData(for: attachment)
        XCTAssertEqual(downloaded, payload)
        let sent = try XCTUnwrap(MediaHTTPProtocol.requests.first)
        XCTAssertEqual(sent.url?.path, "/prefix/api/fs/read-data-url")
        let query = try XCTUnwrap(URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "path" }?.value, attachment.path)
        XCTAssertEqual(query.first { $0.name == "profile" }?.value, "financial")
        XCTAssertEqual(query.first { $0.name == "session_id" }?.value, "stored")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "test-token")

        MediaHTTPProtocol.configure(body: try JSONEncoder().encode(JSON.object(["dataUrl": .string("https://example.test/a.crt")])))
        do { _ = try await client.fileData(for: attachment); XCTFail("Expected payload rejection") }
        catch let error as ClientError { XCTAssertTrue(error.message.contains("文件")) }

        MediaHTTPProtocol.configure(status: 413, body: Data("{\"detail\":\"File too large\"}".utf8))
        do { _ = try await client.fileData(for: attachment); XCTFail("Expected HTTP error") }
        catch let error as ClientError { XCTAssertEqual(error.httpStatus, 413); XCTAssertTrue(error.message.contains("413")) }

        MediaHTTPProtocol.configure(body: Data())
        do { _ = try await client.fileData(for: fileRequest(service: "https://other.fixture")); XCTFail("Expected service mismatch") }
        catch { XCTAssertTrue(MediaHTTPProtocol.requests.isEmpty) }
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
        let markdown = ##"![图](/home/egg/.hermes/profiles/financial/cache/图%20+%20%25%20\#%20%3F.png)"##
        guard case .image(let path)? = MediaDirective.segments(markdown, renderMedia: true).first else {
            return XCTFail("Expected a server image from Markdown")
        }
        let imageRequest = request(service: client.service, path: path)
        XCTAssertEqual(path, "/home/egg/.hermes/profiles/financial/cache/图 + % # ?.png")
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

    func testLargeImageThumbnailIsBoundedAndOriginalSurvivesCacheRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try png(width: 2400, height: 1800)
        let cache = RemoteImageCache(directory: directory)
        let file = try await cache.image(for: request()) { data }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(file.thumbnail as CFData, nil))
        let thumbnail = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(thumbnail.width, 1080)
        XCTAssertEqual(thumbnail.height, 810)
        XCTAssertEqual(file.pixelWidth, 2400)
        XCTAssertEqual(file.pixelHeight, 1800)
        XCTAssertEqual(try Data(contentsOf: file.url), data)
        let restarted = RemoteImageCache(directory: directory)
        let cached = try await restarted.image(for: request()) { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(cached.thumbnail, file.thumbnail)
        XCTAssertEqual(cached.pixelWidth, file.pixelWidth)
    }

    func testImageLoadConcurrencyIsBoundedAndFailureReleasesSlot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = RemoteImageCache(directory: directory, maxConcurrentLoads: 2)
        let fetches = ConcurrentImageFetches()
        let data = try png()
        let requests = (0..<8).map { request(message: "parallel-\($0)") }
        let succeeded = await withTaskGroup(of: Bool.self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    do {
                        _ = try await cache.image(for: request) { try await fetches.fetch(data, fails: index == 0) }
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        XCTAssertEqual(succeeded, 7)
        let peak = await fetches.peak, count = await fetches.count, active = await fetches.active
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(count, 8)
        XCTAssertEqual(active, 0)
        _ = try await cache.image(for: requests[0]) { data }
    }

    func testMarkdownMemoTracksSourceAndMediaModeAcrossStreamRevisions() {
        let cache = MarkdownSegmentCache()
        let source = "before\nMEDIA:/tmp/image.png\n```swift\nlet value = 1"
        XCTAssertEqual(cache.segments(for: source, renderMedia: false), MediaDirective.segments(source, renderMedia: false))
        XCTAssertEqual(cache.segments(for: source, renderMedia: true), [.text("before"), .image("/tmp/image.png"), .code("let value = 1", language: "swift")])
        let completed = source + "\n```\nafter"
        XCTAssertEqual(cache.segments(for: completed, renderMedia: true), MediaDirective.segments(completed, renderMedia: true))
        XCTAssertEqual(cache.segments(for: "", renderMedia: false), MediaDirective.segments("", renderMedia: false))
    }
}
