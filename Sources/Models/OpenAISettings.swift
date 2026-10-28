import Foundation

struct AIProviderProfile: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var baseURL: String
    var apiKey: String
    var availableModels: [String] = []
    var enabledModels: [String] = []

    init(
        id: String = UUID().uuidString,
        name: String = "默认接口配置",
        baseURL: String = "https://api.openai.com/v1",
        apiKey: String = "",
        availableModels: [String] = [],
        enabledModels: [String] = []
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.availableModels = availableModels
        self.enabledModels = enabledModels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "默认接口配置"
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com/v1"
        self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        self.availableModels = try container.decodeIfPresent([String].self, forKey: .availableModels) ?? []
        if let explicitEnabled = try container.decodeIfPresent([String].self, forKey: .enabledModels) {
            self.enabledModels = explicitEnabled
        } else {
            self.enabledModels = self.availableModels
        }
    }
}

struct OpenAISettings: Codable, Equatable {
    var baseURL: String = "https://api.openai.com/v1"
    var apiKey: String = ""
    var modelName: String = "gpt-4o"
    var availableModels: [String] = []
    var enabledModels: [String] = []
    var providerProfiles: [AIProviderProfile] = []
    var activeProfileId: String = ""
    var systemPrompt: String = "You are a helpful assistant with tool calling capabilities."
    var contextWindowTokens: Int = 1_000_000
    private var contextWindowTokensMigrationVersion: Int = 1
    var temperature: Double = 0.7
    var themePreset: String = SoftThemePreset.warmOat.rawValue
    var useCustomBackground: Bool = false
    var customBackgroundHex: String = "F6F1E7"
    var customAccentHex: String = "9C6B3B"

