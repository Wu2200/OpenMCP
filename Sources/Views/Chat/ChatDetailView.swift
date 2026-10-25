import SwiftUI

struct ChatDetailView: View {
    @EnvironmentObject var storage: DataStorage
    let conversationId: String
    @StateObject private var coordinator = AgentCoordinator()
    @State private var inputText: String = ""
    @State private var showingToolsSheet: Bool = false

    private var theme: AppThemePalette {
        storage.settings.currentTheme
    }

    private var currentConversation: Conversation {
        storage.conversations.first(where: { $0.id == conversationId }) ?? Conversation(title: "对话", messages: [])
    }

    private var visibleMessages: [ChatMessage] {
        currentConversation.messages.filter { $0.role != .tool }
    }

    private var activeToolCount: Int {
        storage.servers.filter { $0.isEnabled }.reduce(0) { $0 + $1.tools.filter { $0.isEnabled }.count }
    }

    private var quickModelOptions: [String] {
        if !storage.settings.availableModels.isEmpty {
            return storage.settings.availableModels
        }
        return ["gpt-4o", "gpt-4o-mini", "deepseek-chat", "deepseek-reasoner", "claude-3-5-sonnet-latest"]
    }

    private let starterPrompts: [(icon: String, title: String, prompt: String)] = [
        ("wand.and.stars", "代码架构与重构建议", "请帮我梳理如何设计一套清晰、高可维护性的移动端模块化架构，并给出核心代码示例。"),
        ("terminal.fill", "排查问题与根因分析", "我在开发过程中遇到了接口响应异常与界面状态不同步的问题，请告诉我系统化的排查思路。"),
        ("doc.text.magnifyingglass", "提炼总结与结构化输出", "请帮我将一段复杂的技术方案提炼为要点清晰、包含对比表格与执行步骤的总结文档。"),
        ("cpu.fill", "测试可用 MCP 工具", "请检查你目前挂载了哪些可用的工具，并向我简要介绍每个工具的用途。")
    ]

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            if visibleMessages.isEmpty {
                                welcomeStudioView
                            } else {
                                ForEach(visibleMessages) { msg in
                                    MessageBubbleView(message: msg, modelName: storage.settings.modelName)
                                        .id(msg.id)
                                }
                            }

                            if coordinator.isGenerating {
                                generatingStatusCard
                                    .id("generating_indicator")
                            }

