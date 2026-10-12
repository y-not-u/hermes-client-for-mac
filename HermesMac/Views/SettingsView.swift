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
            // Header
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [Color.accentColor, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "sparkles")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hermes 服务连接")
                            .font(.system(size: 15, weight: .bold))
                        HStack(spacing: 6) {
                            ConnectionStatusBadge(connected: store.connected, connecting: store.connecting, text: store.connection)
                            if !store.selectedProfile.isEmpty {
                                Text("· 当前角色: \(store.profileTitle)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("服务配置") {
                TextField("服务地址", text: $address)
                    .textFieldStyle(.roundedBorder)

                Text("本机或局域网 Linux 服务，例如 http://127.0.0.1:9119。服务需手动启动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SecureField("本机 session token", text: $token)
                    .textFieldStyle(.roundedBorder)

                Text("留空会使用 Keychain 中已有凭据。局域网或多用户服务请使用下面的官方登录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("连接操作") {
                HStack(spacing: 12) {
                    Button("测试连接") { test() }
                        .disabled(busy)

                    Button("保存并重新连接") { reconnect() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)

                    Spacer()

                    if busy {
                        ProgressView().controlSize(.small)
                    }
                }

                HStack(spacing: 12) {
                    Button("在系统浏览器登录") { signIn() }
                        .disabled(busy)

                    if login != nil {
                        Button("取消登录") {
                            loginTask?.cancel()
                            login?.cancel()
                        }
                    }
                }

                if !message.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: message.contains("失败") || message.contains("错误") ? "xmark.circle.fill" : "info.circle.fill")
                            .foregroundStyle(message.contains("失败") || message.contains("错误") ? Color.orange : Color.accentColor)
                        Text(message)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .background(
                        (message.contains("失败") || message.contains("错误") ? Color.orange : Color.accentColor).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
            }

            Section("快捷键与说明") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        KeyCap("⌘N")
                        Text("新建会话").font(.caption).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        KeyCap("⌘[")
                        KeyCap("⌘]")
                        Text("切换角色").font(.caption).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        KeyCap("⇧⌘R")
                        Text("重连").font(.caption).foregroundStyle(.secondary)
                    }

                    Text("更换服务会断开旧连接并清空运行状态，按服务独立保存草稿。服务端任务会继续运行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 530, height: 490)
        .onAppear { address = store.address }
        .onDisappear {
            loginTask?.cancel()
            login?.cancel()
        }
    }

    private func test() {
        busy = true
        message = "测试中…"
        Task {
            defer { busy = false }
            do {
                let client = try HermesClient(address: address)
                if !token.isEmpty { try await client.setSessionToken(token, persist: false) }
                let status = try await client.testConnection()
                message = "REST 可用 · Hermes \(status["version"].string) · \(status["auth_required"].bool ? "官方认证" : "本机 token")。保存并连接以测试 WebSocket。"
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func reconnect() {
        busy = true
        Task {
            await store.connect(address: address, token: token.isEmpty ? nil : token)
            if store.connected { token = "" }
            message = store.error ?? "已连接"
            busy = false
        }
    }

    private func signIn() {
        busy = true
        message = "请在系统浏览器完成登录…"
        let flow = NativeLogin()
        login = flow
        loginTask = Task {
            defer {
                busy = false
                login = nil
                loginTask = nil
            }
            do {
                let client = try HermesClient(address: address)
                try await flow.signIn(client: client)
                guard !Task.isCancelled else { return }
                await store.connect(address: address)
                message = store.error ?? "登录成功，已连接"
                token = ""
            } catch is CancellationError {
                message = "登录已取消"
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
