import SwiftUI

struct ChatView: View {
    var store: AppStore

    private var currentSessionTitle: String {
        if let selected = store.selectedSession,
           let match = store.sessions[store.selectedProfile]?.first(where: { $0.id == selected }) {
            return match.title
        }
        return store.selectedProfile.isEmpty ? "Hermes" : "新会话"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Modern Header
            HStack(spacing: 12) {
                ProfileAvatar(
                    name: store.selectedProfile,
                    displayName: store.profileTitle,
                    size: 32,
                    cornerRadius: 9
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(currentSessionTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)

                        Text(store.profileTitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.secondary.opacity(0.08), in: Capsule())
                    }

                    HStack(spacing: 6) {
                        ConnectionStatusBadge(
                            connected: store.connected,
                            connecting: store.connecting,
                            text: store.connection
                        )

                        if let c = store.current, c.generating {
                            Text("· 正在生成")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    Button {
                        store.newSession()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text("新会话")
                                .font(.system(size: 12))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4.5)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("新会话 · ⌘N")

                    SettingsLink {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 12))
                            .frame(width: 26, height: 26)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("连接设置")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.7))

            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.4))
                .frame(height: 1)

            // Alert Banners
            if let error = store.error {
                BannerCallout(icon: "exclamationmark.triangle.fill", text: error, color: .orange)
            }

            // Main Conversation or Empty State
            if let c = store.current, (!c.messages.isEmpty || !c.tools.isEmpty || c.generating || c.loading || c.hasOlder || c.readOnlyReason != nil || c.error != nil) {
                conversationView(c)
            } else {
                emptyStateView
            }

            // Bottom Input
            ComposerView(store: store)
        }
    }

    // MARK: - Empty State / Hero Welcome
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 12) {
                ProfileAvatar(
                    name: store.selectedProfile,
                    displayName: store.profileTitle,
                    size: 54,
                    cornerRadius: 15
                )

                Text(store.selectedProfile.isEmpty ? "连接你的 Hermes 服务" : "与 \(store.profileTitle) 开始对话")
                    .font(.system(size: 20, weight: .bold))

                Text(store.selectedProfile.isEmpty ? "在设置中填写服务地址与认证信息以开启体验" : "配置和记忆由服务端 profile 统一管理 · 随时发起提问或运行任务")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                if !store.connected {
                    SettingsLink {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                            Text("打开连接设置")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, 4)
                }
            }

            if store.connected && !store.selectedProfile.isEmpty {
                VStack(spacing: 8) {
                    Text("快捷指令建议")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 10) {
                        SuggestionCard(
                            icon: "bubble.left.and.exclamationmark.bubble.right",
                            title: "/status",
                            subtitle: "查看当前会话状态"
                        ) {
                            store.draft = "/status"
                            store.submitDraft()
                        }

                        SuggestionCard(
                            icon: "cpu",
                            title: "/model",
                            subtitle: "查看当前可用模型"
                        ) {
                            store.draft = "/model"
                            store.submitDraft()
                        }
                    }
                    .frame(maxWidth: 500)

                    HStack(spacing: 10) {
                        SuggestionCard(
                            icon: "person.crop.circle",
                            title: "/profile",
                            subtitle: "查看当前角色配置"
                        ) {
                            store.draft = "/profile"
                            store.submitDraft()
                        }

                        SuggestionCard(
                            icon: "network",
                            title: "网关状态",
                            subtitle: "查看服务连接信息"
                        ) {
                            store.draft = "如何查看当前 hermes 的连接信息"
                            store.submitDraft()
                        }
                    }
                    .frame(maxWidth: 500)
                }
                .padding(.top, 8)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Conversation View
    @ViewBuilder
    private func conversationView(_ c: Conversation) -> some View {
        VStack(spacing: 0) {
            if let reason = c.readOnlyReason {
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)

                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)

                    Spacer()

                    Button("重试恢复") {
                        Task { await store.retryResume() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }

            if c.uncertain {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)

                    Text("状态待确认，请查询服务端后再发送。")
                        .font(.system(size: 12))

                    Spacer()

                    Button("查询状态") {
                        Task { await store.retryResume() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!store.connected)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if c.hasOlder {
                            HStack {
                                Spacer()
                                Button("加载更早消息") {
                                    Task { await store.loadOlder(c) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(c.loading)
                                Spacer()
                            }
                            .padding(.top, 8)
                        }

                        ForEach(c.messages) { message in
                            MessageRowView(
                                message: message,
                                profileName: store.selectedProfile,
                                profileTitle: store.profileTitle
                            )
                            .id(message.id)
                        }

                        if !c.tools.isEmpty {
                            ToolCallGroup(tools: c.tools)
                        }

                        ForEach(c.approvals) { approval in
                            ApprovalCard(approval: approval, conversation: c, store: store)
                        }

                        if let error = c.error {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                                Text(error)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        if c.generating {
                            HStack(spacing: 10) {
                                ProfileAvatar(
                                    name: store.selectedProfile,
                                    displayName: store.profileTitle,
                                    size: 24,
                                    cornerRadius: 7
                                )

                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("正在生成回复…")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.06), in: Capsule())
                            }
                        }

                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .overlay(alignment: .top) {
                    if c.loading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: c.messages.count) { _, _ in
                    if c.generating && !c.loading {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: c.approvals.count) { _, _ in
                    if !c.loading { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }
}

// MARK: - Banner Callout

private struct BannerCallout: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .textSelection(.enabled)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

// MARK: - Message Row View

private struct MessageRowView: View {
    let message: Message
    let profileName: String
    let profileTitle: String

    @State private var isHovered = false

    var body: some View {
        if message.role == "tool" {
            ToolCallGroup(tools: [ToolCall(id: message.id, name: "工具返回", details: message.text, complete: true)])
        } else if message.role == "user" {
            // User Message: Right Aligned Bubble
            HStack {
                Spacer(minLength: 60)

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        CopyButton(text: message.text, labelText: "复制")
                            .opacity(isHovered ? 1 : 0)
                            .allowsHitTesting(isHovered)
                            .accessibilityHidden(!isHovered)
                        Text("你")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    MarkdownView(text: message.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 0.8)
                        }
                }
            }
            .onHover { isHovered = $0 }
        } else {
            // Assistant Message: Left Aligned with Avatar
            HStack(alignment: .top, spacing: 10) {
                ProfileAvatar(
                    name: profileName,
                    displayName: profileTitle,
                    size: 28,
                    cornerRadius: 8
                )
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(profileTitle)
                            .font(.system(size: 13, weight: .semibold))

                        Text("AI 助手")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.secondary.opacity(0.08), in: Capsule())

                        Spacer()

                        CopyButton(text: message.text, labelText: "复制回答")
                            .opacity(isHovered ? 1 : 0)
                            .allowsHitTesting(isHovered)
                            .accessibilityHidden(!isHovered)
                    }

                    MarkdownView(text: message.text)
                }
            }
            .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Tool Calls

private struct ToolCallGroup: View {
    let tools: [ToolCall]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(tools) { tool in
                if tool.id != tools.first?.id {
                    Divider()
                        .opacity(0.4)
                        .padding(.horizontal, 12)
                }

                ToolCallRow(title: tool.name, isComplete: tool.complete, details: tool.details)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.8)
        }
    }
}

private struct ToolCallRow: View {
    let title: String
    let isComplete: Bool
    let details: String

    @State private var isExpanded = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isComplete ? "checkmark.circle.fill" : "gearshape.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(isComplete ? Color.green : Color.orange)

                    Text(title)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)

                    Text(isComplete ? "执行完成" : "执行中…")
                        .font(.system(size: 10))
                        .foregroundStyle(isComplete ? Color.green : Color.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background((isComplete ? Color.green : Color.orange).opacity(0.1), in: Capsule())

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isHovered ? Color.secondary.opacity(0.06) : Color.clear)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.3))
                        .frame(height: 1)

                    HStack {
                        Spacer()
                        CopyButton(text: details, labelText: "复制日志", isDark: true)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 4)

                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(details)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Color(red: 0.85, green: 0.88, blue: 0.92))
                            .padding(10)
                            .textSelection(.enabled)
                    }
                    .background(Color(red: 0.12, green: 0.13, blue: 0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(8)
                }
            }
        }
    }
}

// MARK: - Approval Card

struct ApprovalCard: View {
    let approval: Approval
    let conversation: Conversation
    var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)

                Text("等待你的安全审批")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            Text(approval.params["description"].string)
                .font(.system(size: 13))
                .textSelection(.enabled)

            if !approval.params["command"].string.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("待执行命令：")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(approval.params["command"].string)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color(red: 0.92, green: 0.94, blue: 0.96))
                            .padding(8)
                            .textSelection(.enabled)
                    }
                    .background(Color(red: 0.12, green: 0.13, blue: 0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            HStack(spacing: 10) {
                Button("拒绝", role: .destructive) {
                    answer("deny")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                if approval.params["choices"].array.contains(.string("session")) {
                    Button("此会话允许") {
                        answer("session")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if approval.params["choices"].array.contains(.string("once")) {
                    Button("允许一次") {
                        answer("once")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                }
            }
            .disabled(!store.connected || conversation.uncertain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }

    private func answer(_ choice: String) {
        Task { await store.approve(approval, conversation: conversation, choice: choice) }
    }
}
