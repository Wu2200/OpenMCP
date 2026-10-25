import SwiftUI
import UIKit

struct ChatDetailView: View {
    @EnvironmentObject var storage: DataStorage
    let conversationId: String
    @StateObject private var coordinator = AgentCoordinator()
    @State private var inputText: String = ""
    @State private var showingToolsSheet: Bool = false
    @FocusState private var isInputFocused: Bool

    private var theme: AppThemePalette {
        storage.settings.currentTheme
    }

    private var currentConversation: Conversation {
        storage.conversations.first(where: { $0.id == conversationId }) ?? Conversation(title: "对话", messages: [])
    }

    private var displayTurns: [MessageDisplayTurn] {
        var turns: [MessageDisplayTurn] = []
        let messages = currentConversation.messages

        for msg in messages {
            switch msg.role {
            case .user:
                turns.append(
                    MessageDisplayTurn(
                        id: msg.id,
                        role: .user,
                        primaryMessageId: msg.id,
                        content: msg.content,
                        toolCalls: [],
                        createdAt: msg.createdAt,
                        underlyingMessageIds: [msg.id]
                    )
                )
            case .assistant:
                if let lastIdx = turns.indices.last, turns[lastIdx].role == .assistant {
                    if let calls = msg.toolCalls, !calls.isEmpty {
                        turns[lastIdx].toolCalls.append(contentsOf: calls)
                    }
                    let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        if turns[lastIdx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            turns[lastIdx].content = msg.content
                        } else {
                            turns[lastIdx].content += "\n\n" + msg.content
                        }
                        turns[lastIdx].primaryMessageId = msg.id
                    }
                    turns[lastIdx].underlyingMessageIds.append(msg.id)
                } else {
                    turns.append(
                        MessageDisplayTurn(
                            id: msg.id,
                            role: .assistant,
                            primaryMessageId: msg.id,
                            content: msg.content,
                            toolCalls: msg.toolCalls ?? [],
                            createdAt: msg.createdAt,
                            underlyingMessageIds: [msg.id]
                        )
                    )
                }
            case .tool:
                if let lastIdx = turns.indices.last, turns[lastIdx].role == .assistant {
                    turns[lastIdx].underlyingMessageIds.append(msg.id)
                }
            case .system:
                break
            }
        }
        return turns
    }

    private var activeToolCount: Int {
        storage.servers.filter { $0.isEnabled }.reduce(0) { $0 + $1.tools.filter { $0.isEnabled }.count }
    }

    private var quickModelOptions: [String] {
        if !storage.settings.availableModels.isEmpty {
            return Array(storage.settings.availableModels.prefix(20))
        }
        return [storage.settings.modelName, "gpt-4o", "gpt-4o-mini", "deepseek-chat", "deepseek-reasoner"]
            .reduce(into: [String]()) { res, item in
                if !res.contains(item) { res.append(item) }
            }
    }

    private let starterPrompts: [(icon: String, title: String, prompt: String)] = [
        ("sparkles", "代码架构与重构建议", "请帮我分析项目的核心结构，并给出优雅的现代重构方案。"),
        ("wrench.and.screwdriver.fill", "调用 MCP 工具执行任务", "请检查当前已启用的 MCP 工具，并告诉我你可以帮我完成哪些自动化操作。"),
        ("doc.text.magnifyingglass", "深度排查问题根因", "遇到复杂 Bug 时，请帮我按照调用链与数据流定位真实根因。"),
        ("paintbrush.pointed.fill", "UI 与交互体验设计", "如何设计一套柔和护眼、层次清晰的 iOS 原生界面配色与排版？")
    ]

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()
                .onTapGesture {
                    dismissKeyboard()
                }

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        if displayTurns.isEmpty && !coordinator.isGenerating {
                            emptyConversationHero
                                .padding(.horizontal, 16)
                                .padding(.top, 28)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    dismissKeyboard()
                                }
                        } else {
                            LazyVStack(spacing: 16) {
                                ForEach(displayTurns) { turn in
                                    MessageBubbleView(
                                        turn: turn,
                                        modelName: storage.settings.modelName,
                                        isGenerating: coordinator.isGenerating,
                                        onEditSave: { newContent in
                                            dismissKeyboard()
                                            storage.updateMessageContent(
                                                conversationId: conversationId,
                                                messageId: turn.primaryMessageId,
                                                newContent: newContent
                                            )
                                        },
                                        onEditAndResend: { newContent in
                                            dismissKeyboard()
                                            Task {
                                                await coordinator.retryFromMessage(
                                                    conversationId: conversationId,
                                                    messageId: turn.primaryMessageId,
                                                    newPrompt: newContent,
                                                    settings: storage.settings,
                                                    servers: storage.servers
                                                )
                                            }
                                        },
                                        onRetry: {
                                            dismissKeyboard()
                                            Task {
                                                await coordinator.retryFromMessage(
                                                    conversationId: conversationId,
                                                    messageId: turn.primaryMessageId,
                                                    settings: storage.settings,
                                                    servers: storage.servers
                                                )
                                            }
                                        },
                                        onDelete: {
                                            dismissKeyboard()
                                            storage.deleteMessageTurn(
                                                conversationId: conversationId,
                                                messageIds: turn.underlyingMessageIds
                                            )
                                        }
                                    )
                                    .id(turn.id)
                                }

                                if coordinator.isGenerating {
                                    generatingStatusBanner
                                        .id("generating_status")
                                }

                                if let err = coordinator.errorMessage {
                                    errorBanner(err)
                                        .id("error_status")
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 20)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            dismissKeyboard()
                        }
                    )
                    .onChange(of: currentConversation.messages.count) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: coordinator.statusText) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                }

                composerDock
            }
        }
        .navigationTitle(currentConversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    if isInputFocused {
                        Button(action: dismissKeyboard) {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(theme.accent.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }

                    Menu {
                        Section("切换对话模型") {
                            ForEach(quickModelOptions, id: \.self) { m in
                                Button(action: {
                                    storage.settings.modelName = m
                                }) {
                                    HStack {
                                        Text(m)
                                        if storage.settings.modelName == m {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }

                        Divider()

                        Button(role: .destructive, action: {
                            storage.clearConversationMessages(id: conversationId)
                        }) {
                            Label("清空当前对话消息", systemImage: "trash")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "cpu")
                                .font(.system(size: 11, weight: .semibold))
                            Text(storage.settings.modelName)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .frame(maxWidth: 110)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(theme.accent.opacity(0.12))
                        .clipShape(Capsule())
                    }
                }
            }
        }
        .sheet(isPresented: $showingToolsSheet) {
            activeToolsSheet
        }
    }

    private var emptyConversationHero: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(theme.accent.opacity(0.14))
                        .frame(width: 66, height: 66)
                    Image(systemName: "sparkles")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(theme.accent)
                }

                Text("有什么可以帮你的？")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(theme.primaryText)

                HStack(spacing: 8) {
                    Label(storage.settings.modelName, systemImage: "cpu")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(theme.accent.opacity(0.12))
                        .clipShape(Capsule())

                    Label("\(activeToolCount) 个 MCP 工具启用", systemImage: "wrench.and.screwdriver")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(theme.cardBackground)
                        .clipShape(Capsule())
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(starterPrompts, id: \.title) { item in
                    Button(action: {
                        sendSpecificPrompt(item.prompt)
                    }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: item.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(theme.accent)
                                .frame(width: 32, height: 32)
                                .background(theme.accent.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)

                            Text(item.prompt)
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var generatingStatusBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.85)
                .tint(theme.accent)
            Text(coordinator.statusText.isEmpty ? "正在思考..." : coordinator.statusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundColor(.red)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)

                if let lastTurn = displayTurns.last {
                    Button(action: {
                        dismissKeyboard()
                        Task {
                            await coordinator.retryFromMessage(
                                conversationId: conversationId,
                                messageId: lastTurn.primaryMessageId,
                                settings: storage.settings,
                                servers: storage.servers
                            )
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("立即重试")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(theme.accent)
                        .clipShape(Capsule())
                    }
                }
            }
            Spacer()
        }
        .padding(14)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
        )
    }

    private var composerDock: some View {
        let canSend = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !coordinator.isGenerating

        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: {
                    dismissKeyboard()
                    showingToolsSheet = true
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: 11))
                        Text(activeToolCount > 0 ? "工具 (\(activeToolCount))" : "未启用工具")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(activeToolCount > 0 ? theme.accent : theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(activeToolCount > 0 ? theme.accent.opacity(0.12) : theme.cardBackground)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(theme.border, lineWidth: 1)
                    )
                }

                Spacer()

                if isInputFocused {
                    Button(action: dismissKeyboard) {
                        HStack(spacing: 4) {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 11, weight: .semibold))
                            Text("收起键盘")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(theme.cardBackground)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(theme.border, lineWidth: 1)
                        )
                    }
                } else if !displayTurns.isEmpty {
                    Text("\(displayTurns.count) 条消息")
                        .font(.system(size: 11))
                        .foregroundColor(theme.mutedText)
                }
            }
            .padding(.horizontal, 16)

            HStack(alignment: .bottom, spacing: 10) {
                TextField("输入问题或指令，支持自动调用 MCP 工具...", text: $inputText, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .font(.system(size: 15))
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .disabled(coordinator.isGenerating)

                Button(action: sendMessage) {
                    ZStack {
                        Circle()
                            .fill(canSend ? theme.accent : theme.elevatedBackground)
                            .frame(width: 36, height: 36)

                        Image(systemName: coordinator.isGenerating ? "hourglass" : "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(canSend ? .white : theme.mutedText)
                    }
                }
                .disabled(!canSend)
                .padding(.trailing, 6)
                .padding(.bottom, 5)
            }
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .padding(.top, 8)
        .background(
            theme.background
                .overlay(
                    Rectangle()
                        .fill(theme.border.opacity(0.6))
                        .frame(height: 0.5),
                    alignment: .top
                )
        )
    }

    private var activeToolsSheet: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                if storage.servers.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 32))
                            .foregroundColor(theme.mutedText)
                        Text("尚未配置任何 MCP 服务")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text("请前往底部「MCP 工具」标签页添加服务。")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryText)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(storage.servers) { server in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text(server.name)
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundColor(theme.primaryText)
                                        Spacer()
                                        Toggle("启用", isOn: Binding(
                                            get: { server.isEnabled },
                                            set: { val in
                                                var s = server
                                                s.isEnabled = val
                                                storage.addOrUpdateServer(s)
                                            }
                                        ))
                                        .labelsHidden()
                                        .tint(theme.accent)
                                    }

                                    Text("\(server.tools.filter { $0.isEnabled }.count) / \(server.tools.count) 个工具已开启")
                                        .font(.system(size: 12))
                                        .foregroundColor(theme.secondaryText)
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
                        .padding(16)
                    }
                }
            }
            .navigationTitle("对话可用工具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        showingToolsSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func dismissKeyboard() {
        isInputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func sendMessage() {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        inputText = ""
        dismissKeyboard()
        Task {
            await coordinator.sendMessage(
                conversationId: conversationId,
                userPrompt: prompt,
                settings: storage.settings,
                servers: storage.servers
            )
        }
    }

    private func sendSpecificPrompt(_ prompt: String) {
        dismissKeyboard()
        Task {
            await coordinator.sendMessage(
                conversationId: conversationId,
                userPrompt: prompt,
                settings: storage.settings,
                servers: storage.servers
            )
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if coordinator.isGenerating {
                proxy.scrollTo("generating_status", anchor: .bottom)
            } else if let last = displayTurns.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}
