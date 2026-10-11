import Foundation
import Observation

@MainActor @Observable final class Conversation {
    let key: ConversationKey
    var runtimeID: String?
    var messages: [Message] = []
    var tools: [ToolCall] = []
    var approvals: [Approval] = []
    var generating = false
    var uncertain = false
    var readOnlyReason: String?
    var error: String?
    var unread = false
    var loading = false
    var loadingEpoch: UUID?
    var receivedAfter: Double = 0
    var historyBacklog: [Message] = []
    var historyOffset = 0
    var hasOlder = false
    private var streamID: String?
    init(key: ConversationKey) { self.key = key }
    func snapshot(_ json: JSON) {
        let previousMessages = messages
        let wasUncertain = uncertain
        runtimeID = json["session_id"].string
        receivedAfter = json["_responseOrdinal"].number
        messages = json["messages"].array.map(Message.init).filter { !$0.text.isEmpty && $0.role != "system" }
        approvals = []; streamID = nil
        generating = json["running"].bool || json["inflight"]["streaming"].bool
        uncertain = false; readOnlyReason = nil
        let inflight = json["inflight"]
        if !inflight["user"].string.isEmpty, messages.last?.text != inflight["user"].string {
            messages.append(Message(role: "user", text: inflight["user"].string))
        }
        if !inflight["assistant"].string.isEmpty { appendStream(inflight["assistant"].string) }
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
    }
    func appendStream(_ text: String) {
        if let streamID, let i = messages.firstIndex(where: { $0.id == streamID }) { messages[i].text += text }
        else { let message = Message(role: "assistant", text: text); streamID = message.id; messages.append(message) }
    }
    func begin(_ text: String) {
        streamID = nil; error = nil; tools = []; generating = true; unread = false
        messages.append(Message(role: "user", text: text))
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
                else { messages.append(Message(role: "assistant", text: text)) }
            }
            streamID = nil; generating = false; uncertain = false; unread = !visible
            approvals = []; error = payload["error"].string.isEmpty ? nil : payload["error"].string
        case "error": error = payload["message"].string; generating = false
        case "tool.start":
            let id = payload["tool_id"].string
            if !tools.contains(where: { $0.id == id }) { tools.append(ToolCall(id: id, name: payload["name"].string, details: payload["args"].pretty)) }
        case "tool.complete":
            if let i = tools.firstIndex(where: { $0.id == payload["tool_id"].string }) { tools[i].complete = true; tools[i].details += "\n" + payload["result"].pretty }
        case "request.cancel": approvals.removeAll { $0.id == payload["id"].string }
        default: break
        }
    }
}
