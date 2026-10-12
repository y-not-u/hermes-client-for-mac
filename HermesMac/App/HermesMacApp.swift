import SwiftUI
import AppKit

@main struct HermesMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()
    init() {
        NSScroller.enableCleanTrackBackground()
    }

    var body: some Scene {
        WindowGroup("Hermes", id: "main") {
            ContentView(store: store).frame(minWidth: 800, minHeight: 540)
                .task { if !store.connected && !store.connecting { await store.connect() } }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话") { store.newSession() }.keyboardShortcut("n")
            }
            CommandMenu("角色") {
                Button("下一个角色") { store.cycleProfile(1) }.keyboardShortcut("]", modifiers: [.command])
                Button("上一个角色") { store.cycleProfile(-1) }.keyboardShortcut("[", modifiers: [.command])
                Divider()
                Button("重新连接") { Task { await store.connect() } }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        Settings { SettingsView(store: store) }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        NSScroller.enableCleanTrackBackground()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSScroller.enableCleanTrackBackground()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
