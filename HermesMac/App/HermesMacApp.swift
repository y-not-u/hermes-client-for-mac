import SwiftUI
import AppKit

@main struct HermesMacApp: App {
    @AppStorage(ChatTypography.key) private var fontSize = ChatTypography.defaultSize
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore(onReplyCompleted: { _, profile, text in
        ReplyNotifications.shared.replyCompleted(profile: profile, text: text)
    })
    init() {
        NSScroller.enableCleanTrackBackground()
    }

    var body: some Scene {
        WindowGroup("Hermes", id: "main") {
            ContentView(store: store).tint(Color.accentColor).frame(minWidth: 800, minHeight: 540)
                .task { if !store.connected && !store.connecting { await store.connect() } }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话") { store.newSession() }.keyboardShortcut("n")
            }
            CommandMenu("显示") {
                Button("放大字体") { fontSize = Double(ChatTypography.size(fontSize + 0.5)) }
                    .keyboardShortcut("+", modifiers: [.command])
                    .disabled(fontSize >= ChatTypography.range.upperBound)
                Button("缩小字体") { fontSize = Double(ChatTypography.size(fontSize - 0.5)) }
                    .keyboardShortcut("-", modifiers: [.command])
                    .disabled(fontSize <= ChatTypography.range.lowerBound)
                Button("恢复默认字号") { fontSize = ChatTypography.defaultSize }
                    .keyboardShortcut("0", modifiers: [.command])
            }
            CommandMenu("角色") {
                Button("下一个角色") { store.cycleProfile(1) }.keyboardShortcut("]", modifiers: [.command])
                Button("上一个角色") { store.cycleProfile(-1) }.keyboardShortcut("[", modifiers: [.command])
                Divider()
                Button("重新连接") { Task { await store.connect() } }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        Settings { SettingsView(store: store).tint(Color.accentColor) }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        NSScroller.enableCleanTrackBackground()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        ReplyNotifications.shared.start()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSScroller.enableCleanTrackBackground()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
