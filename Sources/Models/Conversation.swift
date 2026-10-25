import Foundation

struct Conversation: Identifiable, Codable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var title: String
    var messages: [ChatMessage]
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var selectedProfileId: String? = nil
    var selectedModelName: String? = nil
}
