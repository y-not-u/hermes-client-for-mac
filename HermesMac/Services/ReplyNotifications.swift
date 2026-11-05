import AppKit
import UserNotifications
import OSLog

@MainActor final class ReplyNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReplyNotifications()
    private let logger = Logger(subsystem: "com.hermes.mac", category: "notifications")

    func start() {
        // SwiftPM test executables are not application bundles.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func replyCompleted(profile: String, text: String) {
        send(title: "\(profile) 回复已完成", text: text, fallback: "打开 Hermes 查看回复。", kind: "reply")
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
                  kind == "approval" || !NSApp.isActive else { return }
            do { try await center.add(request) }
            catch { logger.error("Notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let isApproval = notification.request.content.userInfo["kind"] as? String == "approval"
        Task { @MainActor in
            completionHandler(isApproval || !NSApp.isActive ? [.banner, .sound, .list] : [])
        }
    }
}
