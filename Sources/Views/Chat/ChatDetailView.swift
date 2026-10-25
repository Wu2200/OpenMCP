import SwiftUI
import UIKit

struct ChatDetailView: View {
    @EnvironmentObject var storage: DataStorage
    let conversationId: String
    @ObservedObject private var coordinator: AgentCoordinator
    @State private var inputText: String = ""
    @State private var pendingAttachments: [ChatAttachment] = []
    @State private var showingToolsSheet: Bool = false
    @State private var showingLogViewerSheet: Bool = false
    @State private var showingPhotoPicker: Bool = false
    @State private var showingCameraPicker: Bool = false
    @State private var showingDocumentPicker: Bool = false
    @State private var previewingStagedAttachment: ChatAttachment? = nil
    @State private var selectedTurnId: String? = nil
    @State private var pendingDeleteTurn: MessageDisplayTurn? = nil
    @State private var showingClearConversationAlert: Bool = false
    @State private var autoFollowOutput: Bool = true
    @State private var manualScrollTrigger: Int = 0
    @State private var isChatVisible: Bool = true
    @FocusState private var isInputFocused: Bool

    init(conversationId: String) {
        self.conversationId = conversationId
        self._coordinator = ObservedObject(wrappedValue: AgentCoordinator.coordinator(for: conversationId))
    }

    private var theme: AppThemePalette {
        storage.settings.currentTheme
    }

    private var currentConversation: Conversation {
        storage.conversations.first(where: { $0.id == conversationId }) ?? Conversation(title: "对话", messages: [])
    }

