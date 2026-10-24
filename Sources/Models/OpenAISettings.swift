import Foundation

struct OpenAISettings: Codable, Equatable {
    var baseURL: String = "https://api.openai.com/v1"
    var apiKey: String = ""
    var modelName: String = "gpt-4o"
    var availableModels: [String] = []
    var systemPrompt: String = "You are a helpful assistant with tool calling capabilities."
    var temperature: Double = 0.7
}
