import Foundation

struct OpenAISettings: Codable, Equatable {
    var baseURL: String = "https://api.openai.com/v1"
    var apiKey: String = ""
    var modelName: String = "gpt-4o"
    var availableModels: [String] = []
    var systemPrompt: String = "You are a helpful assistant with tool calling capabilities."
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
        systemPrompt: String = "You are a helpful assistant with tool calling capabilities.",
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
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.themePreset = themePreset
        self.useCustomBackground = useCustomBackground
        self.customBackgroundHex = customBackgroundHex
        self.customAccentHex = customAccentHex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com/v1"
        self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        self.modelName = try container.decodeIfPresent(String.self, forKey: .modelName) ?? "gpt-4o"
        self.availableModels = try container.decodeIfPresent([String].self, forKey: .availableModels) ?? []
        self.systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? "You are a helpful assistant with tool calling capabilities."
        self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.7
        self.themePreset = try container.decodeIfPresent(String.self, forKey: .themePreset) ?? SoftThemePreset.warmOat.rawValue
        self.useCustomBackground = try container.decodeIfPresent(Bool.self, forKey: .useCustomBackground) ?? false
        self.customBackgroundHex = try container.decodeIfPresent(String.self, forKey: .customBackgroundHex) ?? "F6F1E7"
        self.customAccentHex = try container.decodeIfPresent(String.self, forKey: .customAccentHex) ?? "9C6B3B"
    }

    var currentTheme: AppThemePalette {
        if useCustomBackground {
            return AppThemePalette.make(backgroundHex: customBackgroundHex, accentHex: customAccentHex)
        }
        let preset = SoftThemePreset(rawValue: themePreset) ?? .warmOat
        return AppThemePalette.make(backgroundHex: preset.backgroundHex, accentHex: preset.accentHex)
    }
}
