import Foundation
import Observation

@MainActor @Observable final class Conversation {
    let key: ConversationKey
    var runtimeID: String?
    var messages: [Message] = []
    private(set) var lastSubmittedMessageID: String?
    var toolActivities: [ToolActivity] = []
    var tools: [ToolCall] { toolActivities.flatMap(\.tools) }
    var entries: [ConversationEntry] {
        var result = toolActivities.filter { $0.afterMessageID == nil }.map(ConversationEntry.tools)
        for message in messages {
            result.append(.message(message))
            result += toolActivities.filter { $0.afterMessageID == message.id }.map(ConversationEntry.tools)
        }
        return result
    }
    var approvals: [Approval] = []
    var generating = false
    var uncertain = false
    var readOnlyReason: String?
    var error: String?
    var unread = false
    var loading = false
    var loadingEpoch: UUID?
    var receivedAfter: Double = 0
    var historyReadAfter: Double = 0
    var historyBacklog: [Message] = []
    var historyOffset = 0
    var hasOlder = false
    private var streamID: String?
    private var activityID: String?
    private var followUpStreams: [String: (stream: String?, activity: String?)] = [:]
    init(key: ConversationKey) { self.key = key }
    func snapshot(_ json: JSON, history: [Message]? = nil) {
        let previousMessages = messages
        let wasUncertain = uncertain
        runtimeID = json["session_id"].string
        receivedAfter = json["_responseOrdinal"].number
        // A metadata-only resume must not erase the visible transcript. Its inflight
        // snapshot replaces the previous partial assistant rather than appending it twice.
        messages = history ?? (json["messages_omitted"].bool
            ? previousMessages.filter { $0.id != streamID || json["inflight"]["assistant"].string.isEmpty }
            : Message.visibleHistory(json["messages"].array))
        approvals = []; streamID = nil
        generating = json["running"].bool || json["inflight"]["streaming"].bool
        uncertain = false; readOnlyReason = nil
        let inflight = json["inflight"]
        let corrections = inflight["corrections"].array.map(\.string).filter { !$0.isEmpty }
        // Local optimistic corrections must follow the restored assistant checkpoint.
        let localCorrections = messages.filter { $0.role == "user" && $0.deliveryStatus != nil && corrections.contains($0.text) }
        let localIDs = Set(localCorrections.map(\.id))
        messages.removeAll { localIDs.contains($0.id) }
        let hasOriginal = corrections.isEmpty ? messages.last?.text == inflight["user"].string
            : messages.contains { $0.role == "user" && $0.text == inflight["user"].string }
        if !inflight["user"].string.isEmpty, !hasOriginal {
            messages.append(Message(role: "user", text: inflight["user"].string))
        }
        if !inflight["assistant"].string.isEmpty { appendStream(inflight["assistant"].string) }
        var remainingLocal = localCorrections
        for text in corrections {
            if let index = remainingLocal.firstIndex(where: { $0.text == text }) {
                messages.append(remainingLocal.remove(at: index))
            } else if !messages.contains(where: { $0.role == "user" && $0.text == text }) {
                messages.append(Message(role: "user", text: text))
            }
        }
        if !corrections.isEmpty { streamID = nil }
        for frame in json["open_requests"].array where frame["method"].string == "approval" {
            approvals.append(Approval(id: frame["id"].string, params: frame["params"]))
        }
        error = inflight["error"].string.isEmpty ? nil : inflight["error"].string
        if wasUncertain, let sent = previousMessages.last(where: { $0.role == "user" }), !messages.contains(where: { $0.role == "user" && $0.text == sent.text }) {
            messages = previousMessages
            uncertain = true
            error = "恢复的历史未确认上次发送，已保留本地显示内容。请检查服务端历史或新建会话；不会自动重发。"
        }
        historyBacklog = Array(messages.dropLast(100)); messages = Array(messages.suffix(100))
        // History responses can replace local UUIDs with server row IDs.
        // Keep locally observed tool groups attached to the same transcript message.
        for index in toolActivities.indices {
            guard let anchor = toolActivities[index].afterMessageID,
                  !messages.contains(where: { $0.id == anchor }),
                  let previous = previousMessages.first(where: { $0.id == anchor }),
                  let restored = messages.last(where: { $0.role == previous.role && $0.text == previous.text }) else { continue }
            toolActivities[index].afterMessageID = restored.id
        }
        if !generating { activityID = nil }
    }
    func appendStream(_ text: String) {
        if let streamID, let i = messages.firstIndex(where: { $0.id == streamID }) { messages[i].text += text }
        else { let message = Message(role: "assistant", text: text); streamID = message.id; messages.append(message) }
    }
    func begin(_ text: String) {
        streamID = nil; activityID = nil; error = nil; generating = true; unread = false
        let message = Message(role: "user", text: text)
        messages.append(message)
        lastSubmittedMessageID = message.id
    }
    func appendFollowUp(_ text: String, splitReply: Bool) -> String {
        let previous = (stream: streamID, activity: activityID)
        if splitReply { streamID = nil; activityID = nil }
        error = nil
        var message = Message(role: "user", text: text)
        followUpStreams[message.id] = previous
        message.deliveryStatus = "正在提交…"
        messages.append(message)
        lastSubmittedMessageID = message.id
        return message.id
    }
    func setDelivery(_ id: String, _ status: String, preserveReply: Bool = false) {
        if let previous = followUpStreams.removeValue(forKey: id), preserveReply, generating, streamID == nil {
            streamID = previous.stream; activityID = previous.activity
        }
        if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].deliveryStatus = status }
    }
    func moveFollowUpToEnd(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let message = messages.remove(at: index); messages.append(message)
    }
    func apply(type: String, payload: JSON, visible: Bool) {
        switch type {
        case "message.start": generating = true
        case "message.delta": appendStream(payload["text"].string)
        case "message.interim":
            if !payload["already_streamed"].bool { appendStream(payload["text"].string) }; streamID = nil
        case "message.complete":
            let text = payload["text"].string
            if !text.isEmpty && !payload["response_reused"].bool {
                if let streamID, let i = messages.firstIndex(where: { $0.id == streamID }) { messages[i].text = text }
                else if messages.last?.role != "assistant" || messages.last?.text != text {
                    messages.append(Message(role: "assistant", text: text))
                }
            }
            streamID = nil; activityID = nil; generating = false; uncertain = false; unread = !visible
            approvals = []; error = payload["error"].string.isEmpty ? nil : payload["error"].string
        case "error": error = payload["message"].string; generating = false
        case "tool.start":
            let id = payload["tool_id"].string
            if !tools.contains(where: { $0.id == id }) {
                if activityID == nil {
                    let activity = ToolActivity(id: UUID().uuidString, afterMessageID: messages.last?.id, tools: [])
                    activityID = activity.id
                    toolActivities.append(activity)
                }
                if let index = toolActivities.firstIndex(where: { $0.id == activityID }) {
                    toolActivities[index].tools.append(ToolCall(id: id, name: payload["name"].string, details: payload["args"].pretty))
                }
                // Text after tool execution belongs below the activity, even if
                // the server did not emit an interim message boundary.
                streamID = nil
            }
        case "tool.complete":
            for index in toolActivities.indices {
                if let toolIndex = toolActivities[index].tools.firstIndex(where: { $0.id == payload["tool_id"].string }) {
                    toolActivities[index].tools[toolIndex].complete = true
                    toolActivities[index].tools[toolIndex].details += "\n" + payload["result"].pretty
                    break
                }
            }
        case "request.cancel": approvals.removeAll { $0.id == payload["id"].string }
        default: break
        }
    }
}
