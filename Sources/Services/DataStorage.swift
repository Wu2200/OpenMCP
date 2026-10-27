import Foundation
import SwiftUI
import Security

class DataStorage: ObservableObject {
    static let shared = DataStorage()

    private enum SecureStore {
        static func load(key: String) -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Bundle.main.bundleIdentifier ?? "OpenMCP",
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func save(_ value: String, key: String) -> Bool {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Bundle.main.bundleIdentifier ?? "OpenMCP",
                kSecAttrAccount as String: key
            ]
            guard let data = value.data(using: .utf8) else { return false }
            let attributes: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecSuccess {
                return true
            }
            guard status == errSecItemNotFound else { return false }
            var insertQuery = query
            insertQuery[kSecValueData as String] = data
            insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(insertQuery as CFDictionary, nil) == errSecSuccess
        }

        static func remove(key: String) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Bundle.main.bundleIdentifier ?? "OpenMCP",
                kSecAttrAccount as String: key
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

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
    private let persistenceQueue = DispatchQueue(label: "OpenMCP.DataStorage.persistence", qos: .utility)
    private var pendingServersSave: DispatchWorkItem?

    private init() {
        let loadedSettings: OpenAISettings
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(OpenAISettings.self, from: data) {
            var migratedSettings = decoded
            Self.migrateSettingsCredentials(&migratedSettings)
            loadedSettings = migratedSettings
            var persistedSettings = migratedSettings
            Self.saveSettingsCredentials(&persistedSettings)
            if let encoded = try? JSONEncoder().encode(persistedSettings) {
                UserDefaults.standard.set(encoded, forKey: settingsKey)
            }
        } else {
            loadedSettings = OpenAISettings()
        }
        self.settings = loadedSettings

        if let data = UserDefaults.standard.data(forKey: serversKey),
           let decoded = try? JSONDecoder().decode([MCPServer].self, from: data) {
            var migratedServers = decoded
            Self.migrateServerCredentials(&migratedServers)
            self.servers = migratedServers
            var persistedServers = migratedServers
            Self.saveServerCredentials(&persistedServers)
            if let encoded = try? JSONEncoder().encode(persistedServers) {
                UserDefaults.standard.set(encoded, forKey: serversKey)
            }
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
        var persistedSettings = settings
        Self.saveSettingsCredentials(&persistedSettings)
        if let data = try? JSONEncoder().encode(persistedSettings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    func saveServers() {
        pendingServersSave?.cancel()
        let snapshot = servers
        let key = serversKey
        let item = DispatchWorkItem {
            var persistedServers = snapshot
            DataStorage.saveServerCredentials(&persistedServers)
            if let data = try? JSONEncoder().encode(persistedServers) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
        pendingServersSave = item
        persistenceQueue.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private static func saveSettingsCredentials(_ value: inout OpenAISettings) {
        if SecureStore.save(value.apiKey, key: "settings.apiKey") {
            value.apiKey = ""
        }
        for index in value.providerProfiles.indices {
            let key = "profile.\(value.providerProfiles[index].id).apiKey"
            if SecureStore.save(value.providerProfiles[index].apiKey, key: key) {
                value.providerProfiles[index].apiKey = ""
            }
        }
    }

    private static func migrateSettingsCredentials(_ value: inout OpenAISettings) {
        if let saved = SecureStore.load(key: "settings.apiKey") {
            value.apiKey = saved
        } else if !value.apiKey.isEmpty {
            SecureStore.save(value.apiKey, key: "settings.apiKey")
        }
        for index in value.providerProfiles.indices {
            let key = "profile.\(value.providerProfiles[index].id).apiKey"
            if let saved = SecureStore.load(key: key) {
                value.providerProfiles[index].apiKey = saved
            } else if !value.providerProfiles[index].apiKey.isEmpty {
                SecureStore.save(value.providerProfiles[index].apiKey, key: key)
            }
        }
        value.syncActiveProfileFromTopLevel()
    }

    private static func saveServerCredentials(_ value: inout [MCPServer]) {
        for index in value.indices {
            let key = "server.\(value[index].id).token"
            if SecureStore.save(value[index].token, key: key) {
                value[index].token = ""
            }
        }
    }

    private static func migrateServerCredentials(_ value: inout [MCPServer]) {
        for index in value.indices {
            let key = "server.\(value[index].id).token"
            if let saved = SecureStore.load(key: key) {
                value[index].token = saved
            } else if !value[index].token.isEmpty {
                SecureStore.save(value[index].token, key: key)
            }
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
        ContextTokenStore.shared.remove(id)
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
        ContextTokenStore.shared.remove(id)
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
