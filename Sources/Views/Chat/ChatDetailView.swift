import SwiftUI
import UIKit

struct ChatDetailView: View {
    @EnvironmentObject var storage: DataStorage
    let conversationId: String
    @ObservedObject private var coordinator: AgentCoordinator
    @State private var inputText: String = ""
    @State private var pendingAttachments: [ChatAttachment] = []
    @State private var showingToolsSheet: Bool = false
    @State private var showingPhotoPicker: Bool = false
    @State private var showingCameraPicker: Bool = false
    @State private var showingDocumentPicker: Bool = false
    @State private var previewingStagedAttachment: ChatAttachment? = nil
    @State private var selectedTurnId: String? = nil
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
                                            modelName: storage.settings.modelName,
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
                                                if selectedTurnId == turn.id {
                                                    selectedTurnId = nil
                                                }
                                                storage.deleteMessageTurn(
                                                    conversationId: conversationId,
                                                    messageIds: turn.underlyingMessageIds
                                                )
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
                                .padding(.bottom, 54)
                                .frame(width: viewportWidth)
                                .frame(minHeight: max(260, geo.size.height - 120), alignment: .top)
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
                        Button(role: .destructive, action: {
                            selectedTurnId = nil
                            if coordinator.isGenerating {
                                coordinator.stopGeneration()
                            }
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
struct ChatScrollViewObserver: UIViewRepresentable {
    var autoFollowEnabled: Bool
    var isGenerating: Bool
    var contentDigest: Int
    var manualScrollTrigger: Int
    var onAutoFollowChanged: (Bool) -> Void
    var onUserInteractionChanged: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            autoFollowEnabled: autoFollowEnabled,
            isGenerating: isGenerating,
            onAutoFollowChanged: onAutoFollowChanged,
            onUserInteractionChanged: onUserInteractionChanged
        )
    }

    func makeUIView(context: Context) -> ObserverHostView {
        let view = ObserverHostView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        view.onMoveToWindow = { [weak view, weak coordinator] in
            guard let view = view, let coordinator = coordinator else { return }
            coordinator.attachIfNeeded(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: ObserverHostView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onAutoFollowChanged = onAutoFollowChanged
        coordinator.onUserInteractionChanged = onUserInteractionChanged
        let wasGenerating = coordinator.isGenerating
        coordinator.autoFollowEnabled = autoFollowEnabled
        coordinator.isGenerating = isGenerating
        coordinator.attachIfNeeded(from: uiView)

        if manualScrollTrigger != coordinator.lastManualScrollTrigger {
            coordinator.lastManualScrollTrigger = manualScrollTrigger
            coordinator.forceScrollToBottom(animated: !isGenerating)
            return
        }

        if contentDigest != coordinator.lastContentDigest {
            coordinator.lastContentDigest = contentDigest
            if autoFollowEnabled {
                coordinator.followIfNeeded()
            }
        }

        if wasGenerating && !isGenerating && autoFollowEnabled {
            coordinator.schedulePostGenerationSettleAlignment()
        }
    }

    final class ObserverHostView: UIView {
        var onMoveToWindow: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                onMoveToWindow?()
            }
        }
    }

    final class Coordinator: NSObject {
        var autoFollowEnabled: Bool
        var isGenerating: Bool
        var onAutoFollowChanged: (Bool) -> Void
        var onUserInteractionChanged: ((Bool) -> Void)?
        var lastContentDigest: Int = 0
        var lastManualScrollTrigger: Int = 0

        private weak var observedScrollView: UIScrollView?
        private var contentOffsetObservation: NSKeyValueObservation?
        private var contentSizeObservation: NSKeyValueObservation?
        private var panStateObservation: NSKeyValueObservation?
        private var isPerformingProgrammaticScroll: Bool = false
        private var userDraggedAwayDuringCurrentTouch: Bool = false
        private var isReportingUserInteraction: Bool = false
        private var settleWorkItem: DispatchWorkItem?
        private var postGenerationSettleItems: [DispatchWorkItem] = []

        private let bottomLockThreshold: CGFloat = 14.0
        private let userBreakawayThreshold: CGFloat = 18.0
        private let targetBottomGap: CGFloat = 0.0

        init(
            autoFollowEnabled: Bool,
            isGenerating: Bool,
            onAutoFollowChanged: @escaping (Bool) -> Void,
            onUserInteractionChanged: ((Bool) -> Void)?
        ) {
            self.autoFollowEnabled = autoFollowEnabled
            self.isGenerating = isGenerating
            self.onAutoFollowChanged = onAutoFollowChanged
            self.onUserInteractionChanged = onUserInteractionChanged
            super.init()
        }

        deinit {
            settleWorkItem?.cancel()
            postGenerationSettleItems.forEach { $0.cancel() }
            contentOffsetObservation?.invalidate()
            contentSizeObservation?.invalidate()
            panStateObservation?.invalidate()
        }

        private func setUserInteraction(_ interacting: Bool) {
            settleWorkItem?.cancel()
            settleWorkItem = nil
            guard isReportingUserInteraction != interacting else { return }
            isReportingUserInteraction = interacting
            DispatchQueue.main.async { [weak self] in
                self?.onUserInteractionChanged?(interacting)
            }
        }

        private func scheduleInteractionEndAfterSettle(for scrollView: UIScrollView) {
            settleWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self, weak scrollView] in
                guard let self = self else { return }
                if let sv = scrollView {
                    let gestureState = sv.panGestureRecognizer.state
                    let gestureActive = gestureState == .began || gestureState == .changed
                    if sv.isTracking || sv.isDragging || gestureActive {
                        self.scheduleInteractionEndAfterSettle(for: sv)
                        return
                    }
                    let dist = self.distanceFromBottom(in: sv)
                    if dist <= self.bottomLockThreshold {
                        self.userDraggedAwayDuringCurrentTouch = false
                        if !self.autoFollowEnabled {
                            self.autoFollowEnabled = true
                            self.onAutoFollowChanged(true)
                        }
                    }
                }
                self.setUserInteraction(false)
            }
            settleWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
        }

