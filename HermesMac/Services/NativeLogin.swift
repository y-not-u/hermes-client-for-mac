import AppKit
import CryptoKit
import Network

/// RFC 8252: an ephemeral listener restricted to IPv4 loopback; PKCE and state bind the callback.
@MainActor final class NativeLogin {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var state = ""
    private var verifier = ""
    private var path = ""
    private let openBrowser: (URL) -> Bool
    init(openBrowser: ((URL) -> Bool)? = nil) { self.openBrowser = openBrowser ?? { NSWorkspace.shared.open($0) } }
    func signIn(client: HermesClient) async throws {
        let status = try await client.rest("/api/status", authenticated: false)
        guard status["auth_flows"].array.contains(.string("native_pkce")) else { throw ClientError(message: "此服务不支持 native_pkce，请升级 Hermes 并配置官方认证") }
        state = UUID().uuidString; path = "/callback/" + UUID().uuidString
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw ClientError(message: "无法生成登录随机数") }
        verifier = Self.base64(Data(random))
        let challenge = Self.base64(Data(SHA256.hash(data: Data(verifier.utf8))))
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters); self.listener = listener
        let code: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                continuation = c
                listener.stateUpdateHandler = { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.continuation != nil else { return }
                        switch event {
                        case .ready:
                            guard let port = listener.port else { self.finish(.failure(ClientError(message: "登录回调端口不可用"))); return }
                            let callback = "http://127.0.0.1:\(port.rawValue)\(self.path)"
                            let url = client.url("/auth/native/authorize", query: [URLQueryItem(name: "redirect_uri", value: callback), URLQueryItem(name: "state", value: self.state), URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256")])
                            if !self.openBrowser(url) { self.finish(.failure(ClientError(message: "无法打开系统浏览器"))) }
                        case .failed(let error): self.finish(.failure(error))
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    connection.start(queue: .main)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
                        Task { @MainActor in
                            guard let self else { connection.cancel(); return }
                            let first = String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                            let pieces = first.split(separator: " ")
                            let target = pieces.count > 1 ? String(pieces[1]) : ""
                            let components = URLComponents(string: "http://127.0.0.1" + target)
                            let items = components?.queryItems ?? []
                            let valid = pieces.first == "GET" && components?.path == self.path && items.first(where: { $0.name == "state" })?.value == self.state
                            let code = items.first(where: { $0.name == "code" })?.value ?? ""
                            let body = valid && !code.isEmpty ? "Login complete. You can return to HermesMac." : "Invalid login callback."
                            let response = "HTTP/1.1 \(valid ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                            if valid && !code.isEmpty { self.finish(.success(code)) }
                        }
                    }
                }
                listener.start(queue: .main)
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(180)); guard !Task.isCancelled else { return }
                    self?.finish(.failure(ClientError(message: "登录超时，请重试")))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        let result = try await client.rest("/auth/native/token", method: "POST", body: .object(["code": .string(code), "code_verifier": .string(verifier)]), authenticated: false)
        try await client.setNativeCredentials(result)
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<String, Error>) {
        listener?.cancel(); listener = nil; timeout?.cancel(); timeout = nil
        let c = continuation; continuation = nil; c?.resume(with: result)
    }
    private static func base64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
