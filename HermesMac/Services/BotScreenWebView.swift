import SwiftUI
import WebKit

/// Every transport attempt carries an identity, so a late disconnect cannot affect a new profile.
enum BotScreenViewerEvent {
    case connected(UUID)
    case disconnected(UUID, clean: Bool)
    case failed(UUID, message: String)
}

/// The desktop canvas handles mouse input; it must never become a window drag surface.
final class BotScreenNativeWebView: WKWebView {
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A local noVNC renderer. The only remote value entering JavaScript is a single-use display ticket URL.
struct BotScreenWebView: NSViewRepresentable {
    let connectionID: UUID
    let websocketURL: URL
    let hasControl: Bool
    var onEvent: (BotScreenViewerEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let view = context.coordinator.makeWebView()
        context.coordinator.configure(id: connectionID, url: websocketURL, hasControl: hasControl, onEvent: onEvent)
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.configure(id: connectionID, url: websocketURL, hasControl: hasControl, onEvent: onEvent)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.dispose() }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private(set) var webView: WKWebView?
        private var id: UUID?
        private var socketURL: URL?
        private var hasControl = false
        private var focusedForControl = false
        private var ready = false
        private var disposed = false
        private var callback: ((BotScreenViewerEvent) -> Void)?
        private let assets = BotScreenAssetHandler()
        private let handshakeTimeout: Duration
        private var timeoutTask: Task<Void, Never>?
        private var attemptGeneration = UUID()
        private var attemptEnded = false

        init(handshakeTimeout: Duration = .seconds(15)) {
            self.handshakeTimeout = handshakeTimeout
            super.init()
        }
        deinit {
            timeoutTask?.cancel()
            // The renderer can outlive SwiftUI's coordinator (for example in a host view).
            // Teardown stays on the main actor without capturing the dying coordinator.
            if let view = webView {
                Task { @MainActor in Self.disposeWebView(view) }
            }
        }

        private static let pageURL = URL(string: "hermes-botscreen://viewer/index.html")!

        func makeWebView() -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.setURLSchemeHandler(assets, forURLScheme: "hermes-botscreen")
            configuration.userContentController.add(WeakBotScreenMessageHandler(delegate: self), name: "botScreen")
            let view = BotScreenNativeWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            view.setValue(false, forKey: "drawsBackground")
            webView = view
            view.load(URLRequest(url: Self.pageURL))
            return view
        }

        func configure(id: UUID, url: URL, hasControl: Bool, onEvent: @escaping (BotScreenViewerEvent) -> Void) {
            guard !disposed else { return }
            callback = onEvent
            let changed = self.id != id || socketURL != url
            self.id = id
            socketURL = url
            self.hasControl = hasControl
            if changed {
                timeoutTask?.cancel()
                attemptGeneration = UUID()
                attemptEnded = false
                focusedForControl = false
            }
            if !hasControl { focusedForControl = false }
            guard Self.validSocketURL(url) else {
                failAttempt(id, message: "桌面连接地址无效")
                return
            }
            if changed { startTimeout(id: id) }
            guard !attemptEnded else { return }
            if ready {
                if changed { connect() } else { updateControl() }
            }
        }

        static func validSocketURL(_ url: URL) -> Bool {
            guard ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil else { return false }
            let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? []
            return !names.contains(where: { ["token", "access_token", "refresh_token", "authorization"].contains($0) })
        }

