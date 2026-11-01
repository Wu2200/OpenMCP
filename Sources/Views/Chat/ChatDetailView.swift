import Combine
import SwiftUI
import UIKit

struct ChatLayoutProbe: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        content
    }
}

struct ChatLayoutInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: String
    let theme: AppThemePalette
    @State private var isCopied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("报告包含当前可见消息行的真实位置与尺寸，不包含消息正文、工具参数、工具结果或密钥。")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    Text(report)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.border, lineWidth: 1))

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = report
                        isCopied = true
                    } label: {
                        Label(isCopied ? "已复制" : "复制报告", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)

                    ShareLink(item: report) {
                        Label("分享报告", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.accent)
                }
            }
            .padding(16)
            .background(theme.background)
            .navigationTitle("对话布局检查器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

@MainActor
private final class ChatWorkspaceObserver: ObservableObject {
    @Published private(set) var settings: OpenAISettings
    @Published private(set) var servers: [MCPServer]

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let store = DataStorage.shared
        self.settings = store.settings
        self.servers = store.servers

        store.$settings
            .dropFirst()
            .sink { [weak self] newSettings in
                guard let self, self.settings != newSettings else { return }
                self.settings = newSettings
            }
            .store(in: &cancellables)

        store.$servers
            .dropFirst()
            .sink { [weak self] newServers in
                guard let self, self.servers != newServers else { return }
                self.servers = newServers
            }
            .store(in: &cancellables)
    }
}

struct ChatDetailView: View {
    let conversationId: String
    @ObservedObject private var coordinator: AgentCoordinator
    @StateObject private var turnProjection: ChatTurnProjectionStore
    @StateObject private var workspace = ChatWorkspaceObserver()

    @State private var inputText: String = ""
    @State private var pendingAttachments: [ChatAttachment] = []
    @State private var showingToolsSheet: Bool = false
    @State private var showingLogViewerSheet: Bool = false
    @State private var showingPhotoPicker: Bool = false
    @State private var showingCameraPicker: Bool = false
    @State private var showingDocumentPicker: Bool = false
    @State private var previewingStagedAttachment: ChatAttachment? = nil
    @State private var selectedTurnId: String? = nil
    @State private var editingTurnId: String? = nil
    @State private var pendingDeleteTurn: MessageDisplayTurn? = nil
    @State private var showingClearConversationAlert: Bool = false
    @State private var showingLayoutInspector: Bool = false
    @State private var layoutInspectorReport: String = ""
    @State private var autoFollowOutput: Bool = true
    @State private var scrollToBottomTrigger: Int = 0
    @State private var inspectorBridge = ChatTableInspectorBridge()
    @FocusState private var isInputFocused: Bool

    init(conversationId: String) {
        self.conversationId = conversationId
        self._coordinator = ObservedObject(wrappedValue: AgentCoordinator.coordinator(for: conversationId))
        self._turnProjection = StateObject(wrappedValue: ChatTurnProjectionStore(conversationId: conversationId))
        UserDefaults.standard.removeObject(forKey: "chatLayoutDiagnosticsEnabled")
    }

    private var storage: DataStorage {
        DataStorage.shared
    }

    private var theme: AppThemePalette {
        workspace.settings.currentTheme
    }

    private var conversationSnapshot: Conversation {
        Conversation(
            id: conversationId,
            title: turnProjection.conversationTitle,
            messages: [],
            selectedProfileId: turnProjection.selectedProfileId,
            selectedModelName: turnProjection.selectedModelName
        )
    }

    private var effectiveSettings: OpenAISettings {
        workspace.settings.resolvedSettings(for: conversationSnapshot)
    }

    private var displayTurns: [MessageDisplayTurn] {
        let rawTurns = turnProjection.turns
        // 非生成状态下若最后一条也是残留的空占位，过滤掉避免空卡片
        if !coordinator.isGenerating, let last = rawTurns.last, last.isCompletelyEmptyAssistantTurn {
            return Array(rawTurns.dropLast())
        }
        return rawTurns
    }

