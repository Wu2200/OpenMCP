import Foundation
import SwiftUI

class DataStorage: ObservableObject {
    static let shared = DataStorage()

    @Published var settings: OpenAISettings {
        didSet { saveSettings() }
    }
    @Published var servers: [MCPServer] {
        didSet { saveServers() }
    }
    @Published var conversations: [Conversation] = []

    private let settingsKey = "OpenMCP_OpenAISettings"
    private let serversKey = "OpenMCP_MCPServers"
    private let conversationsKey = "OpenMCP_Conversations"

    private init() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(OpenAISettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = OpenAISettings()
        }

        if let data = UserDefaults.standard.data(forKey: serversKey),
           let decoded = try? JSONDecoder().decode([MCPServer].self, from: data) {
            self.servers = decoded
        } else {
            self.servers = []
        }

        if let data = UserDefaults.standard.data(forKey: conversationsKey),
           let decoded = try? JSONDecoder().decode([Conversation].self, from: data) {
            self.conversations = decoded
        } else {
            self.conversations = [Conversation(title: "新对话")]
        }
    }

    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    func saveServers() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: serversKey)
        }
    }

    func saveConversations() {
        if let data = try? JSONEncoder().encode(conversations) {
            UserDefaults.standard.set(data, forKey: conversationsKey)
        }
    }

    func updateConversation(_ conv: Conversation, persistImmediately: Bool = true) {
        if let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[idx] = conv
        } else {
            conversations.insert(conv, at: 0)
        }
        if persistImmediately {
            saveConversations()
        }
    }

    func createNewConversation() -> Conversation {
        let conv = Conversation(title: "新对话")
        conversations.insert(conv, at: 0)
        saveConversations()
        return conv
    }

    func deleteConversation(id: String) {
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty {
            conversations.append(Conversation(title: "新对话"))
        }
        saveConversations()
    }

    func renameConversation(id: String, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].title = trimmed
        conversations[idx].updatedAt = Date()
        saveConversations()
    }

    func clearConversationMessages(id: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages.removeAll()
        conversations[idx].updatedAt = Date()
        saveConversations()
    }

    func deleteMessageTurn(conversationId: String, messageIds: [String]) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        let idSet = Set(messageIds)
        conversations[idx].messages.removeAll { idSet.contains($0.id) }
        conversations[idx].updatedAt = Date()
        saveConversations()
    }

    func updateMessageContent(conversationId: String, messageId: String, newContent: String) {
        let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let cIdx = conversations.firstIndex(where: { $0.id == conversationId }),
              let mIdx = conversations[cIdx].messages.firstIndex(where: { $0.id == messageId }) else { return }
        conversations[cIdx].messages[mIdx].content = trimmed
        conversations[cIdx].updatedAt = Date()
        saveConversations()
    }

    func addOrUpdateServer(_ server: MCPServer) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
        } else {
            servers.append(server)
        }
    }

    func deleteServer(id: String) {
        servers.removeAll { $0.id == id }
    }
}
