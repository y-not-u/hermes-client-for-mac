import SwiftUI
struct SettingsView: View {
    var store: AppStore
    @State private var address = ""
    @State private var token = ""
    @State private var message = ""
    @State private var busy = false
    @State private var login: NativeLogin?
    @State private var loginTask: Task<Void, Never>?
    var body: some View {
        Form {
            Section("Hermes 服务") {
                TextField("服务地址", text: $address).textFieldStyle(.roundedBorder)
                Text("本机或局域网 Linux，例如 http://127.0.0.1:9119。服务需手动启动。").font(.caption).foregroundStyle(.secondary)
                SecureField("本机 session token", text: $token).textFieldStyle(.roundedBorder)
                Text("留空会使用 Keychain 中已有凭据。局域网服务请使用下面的官方登录。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("测试连接") { test() }
                    Button("保存并重新连接") { reconnect() }.buttonStyle(.borderedProminent)
                }.disabled(busy)
                HStack {
                    Button("在系统浏览器登录") { signIn() }.disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                    if login != nil { Button("取消登录") { loginTask?.cancel(); login?.cancel() } }
                }
                if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            }
            Section {
                Text("更换服务会断开旧连接并清空运行状态，按服务保存草稿。服务端任务会继续运行。").font(.caption).foregroundStyle(.secondary)
                Text("⌘N 新会话 · ⌘[ / ⌘] 切换角色 · ⇧⌘R 重连").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(12).frame(width: 520, height: 420)
            .onAppear { address = store.address }
            .onDisappear { loginTask?.cancel(); login?.cancel() }
    }
    private func test() {
        busy = true; message = "测试中…"
        Task {
            defer { busy = false }
            do {
                let client = try HermesClient(address: address)
                if !token.isEmpty { try await client.setSessionToken(token, persist: false) }
                let status = try await client.testConnection()
                message = "REST 可用 · Hermes \(status["version"].string) · \(status["auth_required"].bool ? "官方认证" : "本机 token")。保存并连接以测试 WebSocket。"
            } catch { message = error.localizedDescription }
        }
    }
    private func reconnect() {
        busy = true
        Task { await store.connect(address: address, token: token.isEmpty ? nil : token); token = ""; message = store.error ?? "已连接"; busy = false }
    }
    private func signIn() {
        busy = true; message = "请在系统浏览器完成登录…"
        let flow = NativeLogin(); login = flow
        loginTask = Task {
            defer { busy = false; login = nil; loginTask = nil }
            do {
                let client = try HermesClient(address: address); try await flow.signIn(client: client)
                guard !Task.isCancelled else { return }
                await store.connect(address: address); message = store.error ?? "登录成功，已连接"; token = ""
            } catch is CancellationError { message = "登录已取消" }
            catch { message = error.localizedDescription }
        }
    }
}
