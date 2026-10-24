import Foundation
import Combine

class DataStorage: ObservableObject {
    static let shared = DataStorage()

    @Published var settings: OpenAISettings
    @Published var servers: [MCPServer]
    @Published var conversations: [Conversation]

    private let settingsKey = "openmcp_settings"
    private let serversKey = "openmcp_servers"
    private let conversationsKey = "openmcp_conversations"

    init() {
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
            self.conversations = []
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

    func addOrUpdateServer(_ server: MCPServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        saveServers()
    }

    func deleteServer(at indexSet: IndexSet) {
        servers.remove(atOffsets: indexSet)
        saveServers()
    }

    func addConversation(title: String = "新对话") -> Conversation {
        let conv = Conversation(title: title, messages: [])
        conversations.insert(conv, at: 0)
        saveConversations()
        return conv
    }

    func updateConversation(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
            saveConversations()
        }
    }

    func deleteConversation(at indexSet: IndexSet) {
        conversations.remove(atOffsets: indexSet)
        saveConversations()
    }
}
