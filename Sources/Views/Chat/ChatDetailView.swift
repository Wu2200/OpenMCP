import SwiftUI
import UIKit

struct ChatDetailView: View {
    @EnvironmentObject var storage: DataStorage
    let conversationId: String
    @StateObject private var coordinator = AgentCoordinator()
    @State private var inputText: String = ""
    @State private var showingToolsSheet: Bool = false
    @State private var selectedTurnId: String? = nil
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
            return Array(storage.settings.availableModels.prefix(25))
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

            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ZStack(alignment: .bottomTrailing) {
                        ScrollView {
                            if displayTurns.isEmpty && !coordinator.isGenerating {
                                emptyConversationHero
                                    .padding(.horizontal, 14)
                                    .padding(.top, 24)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        handleBackgroundTap()
                                    }
                            } else {
                                LazyVStack(spacing: 12) {
                                    let turns = displayTurns
                                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                                        let isLastAssistant = (index == turns.count - 1 && turn.role == .assistant)
                                        MessageBubbleView(
                                            turn: turn,
                                            modelName: storage.settings.modelName,
                                            isGenerating: coordinator.isGenerating,
                                            isActiveGeneratingTurn: coordinator.isGenerating && isLastAssistant,
                                            statusText: coordinator.statusText,
                                            isSelected: selectedTurnId == turn.id,
                                            onSelectToggle: {
                                                if isInputFocused {
                                                    dismissKeyboard()
                                                }
                                                withAnimation(.easeInOut(duration: 0.16)) {
                                                    if selectedTurnId == turn.id {
                                                        selectedTurnId = nil
                                                    } else {
                                                        selectedTurnId = turn.id
                                                    }
                                                }
                                            },
                                            onEditSave: { newContent in
                                                dismissKeyboard()
                                                selectedTurnId = nil
                                                storage.updateMessageContent(
                                                    conversationId: conversationId,
                                                    messageId: turn.primaryMessageId,
                                                    newContent: newContent
                                                )
                                            },
                                            onEditAndResend: { newContent in
                                                dismissKeyboard()
                                                selectedTurnId = nil
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
                                                selectedTurnId = nil
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
                                                if selectedTurnId == turn.id {
                                                    selectedTurnId = nil
                                                }
                                                storage.deleteMessageTurn(
                                                    conversationId: conversationId,
                                                    messageIds: turn.underlyingMessageIds
                                                )
                                            }
                                        )
                                        .id(turn.id)
                                    }

                                    if coordinator.isGenerating && (displayTurns.last?.role != .assistant) {
                                        generatingStatusRow
                                            .id("generating_status")
                                    }

                                    if let err = coordinator.errorMessage {
                                        errorBanner(err)
                                            .id("error_status")
                                    }

                                    Color.clear
                                        .frame(height: 4)
                                        .id("bottom_anchor")
                                }
                                .padding(.horizontal, 10)
                                .padding(.top, 10)
                                .padding(.bottom, 14)
                            }
                        }
                        .background(
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    handleBackgroundTap()
                                }
                        )
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: currentConversation.messages.count) { _ in
                            scrollToBottom(proxy: proxy)
                        }
                        .onChange(of: currentConversation.messages.last?.content) { _ in
                            scrollToBottom(proxy: proxy)
                        }
                        .onChange(of: coordinator.statusText) { _ in
                            scrollToBottom(proxy: proxy)
                        }

                        if !displayTurns.isEmpty {
                            Button(action: {
                                scrollToBottom(proxy: proxy)
                            }) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(theme.primaryText)
                                    .frame(width: 32, height: 32)
                                    .background(theme.cardBackground)
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle()
                                            .stroke(theme.border, lineWidth: 1)
                                    )
                                    .shadow(color: Color.black.opacity(theme.isDark ? 0.28 : 0.08), radius: 5, x: 0, y: 2)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 14)
                            .padding(.bottom, 8)
                        }
                    }

                    composerDock
                }
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
                        Button(role: .destructive, action: {
                            selectedTurnId = nil
                            storage.clearConversationMessages(id: conversationId)
                        }) {
                            Label("清空当前对话消息", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .frame(width: 30, height: 30)
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
                        .frame(width: 64, height: 64)
                    Image(systemName: "sparkles")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(theme.accent)
                }

                Text("有什么可以帮你的？")
                    .font(.system(size: 19, weight: .bold))
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

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(starterPrompts, id: \.title) { item in
                    Button(action: {
                        sendSpecificPrompt(item.prompt)
                    }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: item.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(theme.accent)
                                .frame(width: 30, height: 30)
                                .background(theme.accent.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

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
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .stroke(theme.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var generatingStatusRow: some View {
        HStack(alignment: .top, spacing: 6) {
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.14))
                    .frame(width: 24, height: 24)
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accent)
            }
            .padding(.top, 2)

            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(theme.accent)
                Text(coordinator.statusText.isEmpty ? "思考中..." : coordinator.statusText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            )
        }
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
        .padding(12)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
        )
        .padding(.leading, 30)
    }

    private var composerDock: some View {
        let canSend = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !coordinator.isGenerating

        return VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("在这里输入你的问题...", text: $inputText, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .font(.system(size: 15.5))
                    .foregroundColor(theme.primaryText)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !coordinator.isGenerating {
                            isInputFocused = true
                        }
                    }
                    .disabled(coordinator.isGenerating)

                Button(action: sendMessage) {
                    ZStack {
                        Circle()
                            .fill(canSend ? theme.accent : theme.elevatedBackground)
                            .frame(width: 32, height: 32)

                        Image(systemName: coordinator.isGenerating ? "hourglass" : "arrow.up")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundColor(canSend ? .white : theme.mutedText)
                    }
                }
                .disabled(!canSend)
            }

            HStack(spacing: 12) {
                Menu {
                    Section("快捷提问模板") {
                        ForEach(starterPrompts, id: \.title) { item in
                            Button(action: {
                                inputText = item.prompt
                            }) {
                                Label(item.title, systemImage: item.icon)
                            }
                        }
                    }

                    Divider()

                    Button(role: .destructive, action: {
                        selectedTurnId = nil
                        storage.clearConversationMessages(id: conversationId)
                    }) {
                        Label("清空当前对话", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 17.5, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }

                Button(action: {
                    dismissKeyboard()
                    showingToolsSheet = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 13.5, weight: .medium))
                        if activeToolCount > 0 {
                            Text("\(activeToolCount)")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        }
                    }
                    .foregroundColor(activeToolCount > 0 ? theme.accent : theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(activeToolCount > 0 ? theme.accent.opacity(0.12) : Color.clear)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if isInputFocused {
                    Button(action: dismissKeyboard) {
                        HStack(spacing: 3) {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 12.5, weight: .medium))
                            Text("收起")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

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
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "atom")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(theme.accent)
                        Text(storage.settings.modelName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                            .frame(maxWidth: 140, alignment: .trailing)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                    }
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(theme.isDark ? 0.25 : 0.05), radius: 6, x: 0, y: 2)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(theme.background)
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

    private func handleBackgroundTap() {
        if isInputFocused {
            dismissKeyboard()
        }
        if selectedTurnId != nil {
            withAnimation(.easeInOut(duration: 0.16)) {
                selectedTurnId = nil
            }
        }
    }

    private func dismissKeyboard() {
        isInputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func sendMessage() {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        inputText = ""
        selectedTurnId = nil
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
        selectedTurnId = nil
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
            if let last = displayTurns.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            } else if coordinator.isGenerating {
                proxy.scrollTo("generating_status", anchor: .bottom)
            }
        }
    }
}
