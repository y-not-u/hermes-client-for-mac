import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case connection = "服务连接"
    case model = "模型设置"
    case appearance = "偏好与显示"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .connection: return "network"
        case .model: return "cpu"
        case .appearance: return "textformat"
        }
    }
}

struct SettingsView: View {
    var store: AppStore
    @AppStorage(ChatTypography.key) private var fontSize = ChatTypography.defaultSize
    @State private var selectedTab: SettingsTab = .connection
    @State private var address = ""
    @State private var busy = false
    @State private var hasSavedCredentials = false
    @State private var testResult: ConnectionTestResult?
    @State private var login: NativeLogin?
    @State private var loginTask: Task<Void, Never>?

    struct ConnectionTestResult: Equatable {
        let success: Bool
        let message: String
        let latencyMs: Int?
        let version: String?
        let authRequired: Bool?
        let suggestion: String?
    }

    private var statusColor: Color {
        if store.connecting { return Color.accentColor }
        if store.connected { return Color.green }
        return Color.orange
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab Selector
            HStack {
                Picker("", selection: $selectedTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                Spacer()

                // Quick Status Indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(store.connecting ? "连接中" : (store.connected ? "已连接" : "未连接"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08), in: Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            // Scrollable Content
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    switch selectedTab {
                    case .connection:
                        connectionTab
                    case .model:
                        modelTab
                    case .appearance:
                        appearanceTab
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 530, height: 570)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            address = store.address
            refreshCredentialsState()
        }
        .onChange(of: address) { _, _ in
            refreshCredentialsState()
        }
        .onDisappear {
            loginTask?.cancel()
            login?.cancel()
        }
    }

    // MARK: - Connection Tab
    private var connectionTab: some View {
        VStack(spacing: 16) {
            // 1. Connection Status Card
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.15))
                        .frame(width: 38, height: 38)

                    if store.connecting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: store.connected ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(statusColor)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(store.connecting ? "正在连接服务…" : (store.connected ? "已连接到 Hermes 服务" : "服务未连接"))
                            .font(.system(size: 13, weight: .semibold))

                        Text(store.connection)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(statusColor.opacity(0.12), in: Capsule())
                    }

                    if store.connected {
                        Text("\(store.address) · 角色: \(store.profileTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let error = store.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("尚未建立实时通信会话，请确认配置后连接。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(statusColor.opacity(store.connected ? 0.25 : 0.12), lineWidth: 1)
            }

            // 2. Server Address Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("服务地址 (Server Address)", systemImage: "network")
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    if address != "http://127.0.0.1:9119" {
                        Button("设为本机默认") {
                            address = "http://127.0.0.1:9119"
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }

                HStack(spacing: 8) {
                    TextField("http://127.0.0.1:9119", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, design: .monospaced))

                    if address != store.address {
                        Button("还原") {
                            address = store.address
                        }
                        .controlSize(.small)
                    }
                }

                Text("本机或局域网 Linux 服务，例如 http://127.0.0.1:9119。服务需在目标机器手动启动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }

            // 3. Authentication Credentials Card
            VStack(alignment: .leading, spacing: 12) {
                Label("身份认证凭据 (Authentication)", systemImage: "lock.shield")
                    .font(.system(size: 13, weight: .semibold))

                // 官方网页授权 (OAuth PKCE)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "safari")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22, height: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("官方账号登录")
                                    .font(.system(size: 12.5, weight: .medium))

                                if hasSavedCredentials {
                                    HStack(spacing: 3) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                        Text("钥匙串已有凭据")
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.12), in: Capsule())
                                }
                            }

