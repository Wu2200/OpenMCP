import SwiftUI
import UIKit

private struct ChatLayoutDiagnosticsEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chatLayoutDiagnosticsEnabled: Bool {
        get { self[ChatLayoutDiagnosticsEnabledKey.self] }
        set { self[ChatLayoutDiagnosticsEnabledKey.self] = newValue }
    }
}

struct ChatLayoutCoordinateSpace {
    static let name = "OpenMCP.ChatLayout"
}

struct ChatLayoutFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct ChatLayoutProbe: ViewModifier {
    let identifier: String?
    @Environment(\.chatLayoutDiagnosticsEnabled) private var diagnosticsEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if diagnosticsEnabled, let identifier = identifier {
            content.background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ChatLayoutFramesPreferenceKey.self,
                        value: [identifier: geometry.frame(in: .named(ChatLayoutCoordinateSpace.name))]
                    )
                }
            }
        } else {
            content
        }
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
                Text("报告包含消息区域的位置、尺寸和间距，不包含消息正文、工具参数、工具结果或密钥。请复制后粘贴给我。")
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

struct ChatDetailView: View {
    @EnvironmentObject var storage: DataStorage
    let conversationId: String
    @ObservedObject private var coordinator: AgentCoordinator
    @StateObject private var turnProjection: ChatTurnProjectionStore
    @State private var inputText: String = ""
    @State private var pendingAttachments: [ChatAttachment] = []
    @State private var showingToolsSheet: Bool = false
    @State private var showingLogViewerSheet: Bool = false
    @State private var showingPhotoPicker: Bool = false
    @State private var showingCameraPicker: Bool = false
    @State private var showingDocumentPicker: Bool = false
    @State private var previewingStagedAttachment: ChatAttachment? = nil
    @State private var selectedTurnId: String? = nil
    @State private var pendingEditScrollTurnId: String? = nil
    @State private var isKeyboardVisible: Bool = false
    @State private var pendingDeleteTurn: MessageDisplayTurn? = nil
    @State private var showingClearConversationAlert: Bool = false
    @State private var showingLayoutInspector: Bool = false
    @State private var isLayoutDiagnosticsEnabled: Bool = false
    @State private var layoutInspectorReport: String = ""
    @State private var layoutFrames: [String: CGRect] = [:]
    @State private var visibleHistoryLimit: Int = 40
    @State private var autoFollowOutput: Bool = true
    @State private var manualScrollTrigger: Int = 0
    @State private var isChatVisible: Bool = true
    @FocusState private var isInputFocused: Bool

    init(conversationId: String) {
        self.conversationId = conversationId
        self._coordinator = ObservedObject(wrappedValue: AgentCoordinator.coordinator(for: conversationId))
        self._turnProjection = StateObject(wrappedValue: ChatTurnProjectionStore(conversationId: conversationId))
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
        turnProjection.turns
    }

