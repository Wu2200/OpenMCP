import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var storage: DataStorage
    @State private var showingSaveAlert: Bool = false
    @State private var isFetchingModels: Bool = false
    @State private var fetchErrorMessage: String? = nil
    @State private var fetchSuccessMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("OpenAI 兼容接口配置")) {
                    TextField("Base URL (如 https://api.openai.com/v1)", text: $storage.settings.baseURL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    SecureField("API Key", text: $storage.settings.apiKey)
                        .autocapitalization(.none)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("模型名称 (如 gpt-4o, deepseek-chat)", text: $storage.settings.modelName)
                                .autocapitalization(.none)

                            if !storage.settings.availableModels.isEmpty {
                                Menu {
                                    ForEach(storage.settings.availableModels, id: \.self) { model in
                                        Button(action: {
                                            storage.settings.modelName = model
                                            storage.saveSettings()
                                        }) {
                                            HStack {
                                                Text(model)
                                                if storage.settings.modelName == model {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text("选择")
                                            .font(.caption.weight(.medium))
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption2)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(.systemGray5))
                                    .cornerRadius(8)
                                }
                            }
                        }

                        Button(action: {
                            fetchModels()
                        }) {
                            HStack {
                                if isFetchingModels {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("正在获取模型...")
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    Text("获取可用模型列表")
                                }
                            }
                            .font(.footnote.weight(.medium))
                        }
                        .disabled(isFetchingModels || storage.settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let success = fetchSuccessMessage {
                            Text(success)
                                .font(.caption)
                                .foregroundColor(.green)
                        }

                        if let err = fetchErrorMessage {
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }

                Section(header: Text("快速服务预设")) {
                    Button("DeepSeek 官方") {
                        applyPreset(base: "https://api.deepseek.com", model: "deepseek-chat")
                    }
                    Button("OpenAI 官方") {
                        applyPreset(base: "https://api.openai.com/v1", model: "gpt-4o")
                    }
                    Button("Moonshot (Kimi)") {
                        applyPreset(base: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k")
                    }
                    Button("Groq 高速端点") {
                        applyPreset(base: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile")
                    }
                    Button("Ollama 本地 / 局域网") {
                        applyPreset(base: "http://127.0.0.1:11434/v1", model: "qwen2.5:latest")
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

    private func applyPreset(base: String, model: String) {
        storage.settings.baseURL = base
        storage.settings.modelName = model
        storage.settings.availableModels = []
        fetchErrorMessage = nil
        fetchSuccessMessage = nil
        storage.saveSettings()
    }

    private func fetchModels() {
        fetchErrorMessage = nil
        fetchSuccessMessage = nil
        isFetchingModels = true
        Task {
            do {
                let models = try await OpenAIService.shared.fetchModels(settings: storage.settings)
                await MainActor.run {
                    storage.settings.availableModels = models
                    if !models.isEmpty && !models.contains(storage.settings.modelName) {
                        storage.settings.modelName = models[0]
                    }
                    storage.saveSettings()
                    fetchSuccessMessage = "成功获取 \(models.count) 个模型"
                    isFetchingModels = false
                }
            } catch {
                await MainActor.run {
                    fetchErrorMessage = error.localizedDescription
                    isFetchingModels = false
                }
            }
        }
    }
}
