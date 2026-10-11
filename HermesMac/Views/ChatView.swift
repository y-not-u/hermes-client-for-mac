import SwiftUI
struct ChatView: View {
    var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.profileTitle).font(.headline)
                    HStack(spacing: 5) { Circle().fill(store.connected ? Color.green : Color.orange).frame(width: 6, height: 6); Text(store.connection).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if store.connecting { ProgressView().controlSize(.small) }
                SettingsLink { Label("连接设置", systemImage: "slider.horizontal.3") }.labelStyle(.iconOnly).buttonStyle(.borderless)
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            if let error = store.error { banner(error, color: .orange) }
            if let c = store.current {
                conversation(c)
            } else {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                    Text(store.selectedProfile.isEmpty ? "连接你的 Hermes 服务" : "与 \(store.profileTitle) 开始新会话").font(.title2)
                    Text(store.selectedProfile.isEmpty ? "在设置中填写服务地址与认证信息" : "配置和记忆由服务端 profile 管理").foregroundStyle(.secondary)
                    if !store.connected { SettingsLink { Text("打开连接设置") }.buttonStyle(.borderedProminent) }
                }.padding(24)
                Spacer()
            }
            ComposerView(store: store)
        }
    }
    private func banner(_ text: String, color: Color) -> some View {
        Text(text).font(.caption).foregroundStyle(color).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(color.opacity(0.06))
    }
    @ViewBuilder private func conversation(_ c: Conversation) -> some View {
        if let reason = c.readOnlyReason {
            HStack { Text(reason).font(.caption).textSelection(.enabled); Spacer(); Button("重试恢复") { Task { await store.retryResume() } } }.padding(12).background(.orange.opacity(0.08))
        }
        if c.uncertain {
            HStack { Text("状态待确认，请查询服务端后再发送。").font(.caption); Spacer(); Button("查询状态") { Task { await store.retryResume() } }.disabled(!store.connected) }.padding(12)
        }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if c.hasOlder { Button("加载更早消息") { Task { await store.loadOlder(c) } }.disabled(c.loading) }
                    if c.loading { ProgressView().frame(maxWidth: .infinity) }
                    ForEach(c.messages) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message.role == "user" ? "你" : message.role == "tool" ? "工具" : store.profileTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            MarkdownView(text: message.text)
                        }.padding(message.role == "user" ? 14 : 0).frame(maxWidth: .infinity, alignment: .leading)
                            .background(message.role == "user" ? Color.secondary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 12)).id(message.id)
                    }
                    ForEach(c.tools) { tool in
                        DisclosureGroup {
                            ScrollView(.horizontal) { Text(tool.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        } label: { Label(tool.name, systemImage: tool.complete ? "checkmark.circle" : "gearshape.2").font(.caption).foregroundStyle(.secondary) }
                    }
                    ForEach(c.approvals) { approval in ApprovalCard(approval: approval, conversation: c, store: store) }
                    if let error = c.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    if c.generating { HStack { ProgressView().controlSize(.small); Text("正在生成…").font(.caption).foregroundStyle(.secondary) } }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(24).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }
            .onChange(of: c.messages.count) { _, _ in if c.generating { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: c.approvals.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}
struct ApprovalCard: View {
    let approval: Approval
    let conversation: Conversation
    var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("等待你的审批", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(.orange)
            Text(approval.params["description"].string).textSelection(.enabled)
            if !approval.params["command"].string.isEmpty { Text(approval.params["command"].string).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            HStack {
                Button("拒绝", role: .destructive) { answer("deny") }
                if approval.params["choices"].array.contains(.string("once")) { Button("允许一次") { answer("once") }.buttonStyle(.borderedProminent) }
                if approval.params["choices"].array.contains(.string("session")) { Button("此会话允许") { answer("session") } }
            }.disabled(!store.connected || conversation.uncertain)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    private func answer(_ choice: String) { Task { await store.approve(approval, conversation: conversation, choice: choice) } }
}
