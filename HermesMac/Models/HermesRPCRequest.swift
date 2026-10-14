import Foundation

/// Typed inputs for the chat/model RPC contract. Dynamic responses remain open JSON
/// so additive server fields and snapshot receive ordinals survive transport decoding.
enum HermesRPCRequest {
    enum FollowUpMethod: String {
        case redirect = "session.redirect"
        case steer = "session.steer"
    }

    case capabilities
    case createSession(profile: String)
    case resumeSession(profile: String, sessionID: String)
    case modelOptions(profile: String, runtimeID: String?, refresh: Bool)
    case setModel(profile: String, runtimeID: String, choice: ModelChoice, confirmed: Bool)
    case submitPrompt(profile: String, runtimeID: String, text: String, queued: Bool = false)
    case followUp(FollowUpMethod, profile: String, runtimeID: String, text: String)
    case interrupt(profile: String, runtimeID: String)
    case approve(runtimeID: String, requestID: String, choice: String)

    var method: String {
        switch self {
        case .capabilities: return "client.capabilities"
        case .createSession: return "session.create"
        case .resumeSession: return "session.resume"
        case .modelOptions: return "model.options"
        case .setModel: return "config.set"
        case .submitPrompt: return "prompt.submit"
        case .followUp(let method, _, _, _): return method.rawValue
        case .interrupt: return "session.interrupt"
        case .approve: return "approval.respond"
        }
    }

    var params: [String: JSON] {
        switch self {
        case .capabilities:
            return ["server_requests": .bool(true)]
        case .createSession(let profile):
            return ["profile": .string(profile), "source": .string("dashboard"), "close_on_disconnect": .bool(false)]
        case .resumeSession(let profile, let sessionID):
            return ["profile": .string(profile), "session_id": .string(sessionID), "omit_messages": .bool(true)]
        case .modelOptions(let profile, let runtimeID, let refresh):
            var params: [String: JSON] = ["profile": .string(profile)]
            if let runtimeID { params["session_id"] = .string(runtimeID) }
            if refresh { params["refresh"] = .bool(true) }
            return params
        case .setModel(let profile, let runtimeID, let choice, let confirmed):
            var params = Self.sessionParams(profile: profile, runtimeID: runtimeID)
            params["key"] = .string("model"); params["value"] = .string(choice.switchValue)
            if confirmed { params["confirm_expensive_model"] = .bool(true) }
            return params
        case .submitPrompt(let profile, let runtimeID, let text, let queued):
            var params = Self.sessionParams(profile: profile, runtimeID: runtimeID)
            params["text"] = .string(text)
            if queued { params["queued"] = .bool(true) }
            return params
        case .followUp(_, let profile, let runtimeID, let text):
            var params = Self.sessionParams(profile: profile, runtimeID: runtimeID)
            params["text"] = .string(text)
            return params
        case .interrupt(let profile, let runtimeID):
            return Self.sessionParams(profile: profile, runtimeID: runtimeID)
        case .approve(let runtimeID, let requestID, let choice):
            return ["session_id": .string(runtimeID), "request_id": .string(requestID), "choice": .string(choice)]
        }
    }

    private static func sessionParams(profile: String, runtimeID: String) -> [String: JSON] {
        ["profile": .string(profile), "session_id": .string(runtimeID)]
    }
}

@MainActor protocol HermesRPCExecuting {
    func execute(_ request: HermesRPCRequest) async throws -> JSON
}