        private func startTimeout(id: UUID) {
            let generation = attemptGeneration
            let duration = handshakeTimeout
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: duration) } catch { return }
                guard let self, !self.disposed, !self.attemptEnded,
                      self.id == id, self.attemptGeneration == generation else { return }
                self.failAttempt(id, message: "桌面连接超时，请重新连接")
            }
        }
        private func cancelTimeout() { timeoutTask?.cancel(); timeoutTask = nil }
        private func failAttempt(_ id: UUID, message: String) {
            guard !disposed, self.id == id, !attemptEnded else { return }
            attemptEnded = true
            cancelTimeout()
            webView?.evaluateJavaScript("window.hermesBotScreen?.dispose()", completionHandler: nil)
            callback?(.failed(id, message: message))
        }
        private func connect() {
            guard !attemptEnded, let id, let socketURL, Self.validSocketURL(socketURL) else { return }
            let data = try? JSONSerialization.data(withJSONObject: ["connectionID": id.uuidString, "websocketURL": socketURL.absoluteString])
            guard let data, let json = String(data: data, encoding: .utf8) else { return }
            evaluate("window.hermesBotScreen.connect(\(json))", attempt: id)
        }
        private func updateControl() {
            guard !attemptEnded, let id else { return }
            // DOM focus alone cannot route native keyboard events after clicking the takeover button.
            // Only focus on acquisition, so later state updates preserve the user's chat focus.
            if hasControl && !focusedForControl, let view = webView, let window = view.window {
                focusedForControl = window.makeFirstResponder(view)
            }
            evaluate("window.hermesBotScreen.setControl('\(id.uuidString)', \(hasControl ? "true" : "false"))", attempt: id)
        }
        private func evaluate(_ script: String, attempt: UUID) {
            let generation = attemptGeneration
            webView?.evaluateJavaScript(script) { [weak self] _, error in
                guard let self, !self.disposed, !self.attemptEnded, self.id == attempt,
                      self.attemptGeneration == generation, error != nil else { return }
                // JavaScript/WebSocket errors may contain the ticket URL. Never surface their raw text.
                self.failAttempt(attempt, message: "桌面显示组件无法连接，请重试")
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !disposed, message.name == "botScreen", message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol == "hermes-botscreen",
                  message.frameInfo.securityOrigin.host == "viewer",
                  message.frameInfo.request.url == Self.pageURL,
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "ready" { ready = true; connect(); return }
            guard !attemptEnded, let id, body["connectionID"] as? String == id.uuidString else { return }
            switch type {
            case "connected": cancelTimeout(); updateControl(); callback?(.connected(id))
            case "disconnected":
                attemptEnded = true
                cancelTimeout()
                callback?(.disconnected(id, clean: body["clean"] as? Bool == true))
            case "failed": failAttempt(id, message: "桌面连接失败，请重新连接")
            default: break
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == Self.pageURL ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failLoad() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failLoad() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failLoad() }
        private func failLoad() {
            guard !disposed, let id else { return }
            failAttempt(id, message: "桌面显示组件加载失败，请重试")
        }
        func dispose() {
            guard !disposed else { return }
            disposed = true
            cancelTimeout()
            callback = nil
            id = nil
            socketURL = nil
            if let webView { Self.disposeWebView(webView) }
            webView = nil
        }
        private static func disposeWebView(_ view: WKWebView) {
            view.evaluateJavaScript("window.hermesBotScreen?.dispose()", completionHandler: nil)
            view.stopLoading()
            view.configuration.userContentController.removeScriptMessageHandler(forName: "botScreen")
            view.navigationDelegate = nil
        }
    }
}

/// Serves only bundled assets, never network resources or arbitrary filesystem paths.
final class BotScreenAssetHandler: NSObject, WKURLSchemeHandler {
    static var resourceRoot: URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "BotScreen", withExtension: nil)
        #else
        return Bundle.main.url(forResource: "BotScreen", withExtension: nil)
        #endif
    }
    static func assetURL(for url: URL) -> URL? {
        guard url.scheme == "hermes-botscreen", url.host == "viewer", url.query == nil,
              url.fragment == nil, url.user == nil, url.password == nil, let root = resourceRoot else { return nil }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." || $0.contains("\\") }) else { return nil }
        let asset = root.appendingPathComponent(components.joined(separator: "/")).standardizedFileURL.resolvingSymlinksInPath()
        guard asset.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else { return nil }
        return asset
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let asset = Self.assetURL(for: url),
              let data = try? Data(contentsOf: asset) else {
            urlSchemeTask.didFailWithError(NSError(domain: "BotScreenAssets", code: 404)); return
        }
        let mime: String
        switch asset.pathExtension {
        case "js": mime = "text/javascript"
        case "css": mime = "text/css"
        case "html": mime = "text/html"
        default: mime = "application/octet-stream"
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/// WebKit retains its message handler; forwarding must not retain the coordinator.
@MainActor private final class WeakBotScreenMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var delegate: (any WKScriptMessageHandler)?

    init(delegate: any WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