    private var effectiveSettings: OpenAISettings {
        storage.settings.resolvedSettings(for: currentConversation)
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
                        reasoningContent: "",
                        attachments: msg.attachments ?? [],
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
                    if let r = msg.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
                        if turns[lastIdx].reasoningContent.isEmpty {
                            turns[lastIdx].reasoningContent = r
                        } else {
                            turns[lastIdx].reasoningContent += "\n\n" + r
                        }
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
                            reasoningContent: msg.reasoningContent ?? "",
                            attachments: msg.attachments ?? [],
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

    private let starterPrompts: [(icon: String, title: String, prompt: String)] = [
        ("sparkles", "代码架构与重构建议", "请帮我分析项目的核心结构，并给出优雅的现代重构方案。"),
        ("wrench.and.screwdriver.fill", "调用 MCP 工具执行任务", "请检查当前已启用的 MCP 工具，并告诉我你可以帮我完成哪些自动化操作。"),
        ("doc.text.magnifyingglass", "深度排查问题根因", "遇到复杂 Bug 时，请帮我按照调用链与数据流定位真实根因。"),
        ("paintbrush.pointed.fill", "UI 与交互体验设计", "如何设计一套柔和护眼、层次清晰的 iOS 原生界面配色与排版？")
    ]

    var body: some View {
        GeometryReader { geo in
            let viewportWidth = max(320, geo.size.width)
            let rowAvailableWidth = max(280, viewportWidth - 20)

            ZStack {
                theme.background
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleBackgroundTap()
                    }

                VStack(spacing: 0) {
                    ZStack(alignment: .bottomTrailing) {
                        ScrollView(.vertical, showsIndicators: true) {
                            if displayTurns.isEmpty && !coordinator.isGenerating {
                                emptyConversationHero
                                    .padding(.horizontal, 14)
                                    .padding(.top, 24)
                                    .frame(width: viewportWidth)
                                    .frame(minHeight: max(300, geo.size.height - 130), alignment: .top)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        handleBackgroundTap()
                                    }
                            } else {
                                VStack(spacing: 12) {
                                    let turns = displayTurns
                                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                                        let isLastAssistant = (index == turns.count - 1 && turn.role == .assistant)
                                        let activeGenerating = coordinator.isGenerating && isLastAssistant

                                        MessageBubbleView(
                                            turn: turn,
                                            theme: theme,
                                            availableWidth: rowAvailableWidth,
                                            modelName: effectiveSettings.modelName,
                                            isGenerating: coordinator.isGenerating,
                                            isActiveGeneratingTurn: activeGenerating,
                                            statusText: activeGenerating ? coordinator.statusText : "",
                                            thinkingStartTime: activeGenerating ? coordinator.thinkingStartTime : nil,
                                            streamingState: coordinator.streamingState,
                                            isSelected: selectedTurnId == turn.id,
                                            onSelectToggle: {
                                                if isInputFocused {
                                                    dismissKeyboard()
                                                }
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    if selectedTurnId == turn.id {
                                                        selectedTurnId = nil
                                                    } else {
                                                        selectedTurnId = turn.id
                                                    }
                                                }
                                            },
                                            onDismissSelection: {
                                                handleBackgroundTap()
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
                                                autoFollowOutput = true
                                                coordinator.streamingState.setDisplayPaused(false)
                                                manualScrollTrigger &+= 1
                                                coordinator.startRetryFromMessage(
                                                    conversationId: conversationId,
                                                    messageId: turn.primaryMessageId,
                                                    newPrompt: newContent,
                                                    settings: storage.settings,
                                                    servers: storage.servers
                                                )
                                            },
                                            onRetry: {
                                                dismissKeyboard()
                                                selectedTurnId = nil
                                                autoFollowOutput = true
                                                coordinator.streamingState.setDisplayPaused(false)
                                                manualScrollTrigger &+= 1
                                                coordinator.startRetryFromMessage(
                                                    conversationId: conversationId,
                                                    messageId: turn.primaryMessageId,
                                                    settings: storage.settings,
                                                    servers: storage.servers
                                                )
                                            },
                                            onDelete: {
                                                dismissKeyboard()
                                                pendingDeleteTurn = turn
                                            }
                                        )
                                        .frame(width: rowAvailableWidth)
                                        .id(turn.id)
                                    }

                                    if coordinator.isGenerating && (displayTurns.last?.role != .assistant) {
                                        generatingStatusRow
                                            .frame(width: rowAvailableWidth, alignment: .leading)
                                            .id("generating_status")
                                    }

                                    if let err = coordinator.errorMessage {
                                        errorBanner(err)
                                            .frame(width: rowAvailableWidth)
                                            .id("error_status")
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.top, 10)
                                .padding(.bottom, 16)
                                .frame(width: viewportWidth)
                                .background(
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            handleBackgroundTap()
                                        }
                                )
                                .background(
                                    ChatScrollViewIntrospector(
                                        isGenerating: coordinator.isGenerating,
                                        autoFollowOutput: autoFollowOutput,
                                        isViewActive: isChatVisible,
                                        manualScrollTrigger: manualScrollTrigger,
                                        onUserTouchBegan: {
                                            coordinator.streamingState.setDisplayPaused(true)
                                        },
                                        onUserDragUp: {
                                            if autoFollowOutput {
                                                autoFollowOutput = false
                                            }
                                        },
                                        onReachBottom: {
                                            if !autoFollowOutput {
                                                autoFollowOutput = true
                                            }
                                            coordinator.streamingState.setDisplayPaused(false)
                                        },
                                        onScrollSettled: {
                                            coordinator.streamingState.setDisplayPaused(false)
                                        }
                                    )
                                )
                            }
                        }
                        .frame(width: viewportWidth)
                        .scrollDismissesKeyboard(.interactively)
                        .overlay(alignment: .bottom) {
                            LinearGradient(
                                stops: [
                                    .init(color: theme.background.opacity(0), location: 0),
                                    .init(color: theme.background.opacity(0.68), location: 0.55),
                                    .init(color: theme.background, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 40)
                            .allowsHitTesting(false)
                        }
                        .onChange(of: currentConversation.messages.count) { _ in
                            if autoFollowOutput {
                                manualScrollTrigger &+= 1
                            }
                        }
                        .onChange(of: coordinator.isGenerating) { generating in
                            if generating && autoFollowOutput {
                                manualScrollTrigger &+= 1
                            }
                        }

                        if !displayTurns.isEmpty {
                            Button(action: {
                                autoFollowOutput = true
                                coordinator.streamingState.setDisplayPaused(false)
                                manualScrollTrigger &+= 1
                            }) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(autoFollowOutput ? theme.primaryText : theme.accent)
                                    .frame(width: 32, height: 32)
                                    .background(theme.cardBackground)
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle()
                                            .stroke(autoFollowOutput ? theme.border : theme.accent.opacity(0.45), lineWidth: 1)
                                    )
                                    .shadow(color: Color.black.opacity(theme.isDark ? 0.28 : 0.08), radius: 5, x: 0, y: 2)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 14)
                            .padding(.bottom, 8)
                        }
                    }
                    .frame(width: viewportWidth)

                    composerDock(viewportWidth: viewportWidth)
                }
                .frame(width: viewportWidth)
            }
        }
        .onAppear {
            isChatVisible = true
            coordinator.streamingState.setDisplayPaused(false)
            if coordinator.isGenerating && autoFollowOutput {
                manualScrollTrigger &+= 1
            }
        }
        .onDisappear {
            isChatVisible = false
            coordinator.streamingState.setDisplayPaused(false)
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
                        Button(action: {
                            dismissKeyboard()
                            showingLogViewerSheet = true
                        }) {
                            Label("查看本对话日志", systemImage: "doc.text.magnifyingglass")
                        }

                        Button(role: .destructive, action: {
                            dismissKeyboard()
                            showingClearConversationAlert = true
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
        .sheet(isPresented: $showingLogViewerSheet) {
            LogViewerSheet(theme: theme, filterConversationId: conversationId)
        }
        .sheet(isPresented: $showingPhotoPicker) {
            PhotoLibraryPicker { images in
                for (idx, img) in images.enumerated() {
                    if let att = AttachmentProcessor.processUIImage(img, index: pendingAttachments.count + idx + 1) {
                        pendingAttachments.append(att)
                    }
                }
            }
        }
        .sheet(isPresented: $showingCameraPicker) {
            CameraImagePicker { img in
                if let att = AttachmentProcessor.processUIImage(img, index: pendingAttachments.count + 1) {
                    pendingAttachments.append(att)
                }
            }
        }
        .sheet(isPresented: $showingDocumentPicker) {
            DocumentFilePicker { urls in
                for url in urls {
                    if let att = AttachmentProcessor.processFileURL(url) {
                        pendingAttachments.append(att)
                    }
                }
            }
        }
        .sheet(item: $previewingStagedAttachment) { att in
            if att.kind == .image {
                AttachmentImagePreviewSheet(attachment: att, theme: theme)
            } else {
                AttachmentFilePreviewSheet(attachment: att, theme: theme)
            }
        }
        .alert("确认删除此条消息？", isPresented: Binding(
            get: { pendingDeleteTurn != nil },
            set: { if !$0 { pendingDeleteTurn = nil } }
        )) {
            Button("取消", role: .cancel) {
                pendingDeleteTurn = nil
            }
            Button("删除", role: .destructive) {
                if let turn = pendingDeleteTurn {
                    if selectedTurnId == turn.id {
                        selectedTurnId = nil
                    }
                    storage.deleteMessageTurn(
                        conversationId: conversationId,
                        messageIds: turn.underlyingMessageIds
                    )
                }
                pendingDeleteTurn = nil
            }
        } message: {
            Text("删除后该条消息将无法恢复。")
        }
        .alert("确认清空当前对话？", isPresented: $showingClearConversationAlert) {
            Button("取消", role: .cancel) {}
            Button("清空消息", role: .destructive) {
                selectedTurnId = nil
                if coordinator.isGenerating {
                    coordinator.stopGeneration()
                }
                storage.clearConversationMessages(id: conversationId)
            }
        } message: {
            Text("将清空当前对话中的所有历史消息，此操作不可恢复。")
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
                    .foregroundColor(theme.accent)

                HStack(spacing: 8) {
                    Label(effectiveSettings.modelName, systemImage: "cpu")
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

            ThinkingStatusView(
                statusText: coordinator.statusText,
                startDate: coordinator.thinkingStartTime ?? Date(),
                theme: theme,
                isPaused: coordinator.streamingState.isScrollInteracting
            )
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            )

            Spacer(minLength: 36)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleBackgroundTap()
                }
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
                    .contentShape(Capsule())
                    .onTapGesture {
                        dismissKeyboard()
                        autoFollowOutput = true
                        coordinator.streamingState.setDisplayPaused(false)
                        manualScrollTrigger &+= 1
                        coordinator.startRetryFromMessage(
                            conversationId: conversationId,
                            messageId: lastTurn.primaryMessageId,
                            settings: storage.settings,
                            servers: storage.servers
                        )
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

    private func composerDock(viewportWidth: CGFloat) -> some View {
        let hasInput = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
        let canSend = hasInput && !coordinator.isGenerating

        return VStack(alignment: .leading, spacing: 8) {
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { att in
                            stagedAttachmentChip(att)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

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
                        if selectedTurnId != nil {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTurnId = nil
                            }
                        }
                        isInputFocused = true
                    }
                    .onChange(of: inputText) { newValue in
                        if newValue.count >= 650 {
                            let packaged = ChatAttachment.makeLongTextAttachment(
                                from: newValue,
                                index: pendingAttachments.filter { $0.kind == .longText }.count + 1
                            )
                            pendingAttachments.append(packaged)
                            inputText = ""
                        }
                    }

                if coordinator.isGenerating {
                    Button(action: {
                        coordinator.stopGeneration()
                    }) {
                        ZStack {
                            Circle()
                                .fill(theme.accent)
                                .frame(width: 32, height: 32)

                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(Color.white)
                                .frame(width: 11, height: 11)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: {
                        sendMessage()
                    }) {
                        ZStack {
                            Circle()
                                .fill(canSend ? theme.accent : theme.elevatedBackground)
                                .frame(width: 32, height: 32)

                            Image(systemName: "arrow.up")
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundColor(canSend ? .white : theme.mutedText)
                        }
                    }
                    .disabled(!canSend)
                }
            }

            HStack(spacing: 12) {
                Menu {
                    Button(action: {
                        dismissKeyboard()
                        showingPhotoPicker = true
                    }) {
                        Label("图片上传", systemImage: "photo.on.rectangle.angled")
                    }

                    Button(action: {
                        dismissKeyboard()
                        showingCameraPicker = true
                    }) {
                        Label("拍照上传", systemImage: "camera")
                    }

                    Button(action: {
                        dismissKeyboard()
                        showingDocumentPicker = true
                    }) {
                        Label("文件上传", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .fixedSize()

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
                .fixedSize()

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
                    .fixedSize()
                }

                Spacer(minLength: 16)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleBackgroundTap()
                    }

                Menu {
                    let profilesWithModels = storage.settings.providerProfiles.filter { !$0.enabledModels.isEmpty }
                    if profilesWithModels.count > 1 {
                        ForEach(profilesWithModels) { profile in
                            Section(profile.name) {
                                ForEach(profile.enabledModels, id: \.self) { m in
                                    Button(action: {
                                        storage.updateConversationModel(
                                            conversationId: conversationId,
                                            profileId: profile.id,
                                            modelName: m
                                        )
                                    }) {
                                        HStack {
                                            Text(m)
                                            if effectiveSettings.activeProfileId == profile.id && effectiveSettings.modelName == m {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        Section("已启用对话模型") {
                            ForEach(storage.settings.chatSelectableModelEntries, id: \.id) { entry in
                                Button(action: {
                                    storage.updateConversationModel(
                                        conversationId: conversationId,
                                        profileId: entry.profileId,
                                        modelName: entry.model
                                    )
                                }) {
                                    HStack {
                                        Text(entry.model)
                                        if effectiveSettings.activeProfileId == entry.profileId && effectiveSettings.modelName == entry.model {
                                            Image(systemName: "checkmark")
                                        }
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
                        Text(effectiveSettings.modelName)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.elevatedBackground.opacity(0.65))
                    .clipShape(Capsule())
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
        .frame(width: viewportWidth)
        .background(
            theme.background
                .contentShape(Rectangle())
                .onTapGesture {
                    handleBackgroundTap()
                }
        )
    }

    private func stagedAttachmentChip(_ att: ChatAttachment) -> some View {
        HStack(spacing: 7) {
            if att.kind == .image,
               let b64 = att.imageDataBase64,
               let data = Data(base64Encoded: b64),
               let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.accent.opacity(0.14))
                        .frame(width: 32, height: 32)
                    Image(systemName: att.iconName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(theme.accent)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(att.fileName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(att.metadataSummary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: 130, alignment: .leading)

            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundColor(theme.mutedText)
                .padding(2)
                .contentShape(Circle())
                .onTapGesture {
                    pendingAttachments.removeAll { $0.id == att.id }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            previewingStagedAttachment = att
        }
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
            withAnimation(.easeInOut(duration: 0.15)) {
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
        let attachmentsToSend = pendingAttachments
        guard !prompt.isEmpty || !attachmentsToSend.isEmpty else { return }
        inputText = ""
        pendingAttachments = []
        selectedTurnId = nil
        autoFollowOutput = true
        coordinator.streamingState.setDisplayPaused(false)
        manualScrollTrigger &+= 1
        dismissKeyboard()
        coordinator.startSendMessage(
            conversationId: conversationId,
            userPrompt: prompt,
            attachments: attachmentsToSend,
            settings: storage.settings,
            servers: storage.servers
        )
    }

    private func sendSpecificPrompt(_ prompt: String) {
        selectedTurnId = nil
        autoFollowOutput = true
        coordinator.streamingState.setDisplayPaused(false)
        manualScrollTrigger &+= 1
        dismissKeyboard()
        coordinator.startSendMessage(
            conversationId: conversationId,
            userPrompt: prompt,
            settings: storage.settings,
            servers: storage.servers
        )
    }
}

private struct ChatScrollViewIntrospector: UIViewRepresentable {
    var isGenerating: Bool
    var autoFollowOutput: Bool
    var isViewActive: Bool
    var manualScrollTrigger: Int
    var onUserTouchBegan: () -> Void
    var onUserDragUp: () -> Void
    var onReachBottom: () -> Void
    var onScrollSettled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isGenerating: isGenerating,
            autoFollowOutput: autoFollowOutput,
            isViewActive: isViewActive,
            manualScrollTrigger: manualScrollTrigger,
            onUserTouchBegan: onUserTouchBegan,
            onUserDragUp: onUserDragUp,
            onReachBottom: onReachBottom,
            onScrollSettled: onScrollSettled
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coord = context.coordinator
        let wasGenerating = coord.isGenerating
        let wasViewActive = coord.isViewActive
        coord.isGenerating = isGenerating
        coord.autoFollowOutput = autoFollowOutput
        coord.isViewActive = isViewActive
        coord.onUserTouchBegan = onUserTouchBegan
        coord.onUserDragUp = onUserDragUp
        coord.onReachBottom = onReachBottom
        coord.onScrollSettled = onScrollSettled
        let triggerChanged = (coord.manualScrollTrigger != manualScrollTrigger)
        coord.manualScrollTrigger = manualScrollTrigger

        DispatchQueue.main.async {
            coord.attachIfNeeded(from: uiView)
            if !isViewActive {
                coord.cancelActiveAnimation()
            } else if triggerChanged {
                coord.scrollToBottom(force: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    if coord.isViewActive && coord.autoFollowOutput {
                        coord.scrollToBottom(force: false, animated: true)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    if coord.isViewActive && coord.autoFollowOutput {
                        coord.scrollToBottom(force: false, animated: true)
                    }
                }
            } else if wasViewActive != isViewActive && isViewActive && autoFollowOutput {
                scheduleBottomFollow(coord)
            } else if wasGenerating != isGenerating && autoFollowOutput {
                scheduleBottomFollow(coord)
            }
        }
    }

    final class Coordinator: NSObject {
        var isGenerating: Bool
        var autoFollowOutput: Bool
        var isViewActive: Bool
        var manualScrollTrigger: Int
        var onUserTouchBegan: () -> Void
        var onUserDragUp: () -> Void
        var onReachBottom: () -> Void
        var onScrollSettled: () -> Void
        private weak var attachedScrollView: UIScrollView?
        private var contentSizeObservation: NSKeyValueObservation?
        private var lastObservedHeight: CGFloat = 0
        private var scrollSettleWorkItem: DispatchWorkItem?
        private var followAnimator: UIViewPropertyAnimator?
        private var animatedTargetY: CGFloat = 0
        private var userScrollActive = false
        private var panInitialOffsetY: CGFloat = 0

        init(
            isGenerating: Bool,
            autoFollowOutput: Bool,
            isViewActive: Bool,
            manualScrollTrigger: Int,
            onUserTouchBegan: @escaping () -> Void,
            onUserDragUp: @escaping () -> Void,
            onReachBottom: @escaping () -> Void,
            onScrollSettled: @escaping () -> Void
        ) {
            self.isGenerating = isGenerating
            self.autoFollowOutput = autoFollowOutput
            self.isViewActive = isViewActive
            self.manualScrollTrigger = manualScrollTrigger
            self.onUserTouchBegan = onUserTouchBegan
            self.onUserDragUp = onUserDragUp
            self.onReachBottom = onReachBottom
            self.onScrollSettled = onScrollSettled
        }

        func attachIfNeeded(from view: UIView) {
            var current: UIView? = view.superview
            while let candidate = current {
                if let sv = candidate as? UIScrollView {
                    if attachedScrollView !== sv {
                        attachedScrollView = sv
                        sv.delaysContentTouches = true
                        sv.canCancelContentTouches = true
                        sv.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
                        observeContentSize(of: sv)
                    }
                    break
                }
                current = candidate.superview
            }
        }

        func cancelActiveAnimation() {
            followAnimator?.stopAnimation(true)
            followAnimator = nil
        }

        func scrollToBottom(force: Bool = false, animated: Bool = true) {
            guard isViewActive, let sv = attachedScrollView else { return }
            guard force || (autoFollowOutput && !userScrollActive && !sv.isTracking && !sv.isDragging && !sv.isDecelerating) else { return }

            let targetY = bottomOffset(for: sv)
            if force {
                userScrollActive = false
                cancelActiveAnimation()
                animatedTargetY = targetY
                if abs(sv.contentOffset.y - targetY) > 1.0 {
                    sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: targetY), animated: false)
                }
                return
            }

            let delta = targetY - sv.contentOffset.y
            guard delta > 1.5 else { return }

            if !animated {
                cancelActiveAnimation()
                animatedTargetY = targetY
                sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: targetY), animated: false)
                return
            }

            if followAnimator?.isRunning == true && abs(targetY - animatedTargetY) < 4.0 {
                return
            }

            animatedTargetY = targetY
            cancelActiveAnimation()

            let duration = min(0.24, max(0.14, Double(delta) / 900.0))
            let animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut) { [weak sv] in
                guard let sv = sv else { return }
                sv.contentOffset = CGPoint(x: sv.contentOffset.x, y: targetY)
            }
            animator.addCompletion { [weak self] _ in
                self?.followAnimator = nil
            }
            followAnimator = animator
            animator.startAnimation()
        }

        private func bottomOffset(for scrollView: UIScrollView) -> CGFloat {
            let scale = UIScreen.main.scale
            let minOffset = -scrollView.adjustedContentInset.top
            let maxOffset = max(
                minOffset,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            return round(maxOffset * scale) / scale
        }

        private func observeContentSize(of scrollView: UIScrollView) {
            contentSizeObservation?.invalidate()
            lastObservedHeight = scrollView.contentSize.height
            contentSizeObservation = scrollView.observe(\.contentSize, options: [.new]) { [weak self] sv, _ in
                guard let self = self else { return }
                let newHeight = sv.contentSize.height
                let heightDelta = newHeight - self.lastObservedHeight

                if self.userScrollActive || sv.isTracking || sv.isDragging || sv.isDecelerating {
                    self.lastObservedHeight = newHeight
                    return
                }

                guard self.isViewActive, self.autoFollowOutput else {
                    self.lastObservedHeight = newHeight
                    return
                }

                let distanceToTarget = self.bottomOffset(for: sv) - sv.contentOffset.y
                guard heightDelta >= 1.5 || (self.isGenerating && distanceToTarget > 6.0) else { return }
                self.lastObservedHeight = newHeight
                self.scrollToBottom(force: false, animated: true)
            }
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let sv = attachedScrollView else { return }

            switch recognizer.state {
            case .began:
                scrollSettleWorkItem?.cancel()
                userScrollActive = true
                panInitialOffsetY = sv.contentOffset.y
                cancelActiveAnimation()
                onUserTouchBegan()
            case .changed:
                let translationY = recognizer.translation(in: sv).y
                let distanceFromBottom = bottomOffset(for: sv) - sv.contentOffset.y
                if (translationY > 18 || sv.contentOffset.y < panInitialOffsetY - 16) && distanceFromBottom > 68 {
                    onUserDragUp()
                }
            case .ended, .cancelled, .failed:
                scheduleScrollSettleCheck()
            default:
                break
            }
        }

        private func scheduleScrollSettleCheck() {
            scrollSettleWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self = self, let sv = self.attachedScrollView else { return }
                guard !sv.isTracking && !sv.isDragging && !sv.isDecelerating else {
                    self.scheduleScrollSettleCheck()
                    return
                }

                self.userScrollActive = false
                self.onScrollSettled()
                let distanceFromBottom = self.bottomOffset(for: sv) - sv.contentOffset.y
                if distanceFromBottom < 72 {
                    self.onReachBottom()
                }
            }
            scrollSettleWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: item)
        }
    }
}
