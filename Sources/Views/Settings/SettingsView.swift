import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var storage: DataStorage
    @State private var isFetchingModels: Bool = false
    @State private var fetchErrorMessage: String? = nil
    @State private var fetchSuccessMessage: String? = nil
    @State private var showApiKey: Bool = false
    @State private var showingModelPickerSheet: Bool = false
    @State private var modelSearchText: String = ""

    private var theme: AppThemePalette {
        storage.settings.currentTheme
    }

    private let customSoftSwatches: [(name: String, bg: String, accent: String)] = [
        ("杏仁暖奶", "F7F2EA", "9E6B43"),
        ("薄荷微风", "ECF5F0", "3B7A57"),
        ("丁香暮雾", "F2EEF7", "6C5B93"),
        ("冰川浅蓝", "ECF2F8", "3A6B94"),
        ("蜜桃柔粉", "F9EFEF", "A85B6B"),
        ("松烟暖灰", "EFEFEF", "4A5568")
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        themeCustomizationCard

                        apiAndModelCard

                        generationParametersCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("外观与设置")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $showingModelPickerSheet) {
                modelPickerSheet
            }
        }
    }

    private var themeCustomizationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("全局柔和背景色")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(theme.primaryText)
                    Text("选择柔和护眼配色或自由调色，实时应用于全站所有页面")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 18))
                    .foregroundColor(theme.accent)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(SoftThemePreset.allCases) { preset in
                    let isSelected = !storage.settings.useCustomBackground && storage.settings.themePreset == preset.rawValue
                    let previewPalette = AppThemePalette.make(backgroundHex: preset.backgroundHex, accentHex: preset.accentHex)

                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            storage.settings.useCustomBackground = false
                            storage.settings.themePreset = preset.rawValue
                        }
                    }) {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(previewPalette.background)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Circle()
                                            .stroke(previewPalette.accent.opacity(0.5), lineWidth: 1.5)
                                    )
                                Circle()
                                    .fill(previewPalette.accent)
                                    .frame(width: 12, height: 12)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(theme.primaryText)
                                    .lineLimit(1)
                                Text(preset.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundColor(theme.accent)
                            }
                        }
                        .padding(10)
                        .background(isSelected ? theme.accent.opacity(0.1) : theme.elevatedBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(isSelected ? theme.accent : theme.border, lineWidth: isSelected ? 1.5 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
                .overlay(theme.border)

            Toggle(isOn: $storage.settings.useCustomBackground) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("启用自定义全局柔和背景色")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("自由选择任意柔和背景色与主题强调色")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
            }
            .tint(theme.accent)

            if storage.settings.useCustomBackground {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        ColorPicker("全局背景颜色", selection: Binding(
                            get: { Color(hex: storage.settings.customBackgroundHex) },
                            set: { newColor in
                                storage.settings.customBackgroundHex = newColor.toHex()
                            }
                        ), supportsOpacity: false)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                        Text("#\(storage.settings.customBackgroundHex)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                    }

                    HStack {
                        ColorPicker("主题强调颜色", selection: Binding(
                            get: { Color(hex: storage.settings.customAccentHex) },
                            set: { newColor in
                                storage.settings.customAccentHex = newColor.toHex()
                            }
                        ), supportsOpacity: false)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                        Text("#\(storage.settings.customAccentHex)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(customSoftSwatches, id: \.name) { swatch in
                                Button(action: {
                                    storage.settings.customBackgroundHex = swatch.bg
                                    storage.settings.customAccentHex = swatch.accent
                                }) {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(Color(hex: swatch.bg))
                                            .frame(width: 14, height: 14)
                                            .overlay(Circle().stroke(Color(hex: swatch.accent), lineWidth: 1.5))
                                        Text(swatch.name)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(theme.primaryText)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(theme.cardBackground)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(theme.border, lineWidth: 1))
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .background(theme.elevatedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(16)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    private var apiAndModelCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AI 接口与模型管理")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Image(systemName: "network")
                    .foregroundColor(theme.accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("接口地址 (Base URL)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                TextField("https://api.openai.com/v1", text: $storage.settings.baseURL)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .padding(12)
                    .background(theme.elevatedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("接口密钥 (API Key)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                HStack(spacing: 8) {
                    Group {
                        if showApiKey {
                            TextField("sk-...", text: $storage.settings.apiKey)
                                .autocapitalization(.none)
                        } else {
                            SecureField("sk-...", text: $storage.settings.apiKey)
                                .autocapitalization(.none)
                        }
                    }
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(theme.primaryText)

                    Button(action: { showApiKey.toggle() }) {
                        Image(systemName: showApiKey ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 14))
                            .foregroundColor(theme.mutedText)
                    }
                }
                .padding(12)
                .background(theme.elevatedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("当前模型 (Model ID)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                HStack(spacing: 8) {
                    TextField("例如 gpt-4o、deepseek-chat", text: $storage.settings.modelName)
                        .autocapitalization(.none)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .padding(12)
                        .background(theme.elevatedBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if !storage.settings.availableModels.isEmpty {
                        Button(action: {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            showingModelPickerSheet = true
                        }) {
                            HStack(spacing: 4) {
                                Text("列表 (\(storage.settings.availableModels.count))")
                                    .font(.system(size: 12, weight: .semibold))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(theme.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .background(theme.accent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }

                Button(action: fetchModels) {
                    HStack(spacing: 6) {
                        if isFetchingModels {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(.white)
                            Text("正在从服务端拉取模型列表...")
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("一键从接口获取可用模型列表")
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(isFetchingModels ? theme.mutedText : theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(isFetchingModels || storage.settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let success = fetchSuccessMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(success)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.accent)
                }

                if let err = fetchErrorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(err)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.red)
                }
            }
        }
        .padding(16)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    private var generationParametersCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("生成参数与系统提示词")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(theme.primaryText)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("采样温度 (Temperature)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Text(String(format: "%.2f", storage.settings.temperature))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.accent)
                }
                Slider(value: $storage.settings.temperature, in: 0.0...2.0, step: 0.05)
                    .tint(theme.accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("系统提示词 (System Prompt)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                TextField("输入全局系统提示词...", text: $storage.settings.systemPrompt, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.system(size: 14))
                    .foregroundColor(theme.primaryText)
                    .padding(12)
                    .background(theme.elevatedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(16)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    private var modelPickerSheet: some View {
        let filtered = storage.settings.availableModels.filter { m in
            let q = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return q.isEmpty || m.lowercased().contains(q)
        }

        return NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(theme.mutedText)
                        TextField("搜索模型名称...", text: $modelSearchText)
                            .autocapitalization(.none)
                            .font(.system(size: 14))
                            .foregroundColor(theme.primaryText)
                    }
                    .padding(12)
                    .background(theme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.border, lineWidth: 1))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filtered, id: \.self) { model in
                                let isSelected = storage.settings.modelName == model
                                Button(action: {
                                    storage.settings.modelName = model
                                    showingModelPickerSheet = false
                                }) {
                                    HStack {
                                        Text(model)
                                            .font(.system(size: 14, weight: isSelected ? .bold : .regular, design: .monospaced))
                                            .foregroundColor(isSelected ? theme.accent : theme.primaryText)
                                        Spacer()
                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(theme.accent)
                                        }
                                    }
                                    .padding(14)
                                    .background(isSelected ? theme.accent.opacity(0.12) : theme.cardBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(isSelected ? theme.accent : theme.border, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .navigationTitle("选择模型 (\(storage.settings.availableModels.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { showingModelPickerSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func fetchModels() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
                    fetchSuccessMessage = "已获取 \(models.count) 个模型，可点击列表快速切换"
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
