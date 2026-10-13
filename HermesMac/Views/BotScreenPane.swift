import SwiftUI
import AppKit

/// One native pane and one viewer per open desktop. Expanding keeps the same viewer alive.
struct BotScreenPane: View {
    var store: BotScreenStore
    let profileTitle: String
    @Binding var expanded: Bool
    @State private var confirmReplaceController = false
    @State private var confirmStop = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()

            if let notice = store.notice {
                HStack(alignment: .top, spacing: 8) {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { store.dismissNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("关闭控制权提醒")
                }.padding(12)
            }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }

            desktop
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .alert("接管另一位用户的电脑？", isPresented: $confirmReplaceController) {
            Button("取消", role: .cancel) {}
            Button("确认接管", role: .destructive) { Task { await store.takeOver() } }
        } message: {
            Text("当前桌面由另一位用户控制。接管会结束对方的控制权，并暂停 Agent 对电脑的操作。")
        }
        .alert("停止这台电脑？", isPresented: $confirmStop) {
            Button("取消", role: .cancel) {}
            Button("停止电脑", role: .destructive) { Task { await store.stop() } }
        } message: {
            Text("桌面中的应用会被关闭，未保存的工作可能丢失。关闭面板可以保留电脑运行。")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(profileTitle) 的电脑").font(.headline).lineLimit(1)
                Text("Linux · \(store.profile)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .help(expanded ? "返回聊天与电脑" : "放大电脑")
            .accessibilityLabel(expanded ? "返回聊天与电脑" : "放大电脑")
            Button { Task { await store.close() } } label: {
                Image(systemName: "xmark")
            }
            .help("关闭面板并交还本人的控制权，保留电脑运行")
            .accessibilityLabel("关闭电脑面板")
            .accessibilityIdentifier("botScreen.close")
        }
        .buttonStyle(.borderless)
        .padding(12)
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { powerControl; leaseControl; Spacer(minLength: 0); refreshControl }
            VStack(alignment: .leading, spacing: 8) {
                HStack { powerControl; Spacer(minLength: 0); refreshControl }
                leaseControl
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(12)
    }

    @ViewBuilder private var powerControl: some View {
        if store.status?.running == true {
            Button("停止", systemImage: "stop.fill") { confirmStop = true }
                .disabled(store.busy || !store.connected || (store.humanHasControl && !store.hasControl))
        } else {
            Button("启动电脑", systemImage: "play.fill") { Task { await store.start() } }
                .disabled(store.busy || !store.connected || store.unsupported || store.status?.installed != true || store.status?.supported != true || store.status?.blocker != nil)
                .accessibilityIdentifier("botScreen.start")
        }
    }

    @ViewBuilder private var leaseControl: some View {
        if store.hasControl {
            Button("交还 Agent", systemImage: "arrow.uturn.backward") { Task { await store.handBack() } }
                .disabled(store.busy || !store.connected)
                .accessibilityIdentifier("botScreen.handBack")
                .help("交还后在聊天中让 Agent 继续")
        } else {
            Button("接管", systemImage: "hand.point.up.left") {
                if store.humanHasControl { confirmReplaceController = true }
                else { Task { await store.takeOver() } }
            }
            .disabled(store.busy || !store.viewerConnected || !store.connected)
            .accessibilityIdentifier("botScreen.takeOver")
        }
    }

    private var refreshControl: some View {
        Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
            .disabled(store.busy || !store.connected)
            .help("重新检查电脑状态")
            .accessibilityLabel("刷新电脑状态")
    }

    @ViewBuilder private var desktop: some View {
        if !store.connected {
            emptyState("未连接服务", icon: "network.slash", detail: "连接 Hermes 服务后，即可查看这台电脑。")
        } else if store.unsupported || store.status?.supported == false {
            emptyState("服务不支持电脑", icon: "desktopcomputer.trianglebadge.exclamationmark",
                       detail: "当前服务没有提供 Bot Screen 接口。请在 Linux 主机上更新到支持此功能的 Hermes 服务。")
        } else if let status = store.status, !status.installed {
            ScrollView {
                VStack(spacing: 16) {
                    emptyState("缺少桌面组件", icon: "shippingbox",
                               detail: status.blocker ?? "请在运行 Hermes 的 Linux 主机上安装桌面组件，然后重新检查状态。")
                    if !status.missing.isEmpty {
                        Text("缺少：" + status.missing.joined(separator: "、"))
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let command = status.installCommand, !command.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("在 Linux 主机的终端运行").font(.caption).foregroundStyle(.secondary)
                            Text(command).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Button("复制安装命令", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            }
                        }
                        .padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(20)
            }
        } else if let blocker = store.status?.blocker {
            emptyState("电脑暂时无法启动", icon: "desktopcomputer.trianglebadge.exclamationmark", detail: blocker)
        } else if store.status?.running == false {
            emptyState("电脑已停止", icon: "power", detail: "启动电脑后，可以观看 Agent 操作，也可以随时接管。")
        } else if let viewer = store.viewer {
            ZStack {
                BotScreenWebView(connectionID: viewer.id, websocketURL: viewer.websocketURL,
                                 hasControl: store.hasControl, onEvent: store.handleViewerEvent)
                if !store.viewerConnected {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在连接桌面…").foregroundStyle(.secondary)
                        Button("重试连接") { Task { await store.reconnectViewer() } }
                            .disabled(store.busy)
                    }
                    .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        } else if store.status == nil && store.error != nil {
            VStack(spacing: 12) {
                emptyState("无法检查电脑状态", icon: "exclamationmark.triangle", detail: "请检查服务连接，然后重试。")
                Button("重新检查") { Task { await store.refresh() } }
                    .disabled(store.busy)
            }
        } else if store.busy || store.status == nil {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在检查电脑…").foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 12) {
                emptyState("桌面连接已断开", icon: "wifi.exclamationmark", detail: "重新连接以获取最新桌面画面。")
                Button("重试连接") { Task { await store.reconnectViewer() } }
                    .disabled(store.busy)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(store.viewerConnected ? Color.green : Color.secondary).frame(width: 6, height: 6)
                Text(stateLabel).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if store.busy { ProgressView().controlSize(.mini) }
            }
            if store.hasControl {
                Text("交还后在聊天中让 Agent 继续")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .accessibilityIdentifier("botScreen.status")
    }

    private var stateLabel: String {
        if !store.connected { return "未连接" }
        if store.unsupported || store.status?.supported == false { return "服务不支持" }
        if store.status?.installed == false { return "缺少桌面组件" }
        if store.status?.running == false { return "电脑已停止" }
        if store.hasControl { return "你正在控制 · Agent 已暂停电脑操作" }
        if store.humanHasControl { return "另一位用户正在控制 · 只读观看" }
        if store.viewerConnected { return "实时桌面 · 只读观看" }
        return store.busy ? "正在加载" : "桌面未连接"
    }

    private func emptyState(_ title: String, icon: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 32)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(24).frame(maxWidth: 440)
    }
}
