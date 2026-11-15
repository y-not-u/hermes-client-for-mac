import AppKit
import UserNotifications
import OSLog

@MainActor final class ReplyNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReplyNotifications()
    private let logger = Logger(subsystem: "com.hermes.mac", category: "notifications")
    private let isAppActive: @MainActor () -> Bool
    private let updateDockBadge: @MainActor (String?) -> Void
    private(set) var pendingReplyCount = 0

    init(isAppActive: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? false },
         updateDockBadge: @escaping @MainActor (String?) -> Void = { NSApp?.dockTile.badgeLabel = $0 }) {
        self.isAppActive = isAppActive
        self.updateDockBadge = updateDockBadge
        super.init()
    }

    func start() {
        // SwiftPM test executables are not application bundles.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        clearReplyBadge()
        NotificationCenter.default.addObserver(self, selector: #selector(clearReplyBadge),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        Task {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
            catch { logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func replyCompleted(profile: String, text: String) {
        guard !isAppActive() else { return }
        pendingReplyCount += 1
        updateDockBadge(String(pendingReplyCount))
        send(title: "\(profile) 回复已完成", text: text, fallback: "打开 Hermes 查看回复。", kind: "reply")
    }

    @objc func clearReplyBadge() {
        pendingReplyCount = 0
        updateDockBadge(nil)
    }

    func approvalRequested(profile: String, description: String) {
        send(title: "\(profile) 等待审批", text: description, fallback: "打开 Hermes 查看并处理审批请求。", kind: "approval")
    }

    private func send(title: String, text: String, fallback: String, kind: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        let preview = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        content.body = preview.isEmpty ? fallback : String(preview.prefix(180))
        content.userInfo = ["kind": kind]
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized,
                  kind == "approval" || !isAppActive() else { return }
            do { try await center.add(request) }
            catch { logger.error("Notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let isApproval = notification.request.content.userInfo["kind"] as? String == "approval"
        Task { @MainActor in
            completionHandler(isApproval || !self.isAppActive() ? [.banner, .sound, .list] : [])
        }
    }
}