    private var projectedTurnsPlaceholder: [MessageDisplayTurn] {
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

    private var visibleTurns: [MessageDisplayTurn] {
        Array(displayTurns.suffix(visibleHistoryLimit))
    }

    private var hiddenTurnCount: Int {
        max(0, displayTurns.count - visibleHistoryLimit)
    }

    private var isShowingEntireHistory: Bool {
        visibleHistoryLimit >= displayTurns.count
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

            ScrollViewReader { scrollProxy in
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
                                LazyVStack(spacing: 12) {
                                    if hiddenTurnCount > 0 {
                                        Button {
                                            visibleHistoryLimit = min(displayTurns.count, visibleHistoryLimit + 40)
                                        } label: {
                                            Label("加载更早的 \(hiddenTurnCount) 条消息", systemImage: "arrow.up")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(theme.accent)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .frame(maxWidth: .infinity)
                                                .background(theme.cardBackground)
                                                .clipShape(Capsule())
                                                .overlay(Capsule().stroke(theme.border, lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.bottom, 2)
                                    }

                                    let turns = visibleTurns
                                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                                        let isLastAssistant = isShowingEntireHistory && index == turns.count - 1 && turn.role == .assistant
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
                                                let isSelecting = selectedTurnId != turn.id
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    selectedTurnId = isSelecting ? turn.id : nil
                                                }
                                            },
                                            onEditBegin: {
                                                centerTurnForEditing(turn.id, using: scrollProxy)
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

                                    if coordinator.isGenerating && (!isShowingEntireHistory || visibleTurns.last?.role != .assistant) {
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
                                .padding(.bottom, 56)
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
                                        onUserInteraction: {
                                            if autoFollowOutput {
                                                autoFollowOutput = false
                                            }
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
                        .environment(\.chatLayoutDiagnosticsEnabled, isLayoutDiagnosticsEnabled)
                        .coordinateSpace(name: ChatLayoutCoordinateSpace.name)
                        .onPreferenceChange(ChatLayoutFramesPreferenceKey.self) { samples in
                            layoutFrames = samples
                        }
                        .scrollDismissesKeyboard(.interactively)
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

                        LinearGradient(
                            stops: [
                                .init(color: theme.background.opacity(0), location: 0),
                                .init(color: theme.background.opacity(0.68), location: 0.55),
                                .init(color: theme.background, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: viewportWidth, height: 40)
                        .allowsHitTesting(false)

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
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    isKeyboardVisible = true
                    guard let turnId = pendingEditScrollTurnId else { return }
                    scrollEditorToCenter(turnId, using: scrollProxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                    isKeyboardVisible = false
                }
                }
            }
        }
        .onAppear {
            isChatVisible = true
            visibleHistoryLimit = 40
            coordinator.streamingState.setDisplayPaused(false)
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
                        Button {
                            layoutFrames.removeAll()
                            isLayoutDiagnosticsEnabled = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                layoutInspectorReport = makeLayoutInspectorReport()
                                showingLayoutInspector = true
                            }
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
        .sheet(isPresented: $showingLayoutInspector, onDismiss: {
            isLayoutDiagnosticsEnabled = false
            layoutFrames.removeAll()
        }) {
            ChatLayoutInspectorSheet(report: layoutInspectorReport, theme: theme)
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

    private func makeLayoutInspectorReport() -> String {
        let turns = Array(visibleTurns.suffix(8))
        var lines = [
            "OpenMCP 对话布局诊断报告",
            "采集时间：\(ISO8601DateFormatter().string(from: Date()))",
            "坐标单位：pt；坐标系：聊天滚动区域。滚动时 y 值可能为负。",
            "隐私：不包含对话正文、工具参数、工具结果或密钥。",
            "",
            "最近 \(turns.count) 条消息布局"
        ]

        var previousRow: (id: String, frame: CGRect)?

        for (index, turn) in turns.enumerated() {
            let shortID = String(turn.id.prefix(8))
            let row = layoutFrames["row|\(turn.role.rawValue)|\(turn.id)"]
            lines.append("")
            lines.append("[\(index + 1)] \(turn.role.rawValue) \(shortID)")
            lines.append("消息行：\(layoutFrameDescription(row))")

            if let row = row, let previous = previousRow {
                let gap = row.minY - previous.frame.maxY
                lines.append("与上一消息行间距：\(String(format: "%.1f", gap)) pt\(gap > 24 ? " [偏大]" : "")")
            }
            if let row = row {
                previousRow = (turn.id, row)
            }

            guard turn.role == .assistant else { continue }

            let card = layoutFrames["assistantCard|\(turn.id)"]
            let column = layoutFrames["assistantColumn|\(turn.id)"]
            let hStackContent = layoutFrames["assistantHStackContent|\(turn.id)"]
            let hStack = layoutFrames["assistantHStack|\(turn.id)"]
            let avatar = layoutFrames["avatar|assistant|\(turn.id)"]
            let actionBar = layoutFrames["actionBar|\(turn.id)"]
            let editor = layoutFrames["editor|\(turn.id)"]
            lines.append("当前选中状态：\(selectedTurnId == turn.id ? "是" : "否")")
            lines.append("助手 HStack 内容：\(layoutFrameDescription(hStackContent))")
            lines.append("助手 HStack 外框：\(layoutFrameDescription(hStack))")
            lines.append("助手头像：\(layoutFrameDescription(avatar))")
            if let row = row, let hStack = hStack {
                lines.append("消息行高度 - 助手 HStack 高度：\(String(format: "%.1f", row.height - hStack.height)) pt")
            }
            if let hStack = hStack, let hStackContent = hStackContent {
                lines.append("HStack 外框高度 - 内容高度：\(String(format: "%.1f", hStack.height - hStackContent.height)) pt")
            }
            lines.append("助手列：\(layoutFrameDescription(column))")
            if let column = column, let card = card {
                lines.append("卡片底部 → 助手列底部：\(String(format: "%.1f", column.maxY - card.maxY)) pt")
            }
            if let editor = editor {
                lines.append("编辑器：\(layoutFrameDescription(editor))")
            }
            lines.append("助手卡片：\(layoutFrameDescription(card))")
            if let row = row, let card = card {
                let topGap = card.minY - row.minY
                let bottomGap = row.maxY - card.maxY
                lines.append("卡片相对消息行：顶部 \(String(format: "%.1f", topGap)) pt，底部 \(String(format: "%.1f", bottomGap)) pt")
            }
            if let card = card, let actionBar = actionBar {
                let cardToActions = actionBar.minY - card.maxY
                lines.append("操作栏：\(layoutFrameDescription(actionBar))")
                lines.append("卡片底部 → 操作栏顶部：\(String(format: "%.1f", cardToActions)) pt")
                if let row = row {
                    let actionsToRowBottom = row.maxY - actionBar.maxY
                    lines.append("操作栏底部 → 消息行底部：\(String(format: "%.1f", actionsToRowBottom)) pt")
                    lines.append("操作栏高度占消息行额外高度：\(String(format: "%.1f", actionBar.height)) / \(String(format: "%.1f", max(0, row.height - card.height))) pt")
                }
            } else if let row = row, let card = card {
                lines.append("操作栏：未测得（该消息可能未选中）")
                lines.append("卡片下方总余量：\(String(format: "%.1f", row.maxY - card.maxY)) pt")
            }

            var sections: [(String, CGRect)] = []
            if let frame = layoutFrames["toolSummary|\(turn.id)"] {
                sections.append(("工具摘要", frame))
                lines.append("工具摘要：\(layoutFrameDescription(frame))")
            }
            if let frame = layoutFrames["reasoning|\(turn.id)"] {
                sections.append(("思考摘要", frame))
                lines.append("思考摘要：\(layoutFrameDescription(frame))")
            }
            if let frame = layoutFrames["markdown|\(turn.id)"] {
                sections.append(("Markdown 正文", frame))
                lines.append("Markdown 正文外框：\(layoutFrameDescription(frame))")
            }
            let markdownStack = layoutFrames["markdownStack|\(turn.id)"]
            let markdownBlocksGroup = layoutFrames["markdownBlocksGroup|\(turn.id)"]
            lines.append("Markdown VStack：\(layoutFrameDescription(markdownStack))")
            lines.append("Markdown 块组：\(layoutFrameDescription(markdownBlocksGroup))")
            if let markdownStack = markdownStack, let markdownBlocksGroup = markdownBlocksGroup {
                lines.append("Markdown VStack 高度 - 块组高度：\(String(format: "%.1f", markdownStack.height - markdownBlocksGroup.height)) pt")
            }

            if sections.count > 1 {
                for sectionIndex in 1..<sections.count {
                    let gap = sections[sectionIndex].1.minY - sections[sectionIndex - 1].1.maxY
                    lines.append("\(sections[sectionIndex - 1].0) → \(sections[sectionIndex].0) 间距：\(String(format: "%.1f", gap)) pt\(gap > 24 ? " [偏大]" : "")")
                }
            }

            let blockPrefix = "markdownBlock|\(turn.id)|"
            let blocks = layoutFrames
                .filter { $0.key.hasPrefix(blockPrefix) }
                .sorted { $0.value.minY < $1.value.minY }
            if !blocks.isEmpty {
                lines.append("Markdown 块（按屏幕顺序）：")
                for blockIndex in blocks.indices {
                    let block = blocks[blockIndex]
                    let suffix = String(block.key.dropFirst(blockPrefix.count))
                    let parts = suffix.split(separator: "|", maxSplits: 1).map(String.init)
                    let blockID = parts.first ?? suffix
                    let blockType = parts.count > 1 ? parts[1] : "未知类型"
                    lines.append("  块 \(blockID) [\(blockType)]：\(layoutFrameDescription(block.value))")
                    if blockIndex > 0 {
                        let previous = blocks[blockIndex - 1].value
                        let gap = block.value.minY - previous.maxY
                        lines.append("  块间距：\(String(format: "%.1f", gap)) pt\(gap > 24 ? " [偏大]" : "")")
                    }
                }
            }
        }

        if layoutFrames.isEmpty {
            lines.append("\n尚未收到布局测量数据；请关闭检查器，等待聊天内容显示后重新打开。")
        }

        return lines.joined(separator: "\n")
    }

    private func layoutFrameDescription(_ frame: CGRect?) -> String {
        guard let frame = frame else { return "未测得" }
        return String(format: "x=%.1f y=%.1f w=%.1f h=%.1f", frame.minX, frame.minY, frame.width, frame.height)
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

                if !currentConversation.messages.isEmpty {
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

    private func centerTurnForEditing(_ turnId: String, using proxy: ScrollViewProxy) {
        pendingEditScrollTurnId = turnId
        if isKeyboardVisible {
            scrollEditorToCenter(turnId, using: proxy)
        }
    }

    private func scrollEditorToCenter(_ turnId: String, using proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard pendingEditScrollTurnId == turnId else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("message-editor-\(turnId)", anchor: .center)
            }
            pendingEditScrollTurnId = nil
        }
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

private struct ChatScrollViewIntrospector: UIViewRepresentable {
    var isGenerating: Bool
    var autoFollowOutput: Bool
    var isViewActive: Bool
    var manualScrollTrigger: Int
    var onUserTouchBegan: () -> Void
    var onUserInteraction: () -> Void
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
            onUserInteraction: onUserInteraction,
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
        coord.onUserInteraction = onUserInteraction
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
            } else if !wasViewActive && isViewActive && isGenerating && autoFollowOutput && coord.isNearBottom() {
                coord.scheduleBottomFollow()
            } else if !wasGenerating && isGenerating && autoFollowOutput && coord.isNearBottom() {
                coord.scheduleBottomFollow()
            }
            if isViewActive {
                coord.positionAtBottomInitiallyIfNeeded()
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isGenerating: Bool
        var autoFollowOutput: Bool
        var isViewActive: Bool
        var manualScrollTrigger: Int
        var onUserTouchBegan: () -> Void
        var onUserInteraction: () -> Void
        var onUserDragUp: () -> Void
        var onReachBottom: () -> Void
        var onScrollSettled: () -> Void
        private weak var attachedScrollView: UIScrollView?
        private var contentSizeObservation: NSKeyValueObservation?
        private var lastObservedHeight: CGFloat = 0
        private var scrollSettleWorkItem: DispatchWorkItem?
        private var bottomFollowWorkItem: DispatchWorkItem?
        private var followAnimator: UIViewPropertyAnimator?
        private var animatedTargetY: CGFloat = 0
        private var userScrollActive = false
        private var panInitialOffsetY: CGFloat = 0
        private var contentTapRecognizer: UITapGestureRecognizer?
        private var hasPerformedInitialPositioning = false

        init(
            isGenerating: Bool,
            autoFollowOutput: Bool,
            isViewActive: Bool,
            manualScrollTrigger: Int,
            onUserTouchBegan: @escaping () -> Void,
            onUserInteraction: @escaping () -> Void,
            onUserDragUp: @escaping () -> Void,
            onReachBottom: @escaping () -> Void,
            onScrollSettled: @escaping () -> Void
        ) {
            self.isGenerating = isGenerating
            self.autoFollowOutput = autoFollowOutput
            self.isViewActive = isViewActive
            self.manualScrollTrigger = manualScrollTrigger
            self.onUserTouchBegan = onUserTouchBegan
            self.onUserInteraction = onUserInteraction
            self.onUserDragUp = onUserDragUp
            self.onReachBottom = onReachBottom
            self.onScrollSettled = onScrollSettled
        }

        func attachIfNeeded(from view: UIView) {
            var current: UIView? = view.superview
            while let candidate = current {
                if let sv = candidate as? UIScrollView {
                    if attachedScrollView !== sv {
                        if let previousScrollView = attachedScrollView {
                            previousScrollView.panGestureRecognizer.removeTarget(self, action: #selector(handlePan(_:)))
                            if let tapRecognizer = contentTapRecognizer {
                                previousScrollView.removeGestureRecognizer(tapRecognizer)
                            }
                        }
                        attachedScrollView = sv
                        sv.delaysContentTouches = true
                        sv.canCancelContentTouches = true
                        sv.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
                        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleContentTap(_:)))
                        tapRecognizer.cancelsTouchesInView = false
                        tapRecognizer.delaysTouchesBegan = false
                        tapRecognizer.delaysTouchesEnded = false
                        tapRecognizer.delegate = self
                        sv.addGestureRecognizer(tapRecognizer)
                        contentTapRecognizer = tapRecognizer
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

        func isNearBottom(tolerance: CGFloat = 72) -> Bool {
            guard let scrollView = attachedScrollView else { return false }
            return bottomOffset(for: scrollView) - scrollView.contentOffset.y <= tolerance
        }

        func positionAtBottomInitiallyIfNeeded() {
            guard !hasPerformedInitialPositioning else { return }
            hasPerformedInitialPositioning = true
            scheduleBottomFollow()
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
            guard abs(delta) > 1.5 else { return }

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

            let duration = min(0.24, max(0.14, Double(abs(delta)) / 900.0))
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

        func scheduleBottomFollow() {
            bottomFollowWorkItem?.cancel()
            scheduleBottomFollowAttempt(after: 0.04, remainingRetries: 3)
        }

        private func scheduleBottomFollowAttempt(after delay: TimeInterval, remainingRetries: Int) {
            let item = DispatchWorkItem { [weak self] in
                guard let self = self, self.isViewActive, self.autoFollowOutput,
                      let scrollView = self.attachedScrollView else { return }
                scrollView.layoutIfNeeded()
                self.scrollToBottom(animated: false)
                guard remainingRetries > 0 else { return }
                self.scheduleBottomFollowAttempt(after: 0.12, remainingRetries: remainingRetries - 1)
            }
            bottomFollowWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
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
                let previousHeight = self.lastObservedHeight
                let heightDelta = newHeight - previousHeight
                self.lastObservedHeight = newHeight

                guard abs(heightDelta) > 0.5 else { return }
                guard self.isViewActive, self.isGenerating, self.autoFollowOutput else { return }
                guard !self.userScrollActive, !sv.isTracking, !sv.isDragging, !sv.isDecelerating else { return }

                let previousBottomOffset = max(
                    -sv.adjustedContentInset.top,
                    previousHeight - sv.bounds.height + sv.adjustedContentInset.bottom
                )
                guard previousBottomOffset - sv.contentOffset.y <= 72 else { return }
                self.scheduleBottomFollow()
            }
        }

        @objc private func handleContentTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onUserInteraction()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
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
