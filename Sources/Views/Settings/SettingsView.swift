import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var storage: DataStorage
    @State private var isFetchingModels: Bool = false
    @State private var fetchErrorMessage: String? = nil
    @State private var fetchSuccessMessage: String? = nil
    @State private var showApiKey: Bool = false
    @State private var showingModelManagerSheet: Bool = false
    @State private var modelSearchText: String = ""
    @State private var customModelInput: String = ""
    @State private var showingAddProfileAlert: Bool = false
    @State private var newProfileName: String = ""
    @State private var isThemeSectionExpanded: Bool = false

    private enum SettingsField: Hashable {
        case profileName
        case baseURL
        case apiKey
        case systemPrompt
        case modelSearch
        case customModel
    }

    @FocusState private var focusedField: SettingsField?

    private var theme: AppThemePalette {
        storage.settings.currentTheme
    }

    private var activeProfileNameBinding: Binding<String> {
        Binding(
            get: { storage.settings.activeProfile?.name ?? "默认接口配置" },
            set: { newName in
                storage.settings.updateActiveProfile { profile in
                    profile.name = newName
                }
            }
        )
    }

    private var activeBaseURLBinding: Binding<String> {
        Binding(
            get: { storage.settings.baseURL },
            set: { newURL in
                storage.settings.updateActiveProfile { profile in
                    profile.baseURL = newURL
                }
            }
        )
    }

    private var activeApiKeyBinding: Binding<String> {
        Binding(
            get: { storage.settings.apiKey },
            set: { newKey in
                storage.settings.updateActiveProfile { profile in
                    profile.apiKey = newKey
                }
            }
        )
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboard()
                    }

                ScrollView {
                    VStack(spacing: 18) {
                        themeCustomizationCard

                        apiAndModelCard

                        generationParametersCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 36)
                    .background(
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismissKeyboard()
                            }
                    )
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("外观与设置")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if focusedField != nil {
                        Button(action: dismissKeyboard) {
                            HStack(spacing: 4) {
                                Image(systemName: "keyboard.chevron.compact.down")
                                Text("完成")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(theme.accent.opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }
                }
            }
            .sheet(isPresented: $showingModelManagerSheet) {
                modelManagerSheet
            }
            .alert("新建接口配置", isPresented: $showingAddProfileAlert) {
                TextField("配置名称，如 OpenAI / DeepSeek / 反代", text: $newProfileName)
                Button("取消", role: .cancel) {
                    newProfileName = ""
                }
                Button("创建") {
                    let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                    storage.settings.addProfile(name: name.isEmpty ? "新配置 \(storage.settings.providerProfiles.count + 1)" : name)
                    newProfileName = ""
                    fetchErrorMessage = nil
                    fetchSuccessMessage = nil
                }
            }
        }
    }

    private func dismissKeyboard() {
        focusedField = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
                        dismissKeyboard()
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
        let enabledCount = storage.settings.enabledModels.count
        let totalCount = storage.settings.availableModels.count

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 接口与模型管理")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(theme.primaryText)
                    Text("支持保存多套接口配置、独立命名并勾选启用对话模型")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                Button(action: {
                    dismissKeyboard()
                    newProfileName = ""
                    showingAddProfileAlert = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("新建配置")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.accent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(storage.settings.providerProfiles) { profile in
                        let isSelected = (profile.id == storage.settings.activeProfileId)
                        Button(action: {
                            dismissKeyboard()
                            fetchErrorMessage = nil
                            fetchSuccessMessage = nil
                            withAnimation(.easeInOut(duration: 0.16)) {
                                storage.settings.selectProfile(id: profile.id)
                            }
                        }) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(isSelected ? Color.white : theme.accent)
                                    .frame(width: 7, height: 7)
                                Text(profile.name.isEmpty ? "未命名配置" : profile.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                if !profile.enabledModels.isEmpty {
                                    Text("\(profile.enabledModels.count)")
                                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(isSelected ? Color.white.opacity(0.22) : theme.cardBackground)
                                        .clipShape(Capsule())
                                }
                            }
                            .foregroundColor(isSelected ? .white : theme.primaryText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(isSelected ? theme.accent : theme.elevatedBackground)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(isSelected ? theme.accent : theme.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            Divider()
                .overlay(theme.border)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("配置名称")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    if storage.settings.providerProfiles.count > 1 {
                        Button(role: .destructive, action: {
                            dismissKeyboard()
                            storage.settings.deleteProfile(id: storage.settings.activeProfileId)
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "trash")
                                Text("删除此配置")
                            }
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.red.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 8) {
                    TextField("例如：主力中转、OpenAI、DeepSeek", text: activeProfileNameBinding)
                        .focused($focusedField, equals: .profileName)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    if !activeProfileNameBinding.wrappedValue.isEmpty && focusedField == .profileName {
                        Button(action: { activeProfileNameBinding.wrappedValue = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(theme.mutedText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(theme.elevatedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(focusedField == .profileName ? theme.accent : theme.border.opacity(0.6), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture { focusedField = .profileName }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("接口地址 (Base URL)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                HStack(spacing: 8) {
                    TextField("https://api.openai.com/v1", text: activeBaseURLBinding)
                        .focused($focusedField, equals: .baseURL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(theme.primaryText)

                    if !activeBaseURLBinding.wrappedValue.isEmpty && focusedField == .baseURL {
                        Button(action: { activeBaseURLBinding.wrappedValue = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(theme.mutedText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(theme.elevatedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(focusedField == .baseURL ? theme.accent : theme.border.opacity(0.6), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture { focusedField = .baseURL }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("接口密钥 (API Key)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                HStack(spacing: 8) {
                    Group {
                        if showApiKey {
                            TextField("sk-...", text: activeApiKeyBinding)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .submitLabel(.done)
                                .onSubmit { focusedField = nil }
                        } else {
                            SecureField("sk-...", text: activeApiKeyBinding)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .submitLabel(.done)
                                .onSubmit { focusedField = nil }
                        }
                    }
                    .focused($focusedField, equals: .apiKey)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(theme.primaryText)

                    if !activeApiKeyBinding.wrappedValue.isEmpty && focusedField == .apiKey {
                        Button(action: { activeApiKeyBinding.wrappedValue = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(theme.mutedText)
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: { showApiKey.toggle() }) {
                        Image(systemName: showApiKey ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 14))
                            .foregroundColor(theme.mutedText)
                            .padding(.leading, 2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(theme.elevatedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(focusedField == .apiKey ? theme.accent : theme.border.opacity(0.6), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture { focusedField = .apiKey }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("可用与已启用模型")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    Text("已勾选 \(enabledCount) / 共 \(totalCount) 个")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(theme.accent)
                }

                HStack(spacing: 8) {
                    Button(action: fetchModels) {
                        HStack(spacing: 6) {
                            if isFetchingModels {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                                Text("正在拉取...")
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("拉取接口模型")
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

                    Button(action: {
                        dismissKeyboard()
                        showingModelManagerSheet = true
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "checklist")
                            Text("勾选管理模型")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(theme.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(theme.accent.opacity(0.35), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                if !storage.settings.enabledModels.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("此配置已勾选模型（点击可设为当前默认对话模型）：")
                            .font(.system(size: 11))
                            .foregroundColor(theme.mutedText)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(storage.settings.enabledModels, id: \.self) { m in
                                    let isCurrent = (storage.settings.modelName == m)
                                    Button(action: {
                                        storage.settings.modelName = m
                                    }) {
                                        HStack(spacing: 4) {
                                            if isCurrent {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 11))
                                            }
                                            Text(m)
                                                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular, design: .monospaced))
                                                .lineLimit(1)
                                        }
                                        .foregroundColor(isCurrent ? .white : theme.primaryText)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(isCurrent ? theme.accent : theme.elevatedBackground)
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } else {
                    Text("尚未勾选任何模型，请点击「拉取接口模型」或「勾选管理模型」添加。仅勾选的模型会在对话页显示。")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.mutedText)
                }

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
            HStack {
                Text("生成参数与系统提示词")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                if focusedField == .systemPrompt {
                    Button(action: dismissKeyboard) {
                        HStack(spacing: 4) {
                            Image(systemName: "keyboard.chevron.compact.down")
                            Text("收起键盘")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(theme.accent.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

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
                HStack {
                    Text("系统提示词 (System Prompt)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    if !storage.settings.systemPrompt.isEmpty && focusedField == .systemPrompt {
                        Button(action: { storage.settings.systemPrompt = "" }) {
                            Text("清空")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(theme.mutedText)
                        }
                        .buttonStyle(.plain)
                    }
                }

                TextField("输入全局系统提示词...", text: $storage.settings.systemPrompt, axis: .vertical)
                    .lineLimit(3...10)
                    .focused($focusedField, equals: .systemPrompt)
                    .font(.system(size: 14))
                    .foregroundColor(theme.primaryText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(theme.elevatedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(focusedField == .systemPrompt ? theme.accent : theme.border.opacity(0.6), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onTapGesture {
                        focusedField = .systemPrompt
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

    private var modelManagerSheet: some View {
        let allModels = storage.settings.availableModels
        let enabledSet = Set(storage.settings.enabledModels)
        let query = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = allModels.filter { query.isEmpty || $0.lowercased().contains(query) }

        return NavigationStack {
            ZStack {
                theme.background
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboard()
                    }

                VStack(spacing: 12) {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(theme.mutedText)
                            TextField("搜索模型名称...", text: $modelSearchText)
                                .focused($focusedField, equals: .modelSearch)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .submitLabel(.search)
                                .onSubmit { focusedField = nil }
                                .font(.system(size: 14))
                                .foregroundColor(theme.primaryText)
                            if !modelSearchText.isEmpty {
                                Button(action: { modelSearchText = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(theme.mutedText)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(11)
                        .background(theme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.border, lineWidth: 1))

                        HStack(spacing: 8) {
                            TextField("手动添加自定义模型 ID...", text: $customModelInput)
                                .focused($focusedField, equals: .customModel)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .submitLabel(.done)
                                .onSubmit { addCustomModel() }
                                .font(.system(size: 13.5, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                                .padding(10)
                                .background(theme.cardBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.border, lineWidth: 1))

                            Button(action: addCustomModel) {
                                Text("添加并勾选")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(customModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? theme.mutedText : theme.accent)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .disabled(customModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if !filtered.isEmpty {
                            HStack(spacing: 10) {
                                Button(action: {
                                    selectAllFiltered(filtered)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.square.fill")
                                        Text(query.isEmpty ? "全选 (\(filtered.count))" : "全选筛选结果 (\(filtered.count))")
                                    }
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(theme.accent)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(theme.accent.opacity(0.12))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)

                                Button(action: {
                                    deselectAllFiltered(filtered)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "square")
                                        Text(query.isEmpty ? "全不选" : "取消筛选结果")
                                    }
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(theme.secondaryText)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(theme.elevatedBackground)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Text("已勾选 \(enabledSet.count) 个")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.secondaryText)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    if filtered.isEmpty {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "square.stack.3d.up.slash")
                                .font(.system(size: 28))
                                .foregroundColor(theme.mutedText)
                            Text(allModels.isEmpty ? "当前配置暂无模型列表" : "没有匹配的模型")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            Text("可返回上一页点击「拉取接口模型」或在上方手动输入添加")
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)
                        }
                        Spacer()
                    } else {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(filtered, id: \.self) { model in
                                    let isChecked = enabledSet.contains(model)
                                    let isCurrentDefault = (storage.settings.modelName == model)

                                    HStack(spacing: 10) {
                                        Button(action: {
                                            toggleModelSelection(model)
                                        }) {
                                            HStack(spacing: 10) {
                                                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                                    .font(.system(size: 18, weight: .semibold))
                                                    .foregroundColor(isChecked ? theme.accent : theme.mutedText)

                                                Text(model)
                                                    .font(.system(size: 13.5, weight: isChecked ? .semibold : .regular, design: .monospaced))
                                                    .foregroundColor(theme.primaryText)
                                                    .multilineTextAlignment(.leading)

                                                Spacer()
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)

                                        if isChecked {
                                            Button(action: {
                                                storage.settings.modelName = model
                                            }) {
                                                Text(isCurrentDefault ? "当前使用" : "设为当前")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundColor(isCurrentDefault ? .white : theme.accent)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(isCurrentDefault ? theme.accent : theme.accent.opacity(0.12))
                                                    .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 11)
                                    .background(isChecked ? theme.accent.opacity(0.08) : theme.cardBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(isChecked ? theme.accent.opacity(0.45) : theme.border, lineWidth: 1)
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                }
            }
            .navigationTitle("勾选启用模型 (\(storage.settings.activeProfile?.name ?? "当前配置"))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismissKeyboard()
                        showingModelManagerSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addCustomModel() {
        let trimmed = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        storage.settings.updateActiveProfile { profile in
            if !profile.availableModels.contains(trimmed) {
                profile.availableModels.insert(trimmed, at: 0)
            }
            if !profile.enabledModels.contains(trimmed) {
                profile.enabledModels.insert(trimmed, at: 0)
            }
        }
        storage.settings.modelName = trimmed
        customModelInput = ""
    }

    private func toggleModelSelection(_ model: String) {
        storage.settings.updateActiveProfile { profile in
            if let idx = profile.enabledModels.firstIndex(of: model) {
                profile.enabledModels.remove(at: idx)
            } else {
                profile.enabledModels.append(model)
            }
        }
    }

    private func selectAllFiltered(_ models: [String]) {
        storage.settings.updateActiveProfile { profile in
            var set = Set(profile.enabledModels)
            for m in models {
                set.insert(m)
            }
            profile.enabledModels = profile.availableModels.filter { set.contains($0) }
            for m in set where !profile.enabledModels.contains(m) {
                profile.enabledModels.append(m)
            }
        }
    }

    private func deselectAllFiltered(_ models: [String]) {
        let removeSet = Set(models)
        storage.settings.updateActiveProfile { profile in
            profile.enabledModels.removeAll { removeSet.contains($0) }
        }
    }

    private func fetchModels() {
        dismissKeyboard()
        fetchErrorMessage = nil
        fetchSuccessMessage = nil
        isFetchingModels = true
        let targetSettings = storage.settings
        Task {
            do {
                let models = try await OpenAIService.shared.fetchModels(settings: targetSettings)
                await MainActor.run {
                    storage.settings.updateActiveProfile { profile in
                        profile.availableModels = models
                        let validPrevious = profile.enabledModels.filter { models.contains($0) }
                        if validPrevious.isEmpty {
                            profile.enabledModels = models
                        } else {
                            profile.enabledModels = validPrevious
                        }
                    }
                    if let firstEnabled = storage.settings.enabledModels.first,
                       !storage.settings.enabledModels.contains(storage.settings.modelName) {
                        storage.settings.modelName = firstEnabled
                    }
                    fetchSuccessMessage = "已获取 \(models.count) 个模型，已启用 \(storage.settings.enabledModels.count) 个"
                    isFetchingModels = false
                    showingModelManagerSheet = true
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
