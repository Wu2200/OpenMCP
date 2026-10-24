import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var storage: DataStorage
    @State private var showingSaveAlert: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("OpenAI 兼容接口配置")) {
                    TextField("Base URL (如 https://api.openai.com/v1)", text: $storage.settings.baseURL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    SecureField("API Key", text: $storage.settings.apiKey)
                        .autocapitalization(.none)
                    TextField("模型名称 (如 gpt-4o, deepseek-chat)", text: $storage.settings.modelName)
                        .autocapitalization(.none)
                }

                Section(header: Text("快速服务预设")) {
                    Button("DeepSeek 官方") {
                        storage.settings.baseURL = "https://api.deepseek.com"
                        storage.settings.modelName = "deepseek-chat"
                        storage.saveSettings()
                    }
                    Button("OpenAI 官方") {
                        storage.settings.baseURL = "https://api.openai.com/v1"
                        storage.settings.modelName = "gpt-4o"
                        storage.saveSettings()
                    }
                    Button("Moonshot (Kimi)") {
                        storage.settings.baseURL = "https://api.moonshot.cn/v1"
                        storage.settings.modelName = "moonshot-v1-8k"
                        storage.saveSettings()
                    }
                    Button("Groq 高速端点") {
                        storage.settings.baseURL = "https://api.groq.com/openai/v1"
                        storage.settings.modelName = "llama-3.3-70b-versatile"
                        storage.saveSettings()
                    }
                    Button("Ollama 本地 / 局域网") {
                        storage.settings.baseURL = "http://127.0.0.1:11434/v1"
                        storage.settings.modelName = "qwen2.5:latest"
                        storage.saveSettings()
                    }
                }

                Section(header: Text("高级模型参数")) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("温度 (Temperature):")
                            Spacer()
                            Text(String(format: "%.2f", storage.settings.temperature))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $storage.settings.temperature, in: 0.0...2.0, step: 0.05)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("系统提示词 (System Prompt):")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $storage.settings.systemPrompt)
                            .frame(height: 90)
                    }
                }

                Section {
                    Button(action: {
                        storage.saveSettings()
                        showingSaveAlert = true
                    }) {
                        HStack {
                            Spacer()
                            Text("保存配置")
                                .bold()
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .alert("已保存", isPresented: $showingSaveAlert) {
                Button("确定", role: .cancel) { }
            } message: {
                Text("接口配置已成功保存至本地。")
            }
        }
    }
}