    init(
        baseURL: String = "https://api.openai.com/v1",
        apiKey: String = "",
        modelName: String = "gpt-4o",
        availableModels: [String] = [],
        enabledModels: [String] = [],
        providerProfiles: [AIProviderProfile] = [],
        activeProfileId: String = "",
        systemPrompt: String = "You are a helpful assistant with tool calling capabilities.",
        contextWindowTokens: Int = 1_000_000,
        temperature: Double = 0.7,
        themePreset: String = SoftThemePreset.warmOat.rawValue,
        useCustomBackground: Bool = false,
        customBackgroundHex: String = "F6F1E7",
        customAccentHex: String = "9C6B3B"
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelName = modelName
        self.availableModels = availableModels
        self.enabledModels = enabledModels
        self.systemPrompt = systemPrompt
        self.contextWindowTokens = max(4_096, contextWindowTokens)
        self.contextWindowTokensMigrationVersion = 1
        self.temperature = temperature
        self.themePreset = themePreset
        self.useCustomBackground = useCustomBackground
        self.customBackgroundHex = customBackgroundHex
        self.customAccentHex = customAccentHex

        if providerProfiles.isEmpty {
            let initialEnabled = enabledModels.isEmpty ? (availableModels.isEmpty ? [modelName] : availableModels) : enabledModels
            let defaultProfile = AIProviderProfile(
                name: "默认接口配置",
                baseURL: baseURL,
                apiKey: apiKey,
                availableModels: availableModels,
                enabledModels: initialEnabled
            )
            self.providerProfiles = [defaultProfile]
            self.activeProfileId = defaultProfile.id
            self.enabledModels = initialEnabled
        } else {
            self.providerProfiles = providerProfiles
            self.activeProfileId = activeProfileId.isEmpty ? providerProfiles[0].id : activeProfileId
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedBaseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com/v1"
        let decodedApiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        let decodedModelName = try container.decodeIfPresent(String.self, forKey: .modelName) ?? "gpt-4o"
        let decodedAvailable = try container.decodeIfPresent([String].self, forKey: .availableModels) ?? []
        let decodedEnabled = try container.decodeIfPresent([String].self, forKey: .enabledModels)
            ?? (decodedAvailable.isEmpty ? [decodedModelName] : decodedAvailable)

        self.baseURL = decodedBaseURL
        self.apiKey = decodedApiKey
        self.modelName = decodedModelName
        self.availableModels = decodedAvailable
        self.enabledModels = decodedEnabled
        self.systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? "You are a helpful assistant with tool calling capabilities."
        let decodedContextWindowTokens = try container.decodeIfPresent(Int.self, forKey: .contextWindowTokens) ?? 1_000_000
        let decodedContextWindowTokensMigrationVersion = try container.decodeIfPresent(Int.self, forKey: .contextWindowTokensMigrationVersion) ?? 0
        self.contextWindowTokens = max(
            4_096,
            decodedContextWindowTokensMigrationVersion == 0 && decodedContextWindowTokens == 32_768
                ? 1_000_000
                : decodedContextWindowTokens
        )
        self.contextWindowTokensMigrationVersion = 1
        self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.7
        self.themePreset = try container.decodeIfPresent(String.self, forKey: .themePreset) ?? SoftThemePreset.warmOat.rawValue
        self.useCustomBackground = try container.decodeIfPresent(Bool.self, forKey: .useCustomBackground) ?? false
        self.customBackgroundHex = try container.decodeIfPresent(String.self, forKey: .customBackgroundHex) ?? "F6F1E7"
        self.customAccentHex = try container.decodeIfPresent(String.self, forKey: .customAccentHex) ?? "9C6B3B"

        let decodedProfiles = try container.decodeIfPresent([AIProviderProfile].self, forKey: .providerProfiles) ?? []
        let decodedActiveId = try container.decodeIfPresent(String.self, forKey: .activeProfileId) ?? ""

        if decodedProfiles.isEmpty {
            let migratedProfile = AIProviderProfile(
                name: "默认接口配置",
                baseURL: decodedBaseURL,
                apiKey: decodedApiKey,
                availableModels: decodedAvailable,
                enabledModels: decodedEnabled
            )
            self.providerProfiles = [migratedProfile]
            self.activeProfileId = migratedProfile.id
        } else {
            self.providerProfiles = decodedProfiles
            if decodedProfiles.contains(where: { $0.id == decodedActiveId }) {
                self.activeProfileId = decodedActiveId
            } else {
                self.activeProfileId = decodedProfiles[0].id
            }
            if let active = self.providerProfiles.first(where: { $0.id == self.activeProfileId }) {
                self.baseURL = active.baseURL
                self.apiKey = active.apiKey
                self.availableModels = active.availableModels
                self.enabledModels = active.enabledModels
            }
        }
    }

    var activeProfileIndex: Int? {
        providerProfiles.firstIndex(where: { $0.id == activeProfileId })
    }

    var activeProfile: AIProviderProfile? {
        guard let idx = activeProfileIndex else { return providerProfiles.first }
        return providerProfiles[idx]
    }

    var chatSelectableModels: [String] {
        var result: [String] = []
        for profile in providerProfiles {
            for model in profile.enabledModels where !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !result.contains(model) {
                    result.append(model)
                }
            }
        }
        if result.isEmpty {
            for model in enabledModels where !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !result.contains(model) {
                    result.append(model)
                }
            }
        }
        if result.isEmpty {
            let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(trimmed)
            }
        }
        return result
    }

    var chatSelectableModelEntries: [(id: String, profileId: String, profileName: String, model: String)] {
        var entries: [(id: String, profileId: String, profileName: String, model: String)] = []
        for profile in providerProfiles {
            for model in profile.enabledModels where !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries.append(("\(profile.id)::\(model)", profile.id, profile.name, model))
            }
        }
        if entries.isEmpty {
            let fallbackId = activeProfile?.id ?? ""
            let fallbackName = activeProfile?.name ?? "默认配置"
            let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                entries.append(("\(fallbackId)::\(trimmed)", fallbackId, fallbackName, trimmed))
            }
        }
        return entries
    }

    func resolvedSettings(for conversation: Conversation?) -> OpenAISettings {
        guard let conv = conversation else { return self }
        var copy = self

        if let pid = conv.selectedProfileId,
           let profile = providerProfiles.first(where: { $0.id == pid }) {
            copy.activeProfileId = profile.id
            copy.baseURL = profile.baseURL
            copy.apiKey = profile.apiKey
            copy.availableModels = profile.availableModels
            copy.enabledModels = profile.enabledModels
            if let m = conv.selectedModelName?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
                if profile.enabledModels.isEmpty || profile.enabledModels.contains(m) || profile.availableModels.contains(m) {
                    copy.modelName = m
                } else if profile.enabledModels.contains(self.modelName) {
                    copy.modelName = self.modelName
                } else if let first = profile.enabledModels.first {
                    copy.modelName = first
                } else {
                    copy.modelName = m
                }
            } else if let first = profile.enabledModels.first {
                copy.modelName = first
            }
            return copy
        }

        if let m = conv.selectedModelName?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            if let matchedProfile = providerProfiles.first(where: { $0.enabledModels.contains(m) || $0.availableModels.contains(m) }) {
                copy.activeProfileId = matchedProfile.id
                copy.baseURL = matchedProfile.baseURL
                copy.apiKey = matchedProfile.apiKey
                copy.availableModels = matchedProfile.availableModels
                copy.enabledModels = matchedProfile.enabledModels
                copy.modelName = m
            } else if chatSelectableModels.isEmpty || chatSelectableModels.contains(m) {
                copy.modelName = m
            }
        }
        return copy
    }

    mutating func selectProfile(id: String) {
        guard let profile = providerProfiles.first(where: { $0.id == id }) else { return }
        activeProfileId = profile.id
        baseURL = profile.baseURL
        apiKey = profile.apiKey
        availableModels = profile.availableModels
        enabledModels = profile.enabledModels
        if !profile.enabledModels.isEmpty && !profile.enabledModels.contains(modelName) {
            modelName = profile.enabledModels[0]
        }
    }

    mutating func selectChatModel(profileId: String, model: String) {
        if let profile = providerProfiles.first(where: { $0.id == profileId }) {
            activeProfileId = profile.id
            baseURL = profile.baseURL
            apiKey = profile.apiKey
            availableModels = profile.availableModels
            enabledModels = profile.enabledModels
        }
        modelName = model
    }

    mutating func syncActiveProfileFromTopLevel() {
        guard let idx = activeProfileIndex else { return }
        providerProfiles[idx].baseURL = baseURL
        providerProfiles[idx].apiKey = apiKey
        providerProfiles[idx].availableModels = availableModels
        providerProfiles[idx].enabledModels = enabledModels
    }

    mutating func updateActiveProfile(_ mutate: (inout AIProviderProfile) -> Void) {
        if providerProfiles.isEmpty {
            let p = AIProviderProfile(
                name: "默认接口配置",
                baseURL: baseURL,
                apiKey: apiKey,
                availableModels: availableModels,
                enabledModels: enabledModels
            )
            providerProfiles = [p]
            activeProfileId = p.id
        }
        let idx = activeProfileIndex ?? 0
        mutate(&providerProfiles[idx])
        let updated = providerProfiles[idx]
        activeProfileId = updated.id
        baseURL = updated.baseURL
        apiKey = updated.apiKey
        availableModels = updated.availableModels
        enabledModels = updated.enabledModels
        if !updated.enabledModels.isEmpty && !updated.enabledModels.contains(modelName) {
            modelName = updated.enabledModels[0]
        }
    }

    @discardableResult
    mutating func addProfile(name: String, baseURL: String = "https://api.openai.com/v1", apiKey: String = "") -> AIProviderProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = AIProviderProfile(
            name: trimmedName.isEmpty ? "配置 \(providerProfiles.count + 1)" : trimmedName,
            baseURL: baseURL,
            apiKey: apiKey,
            availableModels: [],
            enabledModels: []
        )
        providerProfiles.append(profile)
        selectProfile(id: profile.id)
        return profile
    }

    mutating func deleteProfile(id: String) {
        guard providerProfiles.count > 1 else { return }
        providerProfiles.removeAll { $0.id == id }
        if !providerProfiles.contains(where: { $0.id == activeProfileId }),
           let first = providerProfiles.first {
            selectProfile(id: first.id)
        }
    }

    var currentTheme: AppThemePalette {
        if useCustomBackground {
            return AppThemePalette.make(backgroundHex: customBackgroundHex, accentHex: customAccentHex)
        }
        let preset = SoftThemePreset(rawValue: themePreset) ?? .warmOat
        return AppThemePalette.make(backgroundHex: preset.backgroundHex, accentHex: preset.accentHex)
    }
}
