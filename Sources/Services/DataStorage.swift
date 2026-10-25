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
        let loadedSettings: OpenAISettings
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(OpenAISettings.self, from: data) {
            loadedSettings = decoded
        } else {
            loadedSettings = OpenAISettings()
        }
        self.settings = loadedSettings

        if let data = UserDefaults.standard.data(forKey: serversKey),
           let decoded = try? JSONDecoder().decode([MCPServer].self, from: data) {
            self.servers = decoded
        } else {
            self.servers = []
        }

        if let data = UserDefaults.standard.data(forKey: conversationsKey),
           let decoded = try? JSONDecoder().decode([Conversation].self, from: data) {
            var migrated = decoded
            var didMigrate = false
            for idx in migrated.indices {
                if migrated[idx].selectedProfileId == nil && migrated[idx].selectedModelName == nil {
                    migrated[idx].selectedProfileId = loadedSettings.activeProfileId
                    migrated[idx].selectedModelName = loadedSettings.modelName
                    didMigrate = true
                }
            }
            self.conversations = migrated
            if didMigrate, let encoded = try? JSONEncoder().encode(migrated) {
                UserDefaults.standard.set(encoded, forKey: conversationsKey)
            }
        } else {
            self.conversations = [
                Conversation(
                    title: "新对话",
                    messages: [],
                    selectedProfileId: loadedSettings.activeProfileId,
                    selectedModelName: loadedSettings.modelName
                )
            ]
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

    func updateConversationModel(conversationId: String, profileId: String, modelName: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        conversations[idx].selectedProfileId = profileId
        conversations[idx].selectedModelName = modelName
        saveConversations()
    }

    @discardableResult
    func addConversation(title: String = "新对话") -> Conversation {
        let conv = Conversation(
            title: title,
            messages: [],
            selectedProfileId: settings.activeProfileId,
            selectedModelName: settings.modelName
        )
        conversations.insert(conv, at: 0)
        saveConversations()
        return conv
    }

    func createNewConversation() -> Conversation {
        return addConversation(title: "新对话")
    }

    func deleteConversation(id: String) {
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty {
            conversations.append(
                Conversation(
                    title: "新对话",
                    messages: [],
                    selectedProfileId: settings.activeProfileId,
                    selectedModelName: settings.modelName
                )
            )
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

        if conversations[cIdx].messages[mIdx].role == .user {
            let nonLongAttachments = (conversations[cIdx].messages[mIdx].attachments ?? []).filter { $0.kind != .longText }
            if ChatAttachment.shouldPackageAsLongText(trimmed) {
                var newAtts = nonLongAttachments
                newAtts.append(ChatAttachment.makeLongTextAttachment(from: trimmed))
                conversations[cIdx].messages[mIdx].content = ""
                conversations[cIdx].messages[mIdx].attachments = newAtts
            } else {
                conversations[cIdx].messages[mIdx].content = trimmed
                conversations[cIdx].messages[mIdx].attachments = nonLongAttachments.isEmpty ? nil : nonLongAttachments
            }
        } else {
            conversations[cIdx].messages[mIdx].content = trimmed
        }
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
