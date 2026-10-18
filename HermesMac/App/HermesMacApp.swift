import SwiftUI
import AppKit
import OSLog

@main struct HermesMacApp: App {
    @AppStorage(ChatTypography.key) private var fontSize = ChatTypography.defaultSize
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: AppStore
    // SwiftUI may recreate the App value; the lock belongs to the process.
    private static let instanceLock: SingleInstanceLock = {
        #if DEBUG
        let identifier = Bundle.main.bundleIdentifier ?? "com.hermes.mac.dev"
        #else
        let identifier = Bundle.main.bundleIdentifier ?? "com.hermes.mac"
        #endif
        do {
            let lock = try SingleInstanceLock(identifier: identifier)
            guard try lock.acquire() else {
                if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                    .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                    // Opening the existing bundle also restores its closed main window.
                    NSWorkspace.shared.open(existing.bundleURL ?? Bundle.main.bundleURL)
                    existing.activate(options: [.activateAllWindows])
                }
                exit(0)
            }
            return lock
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法启动 Hermes"
            alert.informativeText = "无法取得应用实例锁：\(error.localizedDescription)"
            alert.runModal()
            exit(1)
        }
    }()

    init() {
        _ = Self.instanceLock
        _store = State(initialValue: AppStore(onReplyCompleted: { _, profile, text in
            ReplyNotifications.shared.replyCompleted(profile: profile, text: text)
        }))
        #if DEBUG
        // Isolated UI acceptance: no real preferences or Keychain entries are read or changed.
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--bot-screen-fixture"), arguments.indices.contains(flag + 1),
           let url = URL(string: arguments[flag + 1]), url.scheme == "http", url.host == "127.0.0.1",
           let defaults = UserDefaults(suiteName: "HermesMac-UIFixture-\(UUID().uuidString)") {
            let local = LocalState(defaults: defaults)
            local.address = url.absoluteString
            _store = State(initialValue: AppStore(local: local, makeClient: {
                try HermesClient(address: $0, credentials: Credentials(sessionToken: "fixture-token"))
            }))
        }
        #endif
    }

    var body: some Scene {
        Window("Hermes", id: "main") {
            ContentView(store: store).tint(Color.accentColor).frame(minWidth: 800, minHeight: 540)
                .onAppear { delegate.configure(store: store) }
                .task { if !store.connected && !store.connecting { await store.connect() } }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话") { store.newSession() }.keyboardShortcut("n")
            }
            CommandMenu("显示") {
                Button(store.botScreen.isOpen ? "关闭电脑" : "打开电脑") {
                    Task {
                        if store.botScreen.isOpen { await store.botScreen.close() }
                        else { await store.botScreen.open() }
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
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
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("HermesMainWindow")
    private static let logger = Logger(subsystem: "HermesMac", category: "DesktopLifecycle")
    private weak var store: AppStore?
    private var observingWindows = false
    private var terminating = false
    private var terminationReplySent = false
    private var terminationDeadline: Task<Void, Never>?

    func configure(store: AppStore) {
        self.store = store
        guard !observingWindows else { return }
        observingWindows = true
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func mainWindowWillClose(_ notification: Notification) {
        guard !terminating, let closing = notification.object as? NSWindow,
              closing.identifier == Self.mainWindowIdentifier,
              !NSApp.windows.contains(where: {
                  $0 !== closing && $0.identifier == Self.mainWindowIdentifier && ($0.isVisible || $0.isMiniaturized)
              }), let store else { return }
        Task {
            await store.botScreen.close()
            if store.botScreen.error != nil || store.botScreen.notice != nil {
                Self.logger.warning("Desktop control release after the last main window closed may be incomplete.")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.botScreen.isOpen || store.botScreen.hasControl else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        terminationDeadline = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            Self.logger.warning("Desktop control release timed out during application exit; server state may be unknown.")
            finishTermination()
        }
        Task {
            await store.botScreen.close()
            if store.botScreen.error != nil || store.botScreen.notice != nil {
                Self.logger.warning("Desktop control release during application exit may be incomplete.")
            }
            finishTermination()
        }
        return .terminateLater
    }

    private func finishTermination() {
        guard !terminationReplySent else { return }
        terminationReplySent = true
        terminationDeadline?.cancel()
        terminationDeadline = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String ?? "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        ReplyNotifications.shared.start()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
