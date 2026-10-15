import XCTest
@testable import HermesMac

@MainActor final class PerformanceTests: XCTestCase {
    func testLongTranscriptAssemblyPerformance() {
        let conversation = Conversation(key: ConversationKey(service: "fixture", profile: "a", storedID: "long"))
        for index in 0..<1_000 {
            let user = Message(id: "user-\(index)", role: "user", text: "Question \(index)")
            conversation.messages.append(user)
            conversation.messages.append(Message(id: "reply-\(index)", role: "assistant", text: "Answer \(index)"))
            conversation.toolActivities.append(ToolActivity(id: "activity-\(index)", afterMessageID: user.id,
                tools: [ToolCall(id: "tool-\(index)", name: "read", details: "result", complete: true)]))
        }
        measure {
            for _ in 0..<10 {
                XCTAssertEqual(conversation.entries.count, 3_000)
            }
        }
    }
}
