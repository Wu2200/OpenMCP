import Foundation

enum MessageRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}

struct ToolCallItem: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var arguments: String
    var result: String?
    var isExecuting: Bool = false
    var error: String?
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var role: MessageRole
    var content: String
    var toolCalls: [ToolCallItem]?
    var toolCallId: String?
    var createdAt: Date = Date()
}