        func attachIfNeeded(from view: UIView) {
            if let existing = observedScrollView, existing.window != nil {
                return
            }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self = self, let view = view else { return }
                guard let scrollView = self.findScrollView(from: view) else { return }
                guard self.observedScrollView !== scrollView else { return }
                self.bind(to: scrollView)
            }
        }

        private func findScrollView(from startView: UIView) -> UIScrollView? {
            var current: UIView? = startView
            while let node = current {
                if let sv = node as? UIScrollView {
                    return sv
                }
                current = node.superview
            }
            return nil
        }

        private func bind(to scrollView: UIScrollView) {
            observedScrollView = scrollView
            contentOffsetObservation?.invalidate()
            contentSizeObservation?.invalidate()
            panStateObservation?.invalidate()

            scrollView.keyboardDismissMode = .interactive

            panStateObservation = scrollView.panGestureRecognizer.observe(\.state, options: [.new]) { [weak self, weak scrollView] recognizer, _ in
                guard let self = self, let scrollView = scrollView else { return }
                let state = recognizer.state
                if state == .began || state == .changed {
                    self.setUserInteraction(true)
                    let translation = recognizer.translation(in: scrollView)
                    if translation.y > 4 {
                        self.userDraggedAwayDuringCurrentTouch = true
                        if self.autoFollowEnabled {
                            self.autoFollowEnabled = false
                            DispatchQueue.main.async {
                                self.onAutoFollowChanged(false)
                            }
                        }
                    }
                } else if state == .ended || state == .cancelled || state == .failed {
                    self.scheduleInteractionEndAfterSettle(for: scrollView)
                }
            }

            contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.old, .new]) { [weak self, weak scrollView] _, change in
                guard let self = self, let scrollView = scrollView else { return }
                self.handleOffsetChanged(scrollView, oldOffset: change.oldValue, newOffset: change.newValue)
            }

            contentSizeObservation = scrollView.observe(\.contentSize, options: [.old, .new]) { [weak self, weak scrollView] _, change in
                guard let self = self, let scrollView = scrollView else { return }
                let oldH = change.oldValue?.height ?? 0
                let newH = change.newValue?.height ?? 0
                guard abs(newH - oldH) > 0.5 else { return }
                self.handleContentSizeChanged(scrollView)
            }
        }

        private func maxBottomOffset(for scrollView: UIScrollView) -> CGFloat {
            let inset = scrollView.adjustedContentInset
            let rawMax = scrollView.contentSize.height - scrollView.bounds.height + inset.bottom - targetBottomGap
            return max(-inset.top, rawMax)
        }

        private func distanceFromBottom(in scrollView: UIScrollView) -> CGFloat {
            return maxBottomOffset(for: scrollView) - scrollView.contentOffset.y
        }

        private func isUserActivelyTouching(_ scrollView: UIScrollView) -> Bool {
            let panState = scrollView.panGestureRecognizer.state
            let panActive = panState == .began || panState == .changed
            return scrollView.isTracking || scrollView.isDragging || panActive
        }

        private func handleOffsetChanged(_ scrollView: UIScrollView, oldOffset: CGPoint?, newOffset: CGPoint?) {
            guard !isPerformingProgrammaticScroll else { return }

            let dist = distanceFromBottom(in: scrollView)
            let touching = isUserActivelyTouching(scrollView)

            if touching {
                setUserInteraction(true)

                if let oldY = oldOffset?.y, let newY = newOffset?.y, newY < oldY - 0.5, dist > userBreakawayThreshold {
                    userDraggedAwayDuringCurrentTouch = true
                    if autoFollowEnabled {
                        autoFollowEnabled = false
                        DispatchQueue.main.async { [weak self] in
                            self?.onAutoFollowChanged(false)
                        }
                    }
                    return
                }

                if dist > userBreakawayThreshold && userDraggedAwayDuringCurrentTouch {
                    if autoFollowEnabled {
                        autoFollowEnabled = false
                        DispatchQueue.main.async { [weak self] in
                            self?.onAutoFollowChanged(false)
                        }
                    }
                    return
                }
            }

            if dist <= bottomLockThreshold {
                if !touching {
                    userDraggedAwayDuringCurrentTouch = false
                }
                if !autoFollowEnabled && !userDraggedAwayDuringCurrentTouch {
                    autoFollowEnabled = true
                    DispatchQueue.main.async { [weak self] in
                        self?.onAutoFollowChanged(true)
                    }
                }
            } else if scrollView.isDecelerating && userDraggedAwayDuringCurrentTouch {
                if autoFollowEnabled {
                    autoFollowEnabled = false
                    DispatchQueue.main.async { [weak self] in
                        self?.onAutoFollowChanged(false)
                    }
                }
            }

            if !touching && !scrollView.isDecelerating && isReportingUserInteraction {
                scheduleInteractionEndAfterSettle(for: scrollView)
            }
        }

        private func handleContentSizeChanged(_ scrollView: UIScrollView) {
            guard autoFollowEnabled else { return }
            guard !isUserActivelyTouching(scrollView), !scrollView.isDecelerating else { return }
            alignToBottomImmediately(scrollView)
        }

        func schedulePostGenerationSettleAlignment() {
            postGenerationSettleItems.forEach { $0.cancel() }
            postGenerationSettleItems.removeAll()

            let delays: [TimeInterval] = [0.05, 0.18, 0.35]
            for delay in delays {
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self,
                          self.autoFollowEnabled,
                          let scrollView = self.observedScrollView else { return }
                    guard !self.isUserActivelyTouching(scrollView), !scrollView.isDecelerating else { return }
                    self.alignToBottomImmediately(scrollView)
                }
                postGenerationSettleItems.append(item)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            }
        }

        func followIfNeeded() {
            guard autoFollowEnabled, let scrollView = observedScrollView else { return }
            guard !isUserActivelyTouching(scrollView), !scrollView.isDecelerating else { return }
            alignToBottomImmediately(scrollView)
        }

        func forceScrollToBottom(animated: Bool) {
            userDraggedAwayDuringCurrentTouch = false
            setUserInteraction(false)
            if !autoFollowEnabled {
                autoFollowEnabled = true
                DispatchQueue.main.async { [weak self] in
                    self?.onAutoFollowChanged(true)
                }
            }
            guard let scrollView = observedScrollView else { return }
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self = self, let scrollView = scrollView else { return }
                let targetY = self.maxBottomOffset(for: scrollView)
                guard abs(scrollView.contentOffset.y - targetY) > 0.5 else { return }
                if animated {
                    self.isPerformingProgrammaticScroll = true
                    scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.isPerformingProgrammaticScroll = false
                    }
                } else {
                    self.alignToBottomImmediately(scrollView)
                }
            }
        }

        private func alignToBottomImmediately(_ scrollView: UIScrollView) {
            let targetY = maxBottomOffset(for: scrollView)
            let delta = targetY - scrollView.contentOffset.y
            guard abs(delta) > 0.5 else { return }

            isPerformingProgrammaticScroll = true
            UIView.performWithoutAnimation {
                scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            }
            isPerformingProgrammaticScroll = false
        }
    }
}
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
            } else if !wasViewActive && isGenerating && autoFollowOutput {
                coord.scrollToBottom(animated: false)
            } else if wasGenerating && !isGenerating && autoFollowOutput {
                coord.scrollToBottom(animated: true)
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
            let raw = max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            return round(raw * scale) / scale
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

                guard heightDelta >= 6.0 else { return }
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
                if (translationY > 8 || sv.contentOffset.y < panInitialOffsetY - 6) && distanceFromBottom > 28 {
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
                if distanceFromBottom < 36 {
                    self.onReachBottom()
                }
            }
            scrollSettleWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: item)
        }
    }
}
