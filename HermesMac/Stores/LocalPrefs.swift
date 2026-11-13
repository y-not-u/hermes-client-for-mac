import Foundation

/// Process-wide layout preferences: window frame, session-list width, the
/// chat/computer split, and whether the computer pane is open. These are
/// global (not per-service), stored directly in UserDefaults.
@MainActor enum LocalPrefs {
    static let windowFrameKey = "layout.windowFrame"
    static let sessionListWidthKey = "layout.sessionListWidth"
    static let chatSplitFractionKey = "layout.chatSplitFraction"
    static let botScreenOpenKey = "layout.botScreenOpen"

    static var windowFrame: CGRect? {
        get {
            guard let data = UserDefaults.standard.data(forKey: windowFrameKey) else { return nil }
            return decode(data)
        }
        set {
            guard let newValue, let data = try? encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: windowFrameKey)
                return
            }
            UserDefaults.standard.set(data, forKey: windowFrameKey)
        }
    }

    static var sessionListWidth: CGFloat? {
        get {
            let value = UserDefaults.standard.double(forKey: sessionListWidthKey)
            return value > 0 ? value : nil
        }
        set {
            if let newValue, newValue > 0 { UserDefaults.standard.set(Double(newValue), forKey: sessionListWidthKey) }
            else { UserDefaults.standard.removeObject(forKey: sessionListWidthKey) }
        }
    }

    static var chatSplitFraction: CGFloat? {
        get {
            let value = UserDefaults.standard.double(forKey: chatSplitFractionKey)
            return value > 0 ? value : nil
        }
        set {
            if let newValue, newValue > 0 { UserDefaults.standard.set(Double(newValue), forKey: chatSplitFractionKey) }
            else { UserDefaults.standard.removeObject(forKey: chatSplitFractionKey) }
        }
    }

    static var botScreenOpen: Bool {
        get { UserDefaults.standard.bool(forKey: botScreenOpenKey) }
        set { UserDefaults.standard.set(newValue, forKey: botScreenOpenKey) }
    }

    // CGRect has no direct UserDefaults bridging on this deployment target.
    private static func encode(_ rect: CGRect) throws -> Data {
        var value = rect
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func decode(_ data: Data) -> CGRect? {
        guard data.count == MemoryLayout<CGRect>.size else { return nil }
        return data.withUnsafeBytes { $0.load(as: CGRect.self) }
    }
}