                            Text("适用于团队或远程多用户服务。在浏览器授权后自动保存凭证。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        if login != nil {
                            Button("取消") {
                                loginTask?.cancel()
                                login?.cancel()
                            }
                            .controlSize(.small)
                        } else {
                            HStack(spacing: 6) {
                                Button(hasSavedCredentials ? "重新登录" : "在浏览器中登录") {
                                    signIn()
                                }
                                .controlSize(.regular)
                                .disabled(busy)

                                if hasSavedCredentials {
                                    Button("注销", role: .destructive) {
                                        clearCredentials()
                                    }
                                    .controlSize(.regular)
                                    .foregroundStyle(.red)
                                    .help("移除该服务在钥匙串中保存的登录凭据")
                                }
                            }
                        }
                    }

                    if login != nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text("已打开系统浏览器，请在网页中完成授权并允许回调…")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }

            // 4. Action Buttons & Diagnostics
            HStack(spacing: 12) {
                Button {
                    test()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg")
                        Text("测试连接")
                    }
                }
                .disabled(busy)

                Button {
                    reconnect()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(store.connected && store.address == address ? "保存并重新连接" : "保存并连接")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)

                if busy {
                    ProgressView().controlSize(.small)
                        .padding(.leading, 4)
                }

                Spacer()
            }

            // 5. Diagnostics Result Card
            if let result = testResult {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(result.success ? Color.green : Color.orange)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(result.message)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(result.success ? .primary : Color.orange)

                            if let latency = result.latencyMs {
                                Text("\(latency) ms")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.green.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.green)
                            }

                            if let version = result.version {
                                Text("Hermes \(version)")
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let suggestion = result.suggestion {
                            Text(suggestion)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if result.success {
                            Text(result.authRequired == true ? "服务通信正常（需官方认证登录）。点击「保存并连接」即可接入此服务。" : "服务通信正常（免密访问模式）。点击「保存并连接」即可接入此服务。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 4)

                    Button {
                        testResult = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(
                    (result.success ? Color.green : Color.orange).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder((result.success ? Color.green : Color.orange).opacity(0.2), lineWidth: 1)
                }
            }
        }
    }

    // MARK: - Model Tab
    private var modelTab: some View {
        VStack(spacing: 16) {
            modelConfigCard
        }
        .task(id: "\(store.connected)-\(store.selectedProfile)") {
            await store.loadModelSettings()
        }
    }

    private var mainModelChoice: ModelChoice? {
        guard let catalog = store.modelSettingsCatalog, !catalog.model.isEmpty else { return nil }
        return ModelChoice(provider: catalog.provider, model: catalog.model)
    }

    private var modelConfigCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("模型配置", systemImage: "cpu")
                .font(.system(size: 13, weight: .semibold))

            Text("主模型是服务端全局默认；fallback 链按顺序在主模型失败时自动接管。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            modelRow(value: mainModelChoice)
            Divider()
            fallbackSection

            if let error = store.modelSettingsError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func modelRow(value: ModelChoice?) -> some View {
        let providers = store.modelSettingsCatalog?.providers ?? []
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("主模型")
                    .font(.system(size: 12.5, weight: .medium))
                Text(value.map { "\($0.model) · \($0.provider)" } ?? (store.modelSettingsLoading ? "加载中…" : "未知"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                ForEach(providers) { provider in
                    Menu(provider.name) {
                        ForEach(provider.choices) { choice in
                            Button {
                                Task { await store.setMainModel(choice) }
                            } label: {
                                if choice == value { Label(choice.model, systemImage: "checkmark") }
                                else { Text(choice.model) }
                            }
                            .disabled(provider.unavailable.contains(choice.model))
                        }
                    }
                }
                if providers.isEmpty { Text("暂无可用模型") }
            } label: {
                HStack(spacing: 5) {
                    if store.mainModelSaving {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    Text(value.map(\.model) ?? "选择…").lineLimit(1)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.1), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!store.connected || store.modelSettingsLoading || store.mainModelSaving)
            .help("设置主模型")
        }
    }

    private var fallbackSection: some View {
        let providers = store.modelSettingsCatalog?.providers ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fallback 链")
                    .font(.system(size: 12.5, weight: .medium))
                Text(store.fallbackChain.isEmpty ? "未设置（主模型失败时不切换）" : "按顺序尝试，共 \(store.fallbackChain.count) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(providers) { provider in
                        Menu(provider.name) {
                            ForEach(provider.choices) { choice in
                                Button {
                                    Task { await store.addFallback(choice) }
                                } label: {
                                    Text(choice.model)
                                }
                                .disabled(provider.unavailable.contains(choice.model) || store.fallbackChain.contains(choice))
                            }
                        }
                    }
                    if providers.isEmpty { Text("暂无可用模型") }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                        Text("添加")
                    }
                    .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!store.connected || store.modelSettingsLoading || store.fallbackSaving)
                .help("添加一个 fallback 模型")
            }

            ForEach(Array(store.fallbackChain.enumerated()), id: \.element.id) { index, choice in
                HStack(spacing: 6) {
                    Text("\(index + 1).")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("\(choice.model) · \(choice.provider)")
                        .font(.system(size: 12))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button {
                        Task { await store.moveFallback(from: index, to: index - 1) }
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0 || store.fallbackSaving)
                    .help("上移")
                    Button {
                        Task { await store.moveFallback(from: index, to: index + 1) }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == store.fallbackChain.count - 1 || store.fallbackSaving)
                    .help("下移")
                    Button {
                        Task { await store.removeFallback(at: index) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.fallbackSaving)
                    .help("移除")
                }
            }

            if store.fallbackSaving { ProgressView().controlSize(.mini) }
        }
    }

    // MARK: - Appearance Tab
    private var appearanceTab: some View {
        VStack(spacing: 16) {
            // 文字显示
            VStack(alignment: .leading, spacing: 12) {
                Label("文字显示", systemImage: "textformat.size")
                    .font(.system(size: 13, weight: .semibold))

                HStack(spacing: 12) {
                    Text("聊天字号")
                        .font(.system(size: 13))

                    Slider(value: $fontSize, in: ChatTypography.range, step: 0.5)
                        .accessibilityLabel("聊天字号")

                    Text("\(ChatTypography.size(fontSize), specifier: "%.1f") pt")
                        .monospacedDigit()
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 58, alignment: .trailing)
                }

                // 预览效果
                VStack(alignment: .leading, spacing: 6) {
                    Text("排版预览：")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("你好，Hermes！这是一段消息字号预览效果。")
                        .font(.system(size: ChatTypography.size(fontSize)))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                        }
                }

                HStack {
                    Text("即时应用于会话列表、消息、代码块和输入框，并自动保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("恢复默认字号") {
                        fontSize = ChatTypography.defaultSize
                    }
                    .disabled(fontSize == ChatTypography.defaultSize)
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }

            // 快捷键指南
            VStack(alignment: .leading, spacing: 12) {
                Label("快捷键指南", systemImage: "command")
                    .font(.system(size: 13, weight: .semibold))

                VStack(spacing: 8) {
                    shortcutRow(keys: ["⌘N"], title: "新建会话", desc: "在当前角色下开启全新对话")
                    shortcutRow(keys: ["⌘[", "⌘]"], title: "切换角色", desc: "快速在上一个 / 下一个角色间切换")
                    shortcutRow(keys: ["⇧⌘R"], title: "重新连接", desc: "强制重连当前配置的 Hermes 服务")
                    shortcutRow(keys: ["⌘+", "⌘-", "⌘0"], title: "缩放字号", desc: "快捷放大、缩小或重置字号")
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }

            // 说明提示
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)

                Text("更换服务会断开旧连接并清空运行状态，按服务独立保存草稿。服务端任务在客户端退出后会继续运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func shortcutRow(keys: [String], title: String, desc: String) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    KeyCap(key)
                }
            }
            .frame(width: 80, alignment: .leading)

            Text(title)
                .font(.system(size: 12, weight: .medium))

            Spacer()

            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions
    private func refreshCredentialsState() {
        let target = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            hasSavedCredentials = false
            return
        }
        Task {
            let creds = try? Keychain.load(service: target)
            let exists = (creds.map { !$0.sessionToken.isEmpty || !$0.accessToken.isEmpty }) ?? false
            await MainActor.run {
                self.hasSavedCredentials = exists
            }
        }
    }

    private func clearCredentials() {
        let target = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        Task {
            try? Keychain.save(Credentials(), service: target)
            refreshCredentialsState()
            testResult = ConnectionTestResult(
                success: true,
                message: "已移除登录凭据",
                latencyMs: nil,
                version: nil,
                authRequired: nil,
                suggestion: "已移除该服务保存在钥匙串中的 Token 与登录信息。"
            )
        }
    }

    private func test() {
        busy = true
        testResult = nil
        let targetAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { busy = false }
            do {
                let start = Date()
                let client = try HermesClient(address: targetAddress)
                let status = try await client.testConnection()
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                let version = status["version"].string
                let authRequired = status["auth_required"].bool
                testResult = ConnectionTestResult(
                    success: true,
                    message: "服务正常响应",
                    latencyMs: elapsed,
                    version: version.isEmpty ? nil : version,
                    authRequired: authRequired,
                    suggestion: nil
                )
            } catch {
                let desc = error.localizedDescription
                var suggestion = "请检查服务地址、端口以及网络连通性。"
                if desc.contains("cannotConnectToHost") || desc.contains("refused") {
                    suggestion = "目标服务未运行或端口未开放（默认 9119）。请在目标机器运行 hermes start 或确认端口无误。"
                } else if desc.contains("timedOut") {
                    suggestion = "网络连接超时。请检查目标 IP 地址是否正确，以及局域网防火墙是否放行该端口。"
                } else if desc.contains("401") || desc.contains("403") {
                    suggestion = "服务需要认证（401/403）。请使用官方网页登录。"
                }
                testResult = ConnectionTestResult(
                    success: false,
                    message: "连接失败",
                    latencyMs: nil,
                    version: nil,
                    authRequired: nil,
                    suggestion: suggestion + " (\(desc))"
                )
            }
        }
    }

    private func reconnect() {
        busy = true
        testResult = nil
        let targetAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await store.connect(address: targetAddress)
            if store.connected {
                refreshCredentialsState()
            }
            busy = false
            if let err = store.error {
                testResult = ConnectionTestResult(
                    success: false,
                    message: "连接失败",
                    latencyMs: nil,
                    version: nil,
                    authRequired: nil,
                    suggestion: err
                )
            } else {
                testResult = ConnectionTestResult(
                    success: true,
                    message: "已成功接入服务",
                    latencyMs: nil,
                    version: nil,
                    authRequired: nil,
                    suggestion: "WebSocket 实时会话与数据同步已建立。"
                )
            }
        }
    }

    private func signIn() {
        busy = true
        testResult = nil
        let targetAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let flow = NativeLogin()
        login = flow
        loginTask = Task {
            defer {
                busy = false
                login = nil
                loginTask = nil
            }
            do {
                let client = try HermesClient(address: targetAddress)
                try await flow.signIn(client: client)
                guard !Task.isCancelled else { return }
                await store.connect(address: targetAddress)
                refreshCredentialsState()
                if store.connected {
                    testResult = ConnectionTestResult(
                        success: true,
                        message: "登录成功，已连接",
                        latencyMs: nil,
                        version: nil,
                        authRequired: nil,
                        suggestion: "认证凭据已安全保存至 Keychain。"
                    )
                } else if let err = store.error {
                    testResult = ConnectionTestResult(
                        success: false,
                        message: "登录成功但连接异常",
                        latencyMs: nil,
                        version: nil,
                        authRequired: nil,
                        suggestion: err
                    )
                }
            } catch is CancellationError {
                testResult = ConnectionTestResult(
                    success: false,
                    message: "登录已取消",
                    latencyMs: nil,
                    version: nil,
                    authRequired: nil,
                    suggestion: "已中止浏览器授权流程。"
                )
            } catch {
                testResult = ConnectionTestResult(
                    success: false,
                    message: "登录失败",
                    latencyMs: nil,
                    version: nil,
                    authRequired: nil,
                    suggestion: error.localizedDescription
                )
            }
        }
    }
}