    private var tableRowItems: [ChatListRowItem] {
        let turns = displayTurns
        var items: [ChatListRowItem] = []
        items.reserveCapacity(turns.count + 2)

        let modelName = effectiveSettings.modelName
        let globalGenerating = coordinator.isGenerating

        for (index, turn) in turns.enumerated() {
            let isLastAssistant = (index == turns.count - 1 && turn.role == .assistant)
            let activeGenerating = globalGenerating && isLastAssistant

            items.append(
                .turn(
                    turn: turn,
                    isActiveGenerating: activeGenerating,
                    isSelected: selectedTurnId == turn.id,
                    isGeneratingGlobal: globalGenerating,
                    statusText: activeGenerating ? coordinator.statusText : "",
                    thinkingStartTime: activeGenerating ? coordinator.thinkingStartTime : nil,
                    modelName: modelName
                )
            )
        }

        if globalGenerating && turns.last?.role != .assistant {
            items.append(
                .generatingStatus(
                    statusText: coordinator.statusText,
                    startDate: coordinator.thinkingStartTime ?? Date()
                )
            )
        }

        if let err = coordinator.errorMessage {
            items.append(
                .errorBanner(
                    message: err,
                    canRetry: !turns.isEmpty
                )
            )
        }

        return items
    }

    private var activeToolCount: Int {
        workspace.servers.filter { $0.isEnabled }.reduce(0) { $0 + $1.tools.filter { $0.isEnabled }.count }
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
            let turns = displayTurns

            ZStack {
                theme.background
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleBackgroundTap()
                    }

                VStack(spacing: 0) {
                    ZStack(alignment: .bottomTrailing) {
                        if turns.isEmpty && !coordinator.isGenerating && coordinator.errorMessage == nil {
                            ScrollView(.vertical, showsIndicators: true) {
                                emptyConversationHero
                                    .padding(.horizontal, 14)
                                    .padding(.top, 24)
                                    .frame(width: viewportWidth)
                                    .frame(minHeight: max(300, geo.size.height - 130), alignment: .top)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        handleBackgroundTap()
                                    }
                            }
                            .frame(width: viewportWidth)
                            .scrollDismissesKeyboard(.interactively)
                        } else {
                            ChatMessagesTableView(
                                conversationId: conversationId,
                                rows: tableRowItems,
                                theme: theme,
                                isGenerating: coordinator.isGenerating,
                                autoFollowOutput: autoFollowOutput,
                                editingTurnId: editingTurnId,
                                selectedTurnId: selectedTurnId,
                                scrollToBottomTrigger: scrollToBottomTrigger,
                                streamingState: coordinator.streamingState,
                                inspectorBridge: inspectorBridge,
                                onAutoFollowChanged: { newFollow in
                                    if autoFollowOutput != newFollow {
                                        autoFollowOutput = newFollow
                                    }
                                },
                                onUserScrollingChanged: { scrolling in
                                    coordinator.streamingState.setUserScrolling(scrolling)
                                },
                                onSelectToggle: { turn in
                                    if isInputFocused {
                                        dismissKeyboard()
                                    }
                                    selectedTurnId = (selectedTurnId == turn.id) ? nil : turn.id
                                },
                                onEditBegin: { turn in
                                    editingTurnId = turn.id
                                },
                                onEditEnd: { _ in
                                    editingTurnId = nil
                                },
                                onDismissSelection: {
                                    handleBackgroundTap()
                                },
                                onEditSave: { turn, newContent in
                                    dismissKeyboard()
                                    selectedTurnId = nil
                                    editingTurnId = nil
                                    storage.updateMessageContent(
                                        conversationId: conversationId,
                                        messageId: turn.primaryMessageId,
                                        newContent: newContent
                                    )
                                },
                                onEditAndResend: { turn, newContent in
                                    dismissKeyboard()
                                    selectedTurnId = nil
                                    editingTurnId = nil
                                    requestScrollToBottom()
                                    coordinator.startRetryFromMessage(
                                        conversationId: conversationId,
                                        messageId: turn.primaryMessageId,
                                        newPrompt: newContent,
                                        settings: workspace.settings,
                                        servers: workspace.servers
                                    )
                                },
                                onRetryTurn: { turn in
                                    dismissKeyboard()
                                    selectedTurnId = nil
                                    requestScrollToBottom()
                                    coordinator.startRetryFromMessage(
                                        conversationId: conversationId,
                                        messageId: turn.primaryMessageId,
                                        settings: workspace.settings,
                                        servers: workspace.servers
                                    )
                                },
                                onDeleteTurn: { turn in
                                    dismissKeyboard()
                                    pendingDeleteTurn = turn
                                },
                                onRetryLastFromError: {
                                    guard let lastTurn = turns.last else { return }
                                    dismissKeyboard()
                                    requestScrollToBottom()
                                    coordinator.startRetryFromMessage(
                                        conversationId: conversationId,
                                        messageId: lastTurn.primaryMessageId,
                                        settings: workspace.settings,
                                        servers: workspace.servers
                                    )
                                }
                            )
                            .frame(width: viewportWidth)
                        }

                        LinearGradient(
                            stops: [
                                .init(color: theme.background.opacity(0), location: 0),
                                .init(color: theme.background.opacity(0.85), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: viewportWidth, height: 12)
                        .allowsHitTesting(false)

                        if !turns.isEmpty {
                            Button {
                                requestScrollToBottom()
                            } label: {
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
            autoFollowOutput = true
            coordinator.streamingState.setUserScrolling(false)
        }
        .onDisappear {
            coordinator.streamingState.setUserScrolling(false)
        }
        .navigationTitle(turnProjection.conversationTitle)
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
                        Button {
                            layoutInspectorReport = inspectorBridge.makeReport(
                                conversationTitle: turnProjection.conversationTitle,
                                selectedTurnId: selectedTurnId
                            )
                            showingLayoutInspector = true
                        } label: {
                            Label("对话布局检查器", systemImage: "rectangle.dashed")
                        }

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
        .sheet(isPresented: $showingLayoutInspector) {
            ChatLayoutInspectorSheet(
                report: layoutInspectorReport,
                theme: theme
            )
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

    private func requestScrollToBottom() {
        autoFollowOutput = true
        coordinator.streamingState.setUserScrolling(false)
        scrollToBottomTrigger &+= 1
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
                            selectedTurnId = nil
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
                        showingDocumentPicker = true
                    }) {
                        Label("文件上传", systemImage: "doc.badge.plus")
                    }

                    Button(action: {
                        dismissKeyboard()
                        showingCameraPicker = true
                    }) {
                        Label("拍照上传", systemImage: "camera")
                    }

                    Button(action: {
                        dismissKeyboard()
                        showingPhotoPicker = true
                    }) {
                        Label("图片上传", systemImage: "photo.on.rectangle.angled")
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

                if turnProjection.rawMessageCount > 0 {
                    ContextTokenBadge(
                        conversationId: conversationId,
                        theme: theme
                    )
                }

                Spacer(minLength: 6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleBackgroundTap()
                    }

                Menu {
                    let profilesWithModels = workspace.settings.providerProfiles.filter { !$0.enabledModels.isEmpty }
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
                            ForEach(workspace.settings.chatSelectableModelEntries, id: \.id) { entry in
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

            Button {
                pendingAttachments.removeAll { $0.id == att.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(theme.mutedText)
                    .padding(2)
            }
            .buttonStyle(.plain)
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

                if workspace.servers.isEmpty {
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
                            Text("已启用的工具会按问题按需搜索；每次只把相关工具定义发送给 AI。")
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 2)

                            ForEach(workspace.servers) { server in
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
        if selectedTurnId != nil && editingTurnId == nil {
            selectedTurnId = nil
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
        requestScrollToBottom()
        dismissKeyboard()
        coordinator.startSendMessage(
            conversationId: conversationId,
            userPrompt: prompt,
            attachments: attachmentsToSend,
            settings: workspace.settings,
            servers: workspace.servers
        )
    }

    private func sendSpecificPrompt(_ prompt: String) {
        selectedTurnId = nil
        requestScrollToBottom()
        dismissKeyboard()
        coordinator.startSendMessage(
            conversationId: conversationId,
            userPrompt: prompt,
            settings: workspace.settings,
            servers: workspace.servers
        )
    }
}

private struct ContextTokenBadge: View {
    @ObservedObject var store = ContextTokenStore.shared
    let conversationId: String
    let theme: AppThemePalette

    private func compactText(_ value: Int) -> String {
        if value < 1_000 {
            return "\(value)"
        }
        if value < 100_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        if value < 1_000_000 {
            return String(format: "%.0fK", Double(value) / 1_000)
        }
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }

    var body: some View {
        if let entry = store.entries[conversationId] {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(compactText(entry.count))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.elevatedBackground.opacity(0.65))
            .clipShape(Capsule())
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("当前上下文 \(entry.count.formatted()) 个 Token")
        }
    }
}
