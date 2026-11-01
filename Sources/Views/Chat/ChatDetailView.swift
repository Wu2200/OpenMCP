import Combine
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
    @Binding var isDiagnosticsEnabled: Bool
    var onDiagnosticsChanged: (Bool) -> Void
    @State private var isCopied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("报告包含消息区域的位置、尺寸和间距，不包含消息正文、工具参数、工具结果或密钥。请复制后粘贴给我。")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(isOn: $isDiagnosticsEnabled) {
                    Label("启用布局测量", systemImage: "ruler")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                }
                .tint(theme.accent)
                .onChange(of: isDiagnosticsEnabled) { enabled in
                    onDiagnosticsChanged(enabled)
                }

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

/// 仅订阅 settings 与 servers 变更，避免 DataStorage.$conversations 高频更新导致整页二次重绘
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
            .sink { [weak self] newSettings in
                guard let self, self.settings != newSettings else { return }
                self.settings = newSettings
            }
            .store(in: &cancellables)

        store.$servers
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
    @State private var pendingEditScrollTurnId: String? = nil
    @State private var editingTurnId: String? = nil
    @State private var isKeyboardVisible: Bool = false
    @State private var pendingDeleteTurn: MessageDisplayTurn? = nil
    @State private var showingClearConversationAlert: Bool = false
    @State private var showingLayoutInspector: Bool = false
    @AppStorage("chatLayoutDiagnosticsEnabled") private var isLayoutDiagnosticsEnabled = false
    @State private var layoutInspectorReport: String = ""
    @State private var layoutFrames: [String: CGRect] = [:]
    @State private var visibleHistoryLimit: Int = 50
    @State private var autoFollowOutput: Bool = true
    @State private var showJumpToBottomButton: Bool = false
    @State private var forceBottomScrollRevision: Int = 0
    @State private var prependHistoryAnchorRevision: Int = 0
    @State private var isChatVisible: Bool = true
    @FocusState private var isInputFocused: Bool

    init(conversationId: String) {
        self.conversationId = conversationId
        self._coordinator = ObservedObject(wrappedValue: AgentCoordinator.coordinator(for: conversationId))
        self._turnProjection = StateObject(wrappedValue: ChatTurnProjectionStore(conversationId: conversationId))
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
        turnProjection.turns
    }

    private var visibleTurns: [MessageDisplayTurn] {
        Array(displayTurns.suffix(visibleHistoryLimit))
    }

    private var hiddenTurnCount: Int {
        max(0, displayTurns.count - visibleHistoryLimit)
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
            let contentMaxWidth = min(viewportWidth, 760)
            let rowAvailableWidth = max(280, contentMaxWidth - 24)

            ScrollViewReader { scrollProxy in
                ZStack {
                    theme.background
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        ZStack(alignment: .bottomTrailing) {
                            ScrollView(.vertical, showsIndicators: true) {
                                if displayTurns.isEmpty && !coordinator.isGenerating {
                                    emptyConversationHero
                                        .padding(.horizontal, 14)
                                        .padding(.top, 24)
                                        .frame(maxWidth: contentMaxWidth)
                                        .frame(maxWidth: .infinity)
                                        .frame(minHeight: max(300, geo.size.height - 130), alignment: .top)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            handleBackgroundTap()
                                        }
                                } else {
                                    VStack(spacing: 14) {
                                        if hiddenTurnCount > 0 {
                                            Button {
                                                prependHistoryAnchorRevision &+= 1
                                                visibleHistoryLimit = min(displayTurns.count, visibleHistoryLimit + 50)
                                            } label: {
                                                Label("加载更早的 \(hiddenTurnCount) 条消息", systemImage: "arrow.up")
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundColor(theme.accent)
                                                    .padding(.horizontal, 14)
                                                    .padding(.vertical, 8)
                                                    .background(theme.cardBackground)
                                                    .clipShape(Capsule())
                                                    .overlay(Capsule().stroke(theme.border, lineWidth: 1))
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.bottom, 2)
                                        }

                                        let turns = visibleTurns
                                        ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                                            let isLastAssistant = index == turns.count - 1 && turn.role == .assistant
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
                                                    editingTurnId = turn.id
                                                    centerTurnForEditing(turn.id, using: scrollProxy)
                                                },
                                                onEditEnd: {
                                                    editingTurnId = nil
                                                    pendingEditScrollTurnId = nil
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
                                                    requestAutoFollowFromBottom()
                                                    coordinator.startRetryFromMessage(
                                                        conversationId: conversationId,
                                                        messageId: turn.primaryMessageId,
                                                        newPrompt: newContent,
                                                        settings: workspace.settings,
                                                        servers: workspace.servers
                                                    )
                                                },
                                                onRetry: {
                                                    dismissKeyboard()
                                                    selectedTurnId = nil
                                                    requestAutoFollowFromBottom()
                                                    coordinator.startRetryFromMessage(
                                                        conversationId: conversationId,
                                                        messageId: turn.primaryMessageId,
                                                        settings: workspace.settings,
                                                        servers: workspace.servers
                                                    )
                                                },
                                                onDelete: {
                                                    dismissKeyboard()
                                                    pendingDeleteTurn = turn
                                                }
                                            )
                                            .equatable()
                                            .id(turn.id)
                                        }

                                        if coordinator.isGenerating && visibleTurns.last?.role != .assistant {
                                            generatingStatusRow
                                                .frame(maxWidth: rowAvailableWidth, alignment: .leading)
                                                .id("generating_status")
                                        }

                                        if let err = coordinator.errorMessage {
                                            errorBanner(err)
                                                .frame(maxWidth: rowAvailableWidth)
                                                .id("error_status")
                                        }

                                        Color.clear
                                            .frame(
                                                height: isKeyboardVisible && editingTurnId != nil
                                                    ? max(48, geo.size.height * 0.36)
                                                    : 14
                                            )
                                            .id("chat_bottom_anchor")
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.top, 10)
                                    .frame(maxWidth: contentMaxWidth)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        ChatScrollBridgeView(
                                            isViewActive: isChatVisible,
                                            isGenerating: coordinator.isGenerating,
                                            hasMessages: !displayTurns.isEmpty || coordinator.isGenerating,
                                            autoFollowOutput: autoFollowOutput,
                                            forceBottomRevision: forceBottomScrollRevision,
                                            prependHistoryRevision: prependHistoryAnchorRevision,
                                            onAutoFollowChanged: { newFollow in
                                                if autoFollowOutput != newFollow {
                                                    autoFollowOutput = newFollow
                                                }
                                            },
                                            onJumpButtonVisibilityChanged: { visible in
                                                if showJumpToBottomButton != visible {
                                                    withAnimation(.easeOut(duration: 0.16)) {
                                                        showJumpToBottomButton = visible
                                                    }
                                                }
                                            }
                                        )
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .environment(\.chatLayoutDiagnosticsEnabled, isLayoutDiagnosticsEnabled)
                            .coordinateSpace(name: ChatLayoutCoordinateSpace.name)
                            .onPreferenceChange(ChatLayoutFramesPreferenceKey.self) { samples in
                                layoutFrames = samples
                            }
                            .scrollDismissesKeyboard(editingTurnId == nil ? .interactively : .never)

                            LinearGradient(
                                stops: [
                                    .init(color: theme.background.opacity(0), location: 0),
                                    .init(color: theme.background.opacity(0.88), location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 16)
                            .frame(maxWidth: .infinity)
                            .allowsHitTesting(false)

                            if showJumpToBottomButton && !displayTurns.isEmpty {
                                jumpToBottomButton
                                    .padding(.trailing, 14)
                                    .padding(.bottom, 10)
                                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        composerDock(contentMaxWidth: contentMaxWidth)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            visibleHistoryLimit = 50
            autoFollowOutput = true
            showJumpToBottomButton = false
        }
        .onDisappear {
            isChatVisible = false
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
                            layoutFrames.removeAll()
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
            layoutFrames.removeAll()
        }) {
            ChatLayoutInspectorSheet(
                report: layoutInspectorReport,
                theme: theme,
                isDiagnosticsEnabled: $isLayoutDiagnosticsEnabled,
                onDiagnosticsChanged: { enabled in
                    layoutFrames.removeAll()
                    guard enabled else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        guard isLayoutDiagnosticsEnabled else { return }
                        layoutInspectorReport = makeLayoutInspectorReport()
                    }
                }
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

    private var jumpToBottomButton: some View {
        Button {
            requestAutoFollowFromBottom()
        } label: {
            HStack(spacing: 5) {
                if coordinator.isGenerating {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 6, height: 6)
                    Text("回到底部")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                }
                Image(systemName: "arrow.down")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(coordinator.isGenerating ? theme.accent : theme.primaryText)
            }
            .padding(.horizontal, coordinator.isGenerating ? 12 : 9.5)
            .padding(.vertical, coordinator.isGenerating ? 7.5 : 9.5)
            .background(theme.cardBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(coordinator.isGenerating ? theme.accent.opacity(0.45) : theme.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(theme.isDark ? 0.3 : 0.1), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func requestAutoFollowFromBottom() {
        autoFollowOutput = true
        showJumpToBottomButton = false
        forceBottomScrollRevision &+= 1
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
            let hStack = layoutFrames["assistantHStack|\(turn.id)"]
            let avatar = layoutFrames["avatar|assistant|\(turn.id)"]
            let actionBar = layoutFrames["actionBar|\(turn.id)"]
            let editor = layoutFrames["editor|\(turn.id)"]
            lines.append("当前选中状态：\(selectedTurnId == turn.id ? "是" : "否")")
            lines.append("助手 HStack 外框：\(layoutFrameDescription(hStack))")
            lines.append("助手头像：\(layoutFrameDescription(avatar))")
            lines.append("助手列：\(layoutFrameDescription(column))")
            if let editor = editor {
                lines.append("编辑器：\(layoutFrameDescription(editor))")
            }
            lines.append("助手卡片：\(layoutFrameDescription(card))")
            if let card = card, let actionBar = actionBar {
                let cardToActions = actionBar.minY - card.maxY
                lines.append("操作栏：\(layoutFrameDescription(actionBar))")
                lines.append("卡片底部 → 操作栏顶部：\(String(format: "%.1f", cardToActions)) pt")
            }

            if let frame = layoutFrames["toolSummary|\(turn.id)"] {
                lines.append("工具摘要：\(layoutFrameDescription(frame))")
            }
            if let frame = layoutFrames["reasoning|\(turn.id)"] {
                lines.append("思考摘要：\(layoutFrameDescription(frame))")
            }
            if let frame = layoutFrames["markdown|\(turn.id)"] {
                lines.append("Markdown 正文外框：\(layoutFrameDescription(frame))")
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
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.14))
                    .frame(width: 26, height: 26)
                Image(systemName: "sparkles")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(theme.accent)
            }
            .padding(.top, 2)

            ThinkingStatusView(
                statusText: coordinator.statusText,
                startDate: coordinator.thinkingStartTime ?? Date(),
                theme: theme,
                isPaused: false
            )
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            )

            Spacer(minLength: 24)
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
                    Button {
                        dismissKeyboard()
                        requestAutoFollowFromBottom()
                        coordinator.startRetryFromMessage(
                            conversationId: conversationId,
                            messageId: lastTurn.primaryMessageId,
                            settings: workspace.settings,
                            servers: workspace.servers
                        )
                    } label: {
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
                    .buttonStyle(.plain)
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
        .padding(.leading, 34)
    }

    private func composerDock(contentMaxWidth: CGFloat) -> some View {
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

                if turnProjection.rawMessageCount > 0 {
                    ContextTokenBadge(
                        conversationId: conversationId,
                        theme: theme
                    )
                }

                Spacer(minLength: 6)

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
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
        .background(theme.background)
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

    private func centerTurnForEditing(_ turnId: String, using proxy: ScrollViewProxy) {
        pendingEditScrollTurnId = turnId
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
        if selectedTurnId != nil && editingTurnId == nil {
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
        requestAutoFollowFromBottom()
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
        requestAutoFollowFromBottom()
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

/// 专为 iOS 16+ 打造的原生 UIScrollView 同步底部锚定与惯性手势桥接器：
/// 1. 在 contentSize / bounds 布局变化的同一帧内同步调整 contentOffset，彻底消除异步 scrollProxy.scrollTo 的帧滞后与抽搐；
/// 2. 手指触摸拖动时立即让出控制权，不拦截点击、不暂停文本流、不抢夺原生 60/120fps 惯性滑动；
/// 3. 加载顶部历史消息时自动保持当前视口锚点不跳回顶部。
private struct ChatScrollBridgeView: UIViewRepresentable {
    var isViewActive: Bool
    var isGenerating: Bool
    var hasMessages: Bool
    var autoFollowOutput: Bool
    var forceBottomRevision: Int
    var prependHistoryRevision: Int
    var onAutoFollowChanged: (Bool) -> Void
    var onJumpButtonVisibilityChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isViewActive: isViewActive,
            isGenerating: isGenerating,
            hasMessages: hasMessages,
            autoFollowOutput: autoFollowOutput,
            forceBottomRevision: forceBottomRevision,
            prependHistoryRevision: prependHistoryRevision,
            onAutoFollowChanged: onAutoFollowChanged,
            onJumpButtonVisibilityChanged: onJumpButtonVisibilityChanged
        )
    }

    func makeUIView(context: Context) -> BridgeProbeUIView {
        let view = BridgeProbeUIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onMoveToWindowOrSuperview = { [weak coordinator = context.coordinator] probe in
            coordinator?.attachIfNeeded(from: probe)
        }
        return view
    }

    func updateUIView(_ uiView: BridgeProbeUIView, context: Context) {
        let coord = context.coordinator
        coord.isViewActive = isViewActive
        coord.isGenerating = isGenerating
        coord.hasMessages = hasMessages
        coord.onAutoFollowChanged = onAutoFollowChanged
        coord.onJumpButtonVisibilityChanged = onJumpButtonVisibilityChanged

        if coord.autoFollowOutput != autoFollowOutput {
            coord.autoFollowOutput = autoFollowOutput
        }

        let forceChanged = coord.forceBottomRevision != forceBottomRevision
        coord.forceBottomRevision = forceBottomRevision

        let prependChanged = coord.prependHistoryRevision != prependHistoryRevision
        coord.prependHistoryRevision = prependHistoryRevision

        coord.attachIfNeeded(from: uiView)

        if prependChanged {
            coord.capturePrependAnchor()
        }

        if forceChanged && isViewActive {
            coord.scrollToBottomRequestedByUser()
        }
    }

    final class BridgeProbeUIView: UIView {
        var onMoveToWindowOrSuperview: ((UIView) -> Void)?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            onMoveToWindowOrSuperview?(self)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onMoveToWindowOrSuperview?(self)
        }
    }

    final class Coordinator: NSObject {
        var isViewActive: Bool
        var isGenerating: Bool
        var hasMessages: Bool
        var autoFollowOutput: Bool
        var forceBottomRevision: Int
        var prependHistoryRevision: Int
        var onAutoFollowChanged: (Bool) -> Void
        var onJumpButtonVisibilityChanged: (Bool) -> Void

        private weak var attachedScrollView: UIScrollView?
        private var contentSizeObservation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?
        private var contentOffsetObservation: NSKeyValueObservation?

        private var isProgrammaticScroll: Bool = false
        private var isUserPanning: Bool = false
        private var isAnimatingToBottom: Bool = false
        private var initialPositioningDeadline: CFAbsoluteTime = 0
        private var didPerformInitialSnap: Bool = false
        private var pendingPrependAnchor: (height: CGFloat, offsetY: CGFloat)? = nil
        private var lastReportedJumpButtonVisible: Bool = false

        init(
            isViewActive: Bool,
            isGenerating: Bool,
            hasMessages: Bool,
            autoFollowOutput: Bool,
            forceBottomRevision: Int,
            prependHistoryRevision: Int,
            onAutoFollowChanged: @escaping (Bool) -> Void,
            onJumpButtonVisibilityChanged: @escaping (Bool) -> Void
        ) {
            self.isViewActive = isViewActive
            self.isGenerating = isGenerating
            self.hasMessages = hasMessages
            self.autoFollowOutput = autoFollowOutput
            self.forceBottomRevision = forceBottomRevision
            self.prependHistoryRevision = prependHistoryRevision
            self.onAutoFollowChanged = onAutoFollowChanged
            self.onJumpButtonVisibilityChanged = onJumpButtonVisibilityChanged
            super.init()
            if hasMessages {
                self.initialPositioningDeadline = CFAbsoluteTimeGetCurrent() + 0.45
            }
        }

        deinit {
            contentSizeObservation?.invalidate()
            boundsObservation?.invalidate()
            contentOffsetObservation?.invalidate()
        }

        func attachIfNeeded(from view: UIView) {
            var current: UIView? = view.superview
            while let candidate = current {
                if let sv = candidate as? UIScrollView {
                    if attachedScrollView !== sv {
                        detachCurrentScrollView()
                        attachedScrollView = sv
                        // 关闭内容触摸延迟，使折叠卡片、复制按钮点击零粘滞
                        sv.delaysContentTouches = false
                        sv.canCancelContentTouches = true
                        sv.keyboardDismissMode = .interactive
                        sv.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
                        setupObservations(for: sv)
                        performInitialSnapIfNeeded(on: sv)
                    }
                    return
                }
                current = candidate.superview
            }
        }

        private func detachCurrentScrollView() {
            if let prev = attachedScrollView {
                prev.panGestureRecognizer.removeTarget(self, action: #selector(handlePan(_:)))
            }
            contentSizeObservation?.invalidate()
            boundsObservation?.invalidate()
            contentOffsetObservation?.invalidate()
            contentSizeObservation = nil
            boundsObservation = nil
            contentOffsetObservation = nil
            attachedScrollView = nil
        }

        func capturePrependAnchor() {
            guard let sv = attachedScrollView else { return }
            pendingPrependAnchor = (height: sv.contentSize.height, offsetY: sv.contentOffset.y)
        }

        func scrollToBottomRequestedByUser() {
            autoFollowOutput = true
            isUserPanning = false
            pendingPrependAnchor = nil
            reportJumpButtonVisibility(false)

            guard let sv = attachedScrollView, sv.bounds.height > 0 else { return }
            let targetY = bottomOffset(for: sv)
            let distance = targetY - sv.contentOffset.y
            guard abs(distance) > 1 else { return }

            if distance > sv.bounds.height * 1.6 {
                // 跨屏距离很大时先无动画跳到近底位置再轻柔落底，避免长距离动画掉帧
                setOffsetSynchronously(on: sv, y: max(-sv.adjustedContentInset.top, targetY - sv.bounds.height * 0.45))
            }

            isAnimatingToBottom = true
            sv.setContentOffset(CGPoint(x: 0, y: bottomOffset(for: sv)), animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                guard let self else { return }
                self.isAnimatingToBottom = false
                if self.autoFollowOutput, let sv = self.attachedScrollView, !self.isUserInteracting(with: sv) {
                    self.setOffsetSynchronously(on: sv, y: self.bottomOffset(for: sv))
                }
            }
        }

        private func isUserInteracting(with sv: UIScrollView) -> Bool {
            isUserPanning || sv.isTracking || sv.isDragging || sv.isDecelerating
        }

        private func bottomOffset(for sv: UIScrollView) -> CGFloat {
            let minOffset = -sv.adjustedContentInset.top
            let rawMax = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
            return max(minOffset, rawMax)
        }

        private func setOffsetSynchronously(on sv: UIScrollView, y: CGFloat) {
            let clampedMin = -sv.adjustedContentInset.top
            let targetY = max(clampedMin, y)
            guard abs(sv.contentOffset.y - targetY) > 0.5 else { return }
            isProgrammaticScroll = true
            sv.contentOffset = CGPoint(x: sv.contentOffset.x, y: targetY)
            isProgrammaticScroll = false
        }

        private func performInitialSnapIfNeeded(on sv: UIScrollView) {
            guard hasMessages,
                  !didPerformInitialSnap,
                  sv.bounds.height > 10,
                  sv.contentSize.height > 10 else { return }
            didPerformInitialSnap = true
            if initialPositioningDeadline == 0 {
                initialPositioningDeadline = CFAbsoluteTimeGetCurrent() + 0.35
            }
            setOffsetSynchronously(on: sv, y: bottomOffset(for: sv))
        }

        private func setupObservations(for sv: UIScrollView) {
            contentSizeObservation = sv.observe(\.contentSize, options: [.old, .new]) { [weak self] scrollView, change in
                guard let self, self.isViewActive else { return }
                let oldHeight = change.oldValue?.height ?? 0
                let newHeight = change.newValue?.height ?? scrollView.contentSize.height
                guard abs(newHeight - oldHeight) > 0.5, scrollView.bounds.height > 10 else { return }

                // 1. 顶部加载更早历史消息时：保持原阅读位置不跳动
                if let anchor = self.pendingPrependAnchor, newHeight > anchor.height + 4 {
                    self.pendingPrependAnchor = nil
                    let delta = newHeight - anchor.height
                    self.setOffsetSynchronously(on: scrollView, y: anchor.offsetY + delta)
                    return
                }

                // 2. 页面初次打开时的布局稳定窗口：无动画静默锚定到底部（解决 iOS 16 无 defaultScrollAnchor 问题）
                if self.hasMessages,
                   !self.isUserInteracting(with: scrollView),
                   self.autoFollowOutput,
                   CFAbsoluteTimeGetCurrent() <= self.initialPositioningDeadline {
                    self.didPerformInitialSnap = true
                    self.setOffsetSynchronously(on: scrollView, y: self.bottomOffset(for: scrollView))
                    return
                }

                // 3. 流式输出或卡片展开时：若处于自动跟随且用户未触摸滚动，在同一布局帧内同步贴底
                guard !self.isUserInteracting(with: scrollView), !self.isAnimatingToBottom else {
                    self.refreshJumpButtonState(for: scrollView)
                    return
                }

                if self.autoFollowOutput {
                    self.setOffsetSynchronously(on: scrollView, y: self.bottomOffset(for: scrollView))
                    self.reportJumpButtonVisibility(false)
                } else {
                    // 用户正在阅读上方内容：保持当前 contentOffset 不变，仅防止内容缩小时越界悬空
                    let maxAllowed = self.bottomOffset(for: scrollView)
                    if scrollView.contentOffset.y > maxAllowed + 1 {
                        self.setOffsetSynchronously(on: scrollView, y: maxAllowed)
                    }
                    self.refreshJumpButtonState(for: scrollView)
                }
            }

            boundsObservation = sv.observe(\.bounds, options: [.old, .new]) { [weak self] scrollView, change in
                guard let self, self.isViewActive else { return }
                let oldH = change.oldValue?.size.height ?? 0
                let newH = change.newValue?.size.height ?? scrollView.bounds.height
                guard abs(newH - oldH) > 1, newH > 10 else { return }

                if !self.didPerformInitialSnap {
                    self.performInitialSnapIfNeeded(on: scrollView)
                    return
                }

                // 键盘弹起使可视区域缩小时，若原本开启自动跟随则同步上推到底部
                if self.autoFollowOutput && !self.isUserInteracting(with: scrollView) && !self.isAnimatingToBottom {
                    self.setOffsetSynchronously(on: scrollView, y: self.bottomOffset(for: scrollView))
                } else {
                    self.refreshJumpButtonState(for: scrollView)
                }
            }

            contentOffsetObservation = sv.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                guard let self, self.isViewActive, !self.isProgrammaticScroll, !self.isAnimatingToBottom else { return }
                let distanceFromBottom = self.bottomOffset(for: scrollView) - scrollView.contentOffset.y

                if self.isUserInteracting(with: scrollView) {
                    if distanceFromBottom > 42 && self.autoFollowOutput {
                        self.autoFollowOutput = false
                        DispatchQueue.main.async { [weak self] in
                            self?.onAutoFollowChanged(false)
                        }
                    } else if distanceFromBottom <= 18 && !self.autoFollowOutput && !scrollView.isDragging {
                        self.autoFollowOutput = true
                        DispatchQueue.main.async { [weak self] in
                            self?.onAutoFollowChanged(true)
                        }
                    }
                } else if distanceFromBottom <= 20 && !self.autoFollowOutput {
                    // 惯性滑动自然停在底部附近时自动恢复底部跟随
                    self.autoFollowOutput = true
                    DispatchQueue.main.async { [weak self] in
                        self?.onAutoFollowChanged(true)
                    }
                }

                self.refreshJumpButtonState(for: scrollView)
            }
        }

        private func refreshJumpButtonState(for sv: UIScrollView) {
            let scrollableRange = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.top + sv.adjustedContentInset.bottom
            guard scrollableRange > 60 else {
                reportJumpButtonVisibility(false)
                return
            }
            let distanceFromBottom = bottomOffset(for: sv) - sv.contentOffset.y
            let shouldShow = distanceFromBottom > 56
            reportJumpButtonVisibility(shouldShow)
        }

        private func reportJumpButtonVisibility(_ visible: Bool) {
            guard lastReportedJumpButtonVisible != visible else { return }
            lastReportedJumpButtonVisible = visible
            DispatchQueue.main.async { [weak self] in
                self?.onJumpButtonVisibilityChanged(visible)
            }
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let sv = attachedScrollView else { return }
            switch recognizer.state {
            case .began:
                isUserPanning = true
                isAnimatingToBottom = false
                initialPositioningDeadline = 0
            case .changed:
                let distanceFromBottom = bottomOffset(for: sv) - sv.contentOffset.y
                if distanceFromBottom > 42 && autoFollowOutput {
                    autoFollowOutput = false
                    DispatchQueue.main.async { [weak self] in
                        self?.onAutoFollowChanged(false)
                    }
                }
            case .ended, .cancelled, .failed:
                isUserPanning = false
                let distanceFromBottom = bottomOffset(for: sv) - sv.contentOffset.y
                if !sv.isDecelerating && distanceFromBottom <= 24 && !autoFollowOutput {
                    autoFollowOutput = true
                    DispatchQueue.main.async { [weak self] in
                        self?.onAutoFollowChanged(true)
                    }
                }
                refreshJumpButtonState(for: sv)
            default:
                break
            }
        }
    }
}
