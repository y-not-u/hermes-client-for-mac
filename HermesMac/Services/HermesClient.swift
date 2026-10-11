import Foundation

@MainActor final class HermesClient {
    let baseURL: URL
    let service: String
    private var credentials: Credentials
    private var credentialsLoaded: Bool
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<JSON, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var ordinal: Double = 0
    private var refreshTask: Task<Void, Error>?
    var onFrame: ((JSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var isConnected: Bool { socket != nil }
    var receivedOrdinal: Double { ordinal }

    init(address: String, credentials: Credentials? = nil, session: URLSession? = nil) throws {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host != nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw ClientError(message: "请输入完整的 http:// 或 https:// 服务地址")
        }
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !parts.path.isEmpty { parts.path = "/" + parts.path }
        guard let url = parts.url else { throw ClientError(message: "无效服务地址") }
        baseURL = url; service = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.credentials = credentials ?? Credentials(); self.credentialsLoaded = credentials != nil
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30
        self.session = session ?? URLSession(configuration: config)
    }
    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.path = baseURL.path + path; c.queryItems = query.isEmpty ? nil : query
        return c.url!
    }
    func setSessionToken(_ token: String, persist: Bool = true) async throws {
        credentials = Credentials(sessionToken: token.trimmingCharacters(in: .whitespacesAndNewlines)); credentialsLoaded = true
        if persist { try await saveCredentials() }
    }
    private func loadCredentials() async {
        guard !credentialsLoaded else { return }
        let account = service
        let loaded = await Task.detached { Keychain.load(service: account) }.value
        guard !credentialsLoaded else { return }
        credentials = loaded; credentialsLoaded = true
    }
    private func saveCredentials() async throws {
        let value = credentials; let account = service
        try await Task.detached { try Keychain.save(value, service: account) }.value
    }
    func setNativeCredentials(_ json: JSON) async throws {
        guard !json["access_token"].string.isEmpty, !json["refresh_token"].string.isEmpty else { throw ClientError(message: "服务未返回原生登录令牌，请升级 Hermes") }
        credentials = Credentials(accessToken: json["access_token"].string, refreshToken: json["refresh_token"].string, provider: json["provider"].string, expiresAt: json["expires_at"].number)
        credentialsLoaded = true; try await saveCredentials()
    }
    func rest(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: JSON? = nil, authenticated: Bool = true, retry: Bool = true) async throws -> JSON {
        if authenticated { await loadCredentials(); try Task.checkCancellation() }
        if authenticated && !credentials.refreshToken.isEmpty && credentials.expiresAt <= Date().timeIntervalSince1970 + 30 { try await refresh() }
        var req = URLRequest(url: url(path, query: query)); req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            if !credentials.accessToken.isEmpty { req.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization") }
            else { req.setValue(credentials.sessionToken, forHTTPHeaderField: "X-Hermes-Session-Token") }
        }
        if let body { req.httpBody = try JSONEncoder().encode(body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ClientError(message: "无效 HTTP 响应") }
        if http.statusCode == 401 && authenticated && retry && !credentials.refreshToken.isEmpty {
            try await refresh(); return try await rest(path, method: method, query: query, body: body, authenticated: authenticated, retry: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError(message: http.statusCode == 401 ? "认证已失效，请在设置中重新登录或更新 session token" : "HTTP \(http.statusCode)：\(String(decoding: data.prefix(800), as: UTF8.self))")
        }
        guard let value = try? JSONDecoder().decode(JSON.self, from: data) else { throw ClientError(message: "服务接口未返回 JSON，请检查地址或升级 Hermes") }; return value
    }
    private func refresh() async throws {
        if let refreshTask { return try await refreshTask.value }
        let token = credentials.refreshToken; let provider = credentials.provider
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            let result = try await self.rest("/auth/native/refresh", method: "POST", body: .object(["refresh_token": .string(token), "provider": .string(provider)]), authenticated: false)
            try await self.setNativeCredentials(result)
        }
        refreshTask = task; defer { refreshTask = nil }; try await task.value
    }
    func testConnection() async throws -> JSON { try await rest("/api/status") }
    func connect() async throws {
        disconnect()
        let status = try await testConnection()
        try Task.checkCancellation()
        var auth: URLQueryItem
        if status["auth_required"].bool {
            guard !credentials.accessToken.isEmpty else { throw ClientError(message: "此服务需要原生登录，请在设置中登录") }
            let ticket = try await rest("/api/auth/ws-ticket", method: "POST")
            try Task.checkCancellation()
            guard !ticket["ticket"].string.isEmpty else { throw ClientError(message: "缺少 WebSocket 票据，请升级 Hermes") }
            auth = URLQueryItem(name: "ticket", value: ticket["ticket"].string)
        } else {
            guard !credentials.sessionToken.isEmpty else { throw ClientError(message: "请在设置中填写本机服务的 session token") }
            auth = URLQueryItem(name: "token", value: credentials.sessionToken)
        }
        try Task.checkCancellation()
        var components = URLComponents(url: url("/api/ws", query: [auth]), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        let ws = session.webSocketTask(with: components.url!); socket = ws; ws.resume()
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    guard let self, !Task.isCancelled, self.socket === ws else { return }
                    let data: Data
                    switch message { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: continue }
                    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                        if let frame = try? JSONDecoder().decode(JSON.self, from: Data(line.utf8)) { self.receive(frame) }
                    }
                }
            } catch {
                guard let self, self.socket === ws else { return }
                self.disconnect(); self.onDisconnect?(error)
            }
        }
        do { _ = try await request("client.capabilities", ["server_requests": .bool(true)]) }
        catch { disconnect(); throw ClientError(message: "WebSocket/协议连接失败：\(error.localizedDescription)。请核对 Hermes revision 与认证配置") }
    }
    func disconnect() {
        reader?.cancel(); reader = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil
        let calls = pending; pending.removeAll()
        timeouts.values.forEach { $0.cancel() }; timeouts.removeAll()
        calls.values.forEach { $0.resume(throwing: ClientError(message: "连接中断；发送结果可能未知，请查询历史后再决定是否重发")) }
    }
    func request(_ method: String, _ params: [String: JSON] = [:]) async throws -> JSON {
        guard let socket else { throw ClientError(message: "服务未连接") }
        let id = "mac-" + UUID().uuidString
        let frame = JSON.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .object(params)])
        let data = try JSONEncoder().encode(frame)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard !Task.isCancelled else { return }
                self?.finish(id, .failure(ClientError(message: "请求超时，结果未知；不会自动重发")))
            }
            Task { [weak self] in
                do { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
                catch { self?.finish(id, .failure(error)) }
            }
        }
    }
    func respond(id: String, result: JSON? = nil) async throws {
        guard let socket else { throw ClientError(message: "连接中断，审批尚未提交") }
        var frame: [String: JSON] = ["jsonrpc": .string("2.0"), "id": .string(id)]
        if let result { frame["result"] = result }
        else { frame["error"] = .object(["code": .number(-32601), "message": .string("HermesMac does not support this server request")]) }
        try await socket.send(.string(String(decoding: JSONEncoder().encode(JSON.object(frame)), as: UTF8.self)))
    }
    private func receive(_ raw: JSON) {
        ordinal += 1
        guard case .object(var fields) = raw else { return }
        fields["_receivedOrdinal"] = .number(ordinal)
        let frame = JSON.object(fields)
        let id = frame["id"].string
        if !id.isEmpty && frame["method"].string.isEmpty {
            if frame["error"] != .null { finish(id, .failure(ClientError(message: frame["error"]["message"].string))) }
            else {
                var result = frame["result"]
                if case .object(var object) = result { object["_responseOrdinal"] = .number(ordinal); result = .object(object) }
                finish(id, .success(result))
            }
        } else { onFrame?(frame) }
    }
    private func finish(_ id: String, _ result: Result<JSON, Error>) {
        timeouts.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(with: result)
    }
}