                            if let err = coordinator.errorMessage {
                                errorBannerCard(err)
                                    .id("error_indicator")
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 20)
                    }
                    .onChange(of: currentConversation.messages.count) { _ in
                        if let last = visibleMessages.last {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: coordinator.statusText) { _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("generating_indicator", anchor: .bottom)
                        }
                    }
                }

                composerDock
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(currentConversation.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Menu {
                        ForEach(quickModelOptions, id: \.self) { model in
                            Button(action: {
                                storage.settings.modelName = model
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
                            Circle()
                                .fill(theme.accent)
                                .frame(width: 6, height: 6)
                            Text(storage.settings.modelName)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(theme.elevatedBackground)
                        .clipShape(Capsule())
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: { showingToolsSheet = true }) {
                        Label("已挂载工具 (\(activeToolCount))", systemImage: "cpu")
                    }

                    if !visibleMessages.isEmpty {
                        Button(role: .destructive, action: {
                            storage.clearConversationMessages(id: conversationId)
                        }) {
                            Label("清空当前对话", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .frame(width: 32, height: 32)
                        .background(theme.cardBackground)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(theme.border, lineWidth: 1))
                }
            }
        }
        .sheet(isPresented: $showingToolsSheet) {
            activeToolsQuickSheet
        }
    }

    private var welcomeStudioView: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(theme.accent.opacity(0.14))
                        .frame(width: 64, height: 64)
                    Image(systemName: "sparkles")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(theme.accent)
                }

                Text("有什么可以帮你的？")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundColor(theme.primaryText)

                HStack(spacing: 8) {
                    Label(storage.settings.modelName, systemImage: "cpu")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(theme.accent.opacity(0.12))
                        .clipShape(Capsule())

                    Button(action: { showingToolsSheet = true }) {
                        Label("\(activeToolCount) 个 MCP 工具启用", systemImage: "wrench.and.screwdriver.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(theme.cardBackground)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(theme.border, lineWidth: 1))
                    }
                }
            }
            .padding(.top, 24)

            VStack(alignment: .leading, spacing: 10) {
                Text("快捷提问灵感")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.mutedText)
                    .padding(.horizontal, 4)

                ForEach(0..<starterPrompts.count, id: \.self) { idx in
                    let item = starterPrompts[idx]
                    Button(action: {
                        inputText = item.prompt
                        sendMessage()
                    }) {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(theme.accent.opacity(0.12))
                                    .frame(width: 36, height: 36)
                                Image(systemName: item.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(theme.accent)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(theme.primaryText)
                                Text(item.prompt)
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.mutedText)
                        }
                        .padding(13)
                        .background(theme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(theme.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var generatingStatusCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(theme.accent)
                .scaleEffect(0.9)

            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.statusText.isEmpty ? "正在思考并组织回答..." : coordinator.statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("使用 \(storage.settings.modelName) 处理中")
                    .font(.system(size: 11))
                    .foregroundColor(theme.mutedText)
            }

            Spacer()

            Button(action: { coordinator.cancel() }) {
                Text("停止")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(14)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.accent.opacity(0.35), lineWidth: 1)
        )
    }

    private func errorBannerCard(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 4) {
                Text("请求发生异常")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.red)
                Text(err)
                    .font(.system(size: 12))
                    .foregroundColor(theme.primaryText)
            }
            Spacer()
        }
        .padding(14)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.red.opacity(0.35), lineWidth: 1)
        )
    }

    private var composerDock: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: { showingToolsSheet = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: 11))
                        Text(activeToolCount > 0 ? "MCP 工具 (\(activeToolCount))" : "未启用工具")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(activeToolCount > 0 ? theme.accent : theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(activeToolCount > 0 ? theme.accent.opacity(0.12) : theme.cardBackground)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(activeToolCount > 0 ? theme.accent.opacity(0.3) : theme.border, lineWidth: 1)
                    )
                }

                Spacer()

                if !inputText.isEmpty {
                    Button(action: { inputText = "" }) {
                        Text("清空输入")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.mutedText)
                    }
                }
            }
            .padding(.horizontal, 4)

            HStack(alignment: .bottom, spacing: 10) {
                TextField("输入问题或指令，支持调用 MCP 工具...", text: $inputText, axis: .vertical)
                    .lineLimit(1...6)
                    .font(.system(size: 15))
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(theme.elevatedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if coordinator.isGenerating {
                    Button(action: { coordinator.cancel() }) {
                        ZStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 40, height: 40)
                            Image(systemName: "stop.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                } else {
                    let canSend = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button(action: sendMessage) {
                        ZStack {
                            Circle()
                                .fill(canSend ? theme.accent : theme.elevatedBackground)
                                .frame(width: 40, height: 40)
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(canSend ? .white : theme.mutedText)
                        }
                    }
                    .disabled(!canSend)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(theme.cardBackground)
        .overlay(
            Rectangle()
                .fill(theme.border)
                .frame(height: 1),
            alignment: .top
        )
    }

    private var activeToolsQuickSheet: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 12) {
                        if storage.servers.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "cpu")
                                    .font(.system(size: 32))
                                    .foregroundColor(theme.mutedText)
                                Text("尚未添加任何 MCP 服务")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(theme.primaryText)
                                Text("请前往底部「MCP 工具」标签页添加服务。")
                                    .font(.system(size: 13))
                                    .foregroundColor(theme.secondaryText)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else {
                            ForEach(storage.servers) { server in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(server.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(theme.primaryText)
                                        Text("\(server.tools.filter { $0.isEnabled }.count) / \(server.tools.count) 个工具已启用")
                                            .font(.system(size: 12))
                                            .foregroundColor(theme.secondaryText)
                                    }
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { server.isEnabled },
                                        set: { newVal in
                                            var updated = server
                                            updated.isEnabled = newVal
                                            storage.addOrUpdateServer(updated)
                                        }
                                    ))
                                    .labelsHidden()
                                    .tint(theme.accent)
                                }
                                .padding(14)
                                .background(theme.cardBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(theme.border, lineWidth: 1)
                                )
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("对话工具开关")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showingToolsSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        if currentConversation.messages.isEmpty {
            var updated = currentConversation
            updated.title = String(text.prefix(20))
            storage.updateConversation(updated)
        }
        Task {
            await coordinator.sendMessage(
                conversationId: conversationId,
                userPrompt: text,
                settings: storage.settings,
                servers: storage.servers
            )
        }
    }
}
