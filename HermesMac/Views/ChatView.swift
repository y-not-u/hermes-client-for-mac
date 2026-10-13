import SwiftUI
import AppKit

struct ChatView: View {
    var store: AppStore
    @State private var imagePreview: ImagePreview?
    @State private var pendingInitialScroll: ConversationKey?
    @State private var isAtBottom = true
    @State private var isBottomButtonHovered = false

    private var currentSessionTitle: String {
        if let selected = store.selectedSession,
           let match = store.sessions[store.selectedProfile]?.first(where: { $0.id == selected }) {
            return match.title
        }
        return store.selectedProfile.isEmpty ? "Hermes" : "新会话"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Minimal Assistant Header (matching Image 2)
            HStack {
                Spacer()
                VStack(spacing: 3) {
                    ProfileAvatar(
                        name: store.selectedProfile,
                        displayName: store.profileTitle,
                        size: 26,
                        cornerRadius: 8
                    )
                    Text(store.profileTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                Spacer()
            }
            .padding(.top, 14)
            .padding(.bottom, 6)

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
        .sheet(item: $imagePreview) { preview in
            ImagePreviewView(file: preview.file, filename: preview.filename)
        }
    }

    private func transcriptRows(_ conversation: Conversation) -> [TranscriptRow] {
        let entries = conversation.entries
        var rows: [TranscriptRow] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            switch entry {
            case .message(let message):
                rows.append(TranscriptRow(id: entry.id, message: message, tools: []))
            case .tools(let activity):
                var reply = Message(id: activity.id, role: "assistant", text: "")
                if index + 1 < entries.count,
                   case .message(let message) = entries[index + 1], message.role == "assistant" {
                    reply = message
                    index += 1
                }
                rows.append(TranscriptRow(id: entry.id, message: reply, tools: activity.tools))
            }
            index += 1
        }
        return rows
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

            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        // Rows change height when media loads. A lazy stack combined
                        // with bottom anchoring can repeatedly revise its estimated
                        // heights on macOS 15 and starve the main actor (including
                        // the image-loading tasks). History is paged, so measure the
                        // loaded rows directly instead.
                        VStack(alignment: .leading, spacing: 20) {
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

                            ForEach(transcriptRows(c)) { row in
                                MessageRowView(
                                    message: row.message,
                                    profileName: store.selectedProfile,
                                    profileTitle: store.profileTitle,
                                    tools: row.tools,
                                    isRunning: c.generating,
                                    conversation: c.key,
                                    store: store,
                                    previewImage: { file, filename in imagePreview = ImagePreview(file: file, filename: filename) }
                                )
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

                            Color.clear.frame(height: 21)
                                .id("bottom")
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: ConversationBottomPreferenceKey.self,
                                            value: geometry.frame(in: .named("conversationScroll")).maxY
                                        )
                                    }
                                }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                        .frame(maxWidth: 860)
                        .frame(maxWidth: .infinity)
                    }
                    .coordinateSpace(name: "conversationScroll")
                    .onPreferenceChange(ConversationBottomPreferenceKey.self) { bottom in
                        // The bottom marker includes the transcript's trailing spacing.
                        isAtBottom = bottom <= viewport.size.height + 4
                    }
                    .defaultScrollAnchor(.bottom)
                    .cleanScrollBars()
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
                    .overlay(alignment: .bottom) {
                        if !isAtBottom {
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 32, height: 32)
                                    .background(.regularMaterial, in: Circle())
                                    .overlay(Circle().strokeBorder(Color.secondary.opacity(0.2)))
                                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("滚动到底部")
                            .help("滚动到底部")
                            .onHover { hovered in
                                guard hovered != isBottomButtonHovered else { return }
                                isBottomButtonHovered = hovered
                                if hovered { NSCursor.pointingHand.push() }
                                else { NSCursor.pop() }
                            }
                            .onDisappear {
                                if isBottomButtonHovered {
                                    NSCursor.pop()
                                    isBottomButtonHovered = false
                                }
                            }
                            .padding(16)
                        }
                    }
                    .onChange(of: c.key, initial: true) { _, key in
                        isAtBottom = true
                        pendingInitialScroll = c.loading ? key : nil
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onChange(of: c.loading) { _, loading in
                        // Only finish the opening scroll; paging older history must
                        // leave the reader at their current position.
                        if !loading && pendingInitialScroll == c.key {
                            pendingInitialScroll = nil
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: c.lastSubmittedMessageID) { _, _ in
                        // Sending resumes following the conversation even when
                        // the reader has scrolled up into earlier messages.
                        isAtBottom = true
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onChange(of: c.messages.count) { _, _ in
                        if isAtBottom && c.generating && !c.loading && imagePreview == nil {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: c.tools.count) { _, _ in
                        if isAtBottom && !c.loading && imagePreview == nil {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: c.messages.last?.text) { _, _ in
                        if isAtBottom && c.generating && !c.loading && imagePreview == nil { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: c.generating) { _, running in
                        if isAtBottom && !running && !c.loading && imagePreview == nil { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: c.approvals.count) { _, _ in
                        if isAtBottom && !c.loading && imagePreview == nil { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            .id(c.key)
        }
    }
}

private struct ConversationBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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

private struct TranscriptRow: Identifiable {
    let id: String
    let message: Message
    let tools: [ToolCall]
}

private struct MessageRowView: View {
    let message: Message
    let profileName: String
    let profileTitle: String
    var tools: [ToolCall] = []
    var isRunning = false
    let conversation: ConversationKey
    let store: AppStore
    let previewImage: (RemoteImageFile, String) -> Void

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

                    if let status = message.deliveryStatus {
                        Text(status)
                            .font(.system(size: 10))
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

                        if !message.text.isEmpty {
                            CopyButton(text: message.text, labelText: "复制回答")
                                .opacity(isHovered ? 1 : 0)
                                .allowsHitTesting(isHovered)
                                .accessibilityHidden(!isHovered)
                        }
                    }

                    if !tools.isEmpty {
                        ToolCallGroup(tools: tools, isRunning: isRunning)
                            .padding(.vertical, 4)
                    }

                    if !message.text.isEmpty {
                        MarkdownView(text: message.text, media: MediaPresentation(
                            conversation: conversation, messageID: message.id, store: store, preview: previewImage
                        ))
                    }
                }
            }
            .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Tool Calls

private struct ToolCallGroup: View {
    let tools: [ToolCall]
    var isRunning = false

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            if let latest = tools.last {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: latest.complete ? "checkmark.circle.fill" : "gearshape.2.fill")
                            .foregroundStyle(latest.complete ? Color.accentColor : Color.orange)
                        Text(latest.name)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                        Text(latest.complete ? "执行完成" : "执行中…")
                            .font(.system(size: 10))
                            .foregroundStyle(latest.complete ? Color.accentColor : Color.orange)
                        Spacer(minLength: 8)
                        Text("\(tools.count) 次工具调用")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "收起工具调用列表" : "展开工具调用列表")
                .accessibilityValue(isExpanded ? "已展开" : "已收起")
            }

            if isExpanded {
                Divider().opacity(0.4)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(tools) { tool in
                                ToolCallRow(title: tool.name, isComplete: tool.complete, details: tool.details)
                                    .id(tool.id)
                                if tool.id != tools.last?.id {
                                    Divider().opacity(0.4).padding(.horizontal, 12)
                                }
                            }
                        }
                    }
                    .cleanScrollBars()
                    .frame(maxHeight: 240)
                    .onAppear { scrollToLatest(proxy) }
                    .onChange(of: tools.last?.id) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) { scrollToLatest(proxy) }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.8)
        }
        .onChange(of: isRunning) { _, running in
            if !running {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded = false }
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        if let latest = tools.last { proxy.scrollTo(latest.id, anchor: .bottom) }
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
                        .foregroundStyle(isComplete ? Color.accentColor : Color.orange)

                    Text(title)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)

                    Text(isComplete ? "执行完成" : "执行中…")
                        .font(.system(size: 10))
                        .foregroundStyle(isComplete ? Color.accentColor : Color.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background((isComplete ? Color.accentColor : Color.orange).opacity(0.1), in: Capsule())

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
                    .cleanScrollBars()
                    .environment(\.colorScheme, .dark)
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
                    .cleanScrollBars()
                    .environment(\.colorScheme, .dark)
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
