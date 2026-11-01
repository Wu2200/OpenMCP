import SwiftUI
import UIKit

private struct ReasoningElapsedBadge: View {
    let startDate: Date
    let theme: AppThemePalette

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startDate))
            Text(ThinkingStatusView.formatElapsed(elapsed))
                .font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundColor(theme.secondaryText)
        }
    }
}

struct ReasoningFoldCardView: View, Equatable {
    let reasoningText: String
    let isStreamingReasoning: Bool
    let startDate: Date
    let theme: AppThemePalette
    var width: CGFloat? = nil

    @State private var isExpanded: Bool = false
    @State private var showingFullReasoningSheet: Bool = false

    static func == (lhs: ReasoningFoldCardView, rhs: ReasoningFoldCardView) -> Bool {
        lhs.reasoningText == rhs.reasoningText &&
        lhs.isStreamingReasoning == rhs.isStreamingReasoning &&
        lhs.startDate == rhs.startDate &&
        lhs.theme == rhs.theme &&
        lhs.width == rhs.width
    }

    private var previewLine: String {
        let trimmed = reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "正在深度思考..." }
        let suffixSlice = trimmed.suffix(220)
        let lines = suffixSlice
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last ?? "正在深度思考..."
    }

    private static let inlineMaxCharacters = 3_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(theme.accent)

                    if isStreamingReasoning {
                        HStack(spacing: 5) {
                            Text("深度思考中")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            ReasoningElapsedBadge(startDate: startDate, theme: theme)
                        }
                    } else {
                        Text("已深度思考")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                    }

                    if !isExpanded {
                        Text(previewLine)
                            .font(.system(size: 11.5))
                            .foregroundColor(theme.mutedText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(theme.mutedText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Rectangle()
                    .fill(theme.border.opacity(0.75))
                    .frame(height: 1)

                let trimmed = reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
                let isTruncated = trimmed.count > Self.inlineMaxCharacters
                let inlineText = isTruncated
                    ? String(trimmed.prefix(Self.inlineMaxCharacters)) + "\n…"
                    : trimmed

                VStack(alignment: .leading, spacing: 6) {
                    Text(inlineText)
                        .font(.system(size: 12.5))
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if isTruncated {
                        Button {
                            showingFullReasoningSheet = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("查看完整思考全文 (\(trimmed.count.formatted()) 字)")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundColor(theme.accent)
                            .padding(.top, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .frame(width: width, alignment: .leading)
        .background(theme.elevatedBackground.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
        .sheet(isPresented: $showingFullReasoningSheet) {
            AttachmentFilePreviewSheet(
                attachment: ChatAttachment(
                    kind: .file,
                    fileName: "深度思考过程.txt",
                    mimeType: "text/plain",
                    fileSize: reasoningText.utf8.count,
                    textContent: reasoningText
                ),
                theme: theme
            )
        }
    }
}

private struct ActiveStreamingAssistantCardView: View {
    let turn: MessageDisplayTurn
    let theme: AppThemePalette
    let bubbleColumnWidth: CGFloat
    let innerContentWidth: CGFloat
    let statusText: String
    let thinkingStartTime: Date?
    let isSelected: Bool
    let onSelectToggle: (() -> Void)?
    let onDismissSelection: (() -> Void)?
    @ObservedObject var streamingState: StreamingTurnState

    var body: some View {
        let activeMsgId = streamingState.activeMessageId
        let liveText = streamingState.displayedText
        let liveReasoning = streamingState.displayedReasoning
        let liveTrimmedText = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveTrimmedReasoning = liveReasoning.trimmingCharacters(in: .whitespacesAndNewlines)

        let steps = turn.steps
        let hasPriorVisibleContent = steps.contains { step in
            guard step.id != activeMsgId else { return false }
            return !step.isEmptyPlaceholder
        }
        let currentStepCalls = steps.last(where: { $0.id == activeMsgId })?.toolCalls ?? []
        let isWaitingInitialOutput = !hasPriorVisibleContent
            && liveTrimmedText.isEmpty
            && liveTrimmedReasoning.isEmpty
            && currentStepCalls.isEmpty
            && turn.toolCalls.isEmpty

        if isWaitingInitialOutput {
            HStack(spacing: 0) {
                ThinkingStatusView(
                    statusText: statusText,
                    startDate: thinkingStartTime ?? turn.createdAt,
                    theme: theme,
                    isPaused: false
                )
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(isSelected ? theme.accent.opacity(0.45) : theme.border, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .onTapGesture {
                    onSelectToggle?()
                }

                Spacer(minLength: 16)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onDismissSelection?()
                    }
            }
            .frame(width: bubbleColumnWidth, alignment: .leading)
            .modifier(ChatLayoutProbe(identifier: "assistantCard|\(turn.id)"))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                    let isLiveStep = (step.id == activeMsgId) || (activeMsgId == nil && idx == steps.count - 1)
                    let stepReasoning = isLiveStep && !liveTrimmedReasoning.isEmpty ? liveReasoning : step.reasoningContent
                    let stepText = isLiveStep && !liveTrimmedText.isEmpty ? liveText : step.content
                    let trimmedStepReasoning = stepReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedStepText = stepText.trimmingCharacters(in: .whitespacesAndNewlines)

                    if !trimmedStepReasoning.isEmpty {
                        ReasoningFoldCardView(
                            reasoningText: stepReasoning,
                            isStreamingReasoning: isLiveStep && trimmedStepText.isEmpty && step.toolCalls.isEmpty,
                            startDate: thinkingStartTime ?? turn.createdAt,
                            theme: theme,
                            width: innerContentWidth
                        )
                        .equatable()
                        .modifier(ChatLayoutProbe(identifier: idx == 0 ? "reasoning|\(turn.id)" : nil))
                    }

                    if !trimmedStepText.isEmpty {
                        MarkdownDocumentView(
                            content: stepText,
                            theme: theme,
                            contentWidth: innerContentWidth,
                            isStreaming: isLiveStep,
                            diagnosticIDPrefix: idx == steps.count - 1 ? turn.id : nil
                        )
                        .frame(width: innerContentWidth, alignment: .leading)
                        .modifier(ChatLayoutProbe(identifier: idx == steps.count - 1 ? "markdown|\(turn.id)" : nil))
                    }

                    if !step.toolCalls.isEmpty {
                        ToolCallSummaryGroupView(toolCalls: step.toolCalls, theme: theme)
                            .equatable()
                            .frame(width: innerContentWidth, alignment: .leading)
                            .modifier(ChatLayoutProbe(identifier: idx == 0 ? "toolSummary|\(turn.id)" : nil))
                    }

                    if isLiveStep && trimmedStepText.isEmpty && trimmedStepReasoning.isEmpty {
                        let anyExecutingTool = step.toolCalls.contains(where: { $0.isExecuting })
                        if !anyExecutingTool {
                            ThinkingStatusView(
                                statusText: statusText,
                                startDate: thinkingStartTime ?? turn.createdAt,
                                theme: theme,
                                isPaused: false
                            )
                            .padding(.top, 2)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: bubbleColumnWidth, alignment: .leading)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(isSelected ? theme.accent.opacity(0.45) : theme.border, lineWidth: 1)
            )
            .modifier(ChatLayoutProbe(identifier: "assistantCard|\(turn.id)"))
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .onTapGesture {
                onSelectToggle?()
            }
        }
    }
}

struct MessageBubbleView: View, Equatable {
    let turn: MessageDisplayTurn
    let theme: AppThemePalette
    var availableWidth: CGFloat = UIScreen.main.bounds.width - 20
    var modelName: String = "Assistant"
    var isGenerating: Bool = false
    var isActiveGeneratingTurn: Bool = false
    var statusText: String = ""
    var thinkingStartTime: Date? = nil
    var streamingState: StreamingTurnState
    var isSelected: Bool = false
    var onSelectToggle: (() -> Void)? = nil
    var onEditBegin: (() -> Void)? = nil
    var onEditEnd: (() -> Void)? = nil
    var onDismissSelection: (() -> Void)? = nil
    var onEditSave: ((String) -> Void)? = nil
    var onEditAndResend: ((String) -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    static func == (lhs: MessageBubbleView, rhs: MessageBubbleView) -> Bool {
        lhs.turn == rhs.turn &&
        lhs.theme == rhs.theme &&
        abs(lhs.availableWidth - rhs.availableWidth) < 0.5 &&
        lhs.modelName == rhs.modelName &&
        lhs.isGenerating == rhs.isGenerating &&
        lhs.isActiveGeneratingTurn == rhs.isActiveGeneratingTurn &&
        lhs.statusText == rhs.statusText &&
        lhs.thinkingStartTime == rhs.thinkingStartTime &&
        lhs.isSelected == rhs.isSelected
    }

    @State private var isCopied: Bool = false
    @State private var isEditing: Bool = false
    @State private var draftText: String = ""
    @State private var previewingFileAttachment: ChatAttachment? = nil
    @State private var previewingImageAttachment: ChatAttachment? = nil
    @FocusState private var isEditFieldFocused: Bool

    private var bubbleColumnWidth: CGFloat {
        max(220, availableWidth - 30)
    }

    private var editableRawText: String {
        let trimmed = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return turn.content
        }
        if let longAtt = turn.attachments.first(where: { $0.kind == .longText }),
           let text = longAtt.textContent {
            return text
        }
        return turn.content
    }

    var body: some View {
        Group {
            if turn.role == .user {
                userTurnView
            } else {
                assistantTurnView
            }
        }
        .frame(width: availableWidth)
        .modifier(ChatLayoutProbe(identifier: "row|\(turn.role.rawValue)|\(turn.id)"))
        .sheet(item: $previewingFileAttachment) { fileAtt in
            AttachmentFilePreviewSheet(attachment: fileAtt, theme: theme)
        }
        .sheet(item: $previewingImageAttachment) { imgAtt in
            AttachmentImagePreviewSheet(attachment: imgAtt, theme: theme)
        }
    }

    private var userTurnView: some View {
        let imageAtts = turn.attachments.filter { $0.kind == .image }
        let fileAtts = turn.attachments.filter { $0.kind != .image }
        let trimmed = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let autoPackagedLongText: ChatAttachment? = (!trimmed.isEmpty && ChatAttachment.shouldPackageAsLongText(trimmed))
            ? ChatAttachment.makeLongTextAttachment(from: trimmed)
            : nil

        return HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 24)
                .contentShape(Rectangle())
                .onTapGesture {
                    onDismissSelection?()
                }

            if isEditing {
                editEditorBox(allowResend: true)
                    .frame(width: bubbleColumnWidth)
                    .id("message-editor-\(turn.id)")
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    if !imageAtts.isEmpty {
                        AttachmentImageGridView(
                            attachments: imageAtts,
                            theme: theme,
                            isSelected: isSelected,
                            onCardTap: {
                                onSelectToggle?()
                            },
                            onSelectImage: { img in
                                previewingImageAttachment = img
                            }
                        )
                    }

                    ForEach(fileAtts) { fileAtt in
                        AttachmentFileCardView(
                            attachment: fileAtt,
                            theme: theme,
                            isSelected: isSelected,
                            onCardTap: {
                                onSelectToggle?()
                            },
                            onPreviewTap: {
                                previewingFileAttachment = fileAtt
                            }
                        )
                    }

                    if let packaged = autoPackagedLongText {
                        AttachmentFileCardView(
                            attachment: packaged,
                            theme: theme,
                            isSelected: isSelected,
                            onCardTap: {
                                onSelectToggle?()
                            },
                            onPreviewTap: {
                                previewingFileAttachment = packaged
                            }
                        )
                    } else if !trimmed.isEmpty {
                        Text(turn.content)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(theme.primaryText)
                            .lineSpacing(3.5)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(theme.userMessageBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .stroke(isSelected ? theme.accent.opacity(0.55) : theme.accent.opacity(0.18), lineWidth: 1)
                            )
                            .modifier(ChatLayoutProbe(identifier: "userText|\(turn.id)"))
                            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .onTapGesture {
                                onSelectToggle?()
                            }
                    }

                    if isSelected {
                        floatingActionPill
                    }
                }
                .frame(maxWidth: bubbleColumnWidth, alignment: .trailing)
            }

            compactAvatar(isUser: true)
                .onTapGesture {
                    onSelectToggle?()
                }
        }
        .frame(width: availableWidth, alignment: .trailing)
    }

    private var assistantTurnView: some View {
        let innerContentWidth = max(180, bubbleColumnWidth - 24)

        return HStack(alignment: .top, spacing: 6) {
            compactAvatar(isUser: false)
                .onTapGesture {
                    onSelectToggle?()
                }

            VStack(alignment: .leading, spacing: 6) {
                if isEditing {
                    editEditorBox(allowResend: false)
                        .frame(width: bubbleColumnWidth)
                        .id("message-editor-\(turn.id)")
                } else {
                    if isActiveGeneratingTurn {
                        ActiveStreamingAssistantCardView(
                            turn: turn,
                            theme: theme,
                            bubbleColumnWidth: bubbleColumnWidth,
                            innerContentWidth: innerContentWidth,
                            statusText: statusText,
                            thinkingStartTime: thinkingStartTime,
                            isSelected: isSelected,
                            onSelectToggle: onSelectToggle,
                            onDismissSelection: onDismissSelection,
                            streamingState: streamingState
                        )
                    } else {
                        staticAssistantCard(innerContentWidth: innerContentWidth)
                    }

                    if isSelected {
                        floatingActionPill
                    }
                }
            }
            .frame(width: bubbleColumnWidth, alignment: .leading)
            .modifier(ChatLayoutProbe(identifier: "assistantColumn|\(turn.id)"))
        }
        .frame(width: availableWidth, alignment: .leading)
        .modifier(ChatLayoutProbe(identifier: "assistantHStack|\(turn.id)"))
    }

    @ViewBuilder
    private func staticAssistantCard(innerContentWidth: CGFloat) -> some View {
        let stepsToRender: [AssistantTurnStep] = turn.steps.isEmpty
            ? [AssistantTurnStep(id: turn.id, content: turn.content, reasoningContent: turn.reasoningContent, toolCalls: turn.toolCalls)]
            : turn.steps

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(stepsToRender.enumerated()), id: \.element.id) { idx, step in
                let trimmedReasoning = step.trimmedReasoning
                let trimmedText = step.trimmedContent

                if !trimmedReasoning.isEmpty {
                    ReasoningFoldCardView(
                        reasoningText: step.reasoningContent,
                        isStreamingReasoning: false,
                        startDate: turn.createdAt,
                        theme: theme,
                        width: innerContentWidth
                    )
                    .equatable()
                    .modifier(ChatLayoutProbe(identifier: idx == 0 ? "reasoning|\(turn.id)" : nil))
                }

                if !trimmedText.isEmpty {
                    MarkdownDocumentView(
                        content: step.content,
                        theme: theme,
                        contentWidth: innerContentWidth,
                        isStreaming: false,
                        diagnosticIDPrefix: idx == stepsToRender.count - 1 ? turn.id : nil
                    )
                    .frame(width: innerContentWidth, alignment: .leading)
                    .modifier(ChatLayoutProbe(identifier: idx == stepsToRender.count - 1 ? "markdown|\(turn.id)" : nil))
                }

                if !step.toolCalls.isEmpty {
                    ToolCallSummaryGroupView(toolCalls: step.toolCalls, theme: theme)
                        .equatable()
                        .frame(width: innerContentWidth, alignment: .leading)
                        .modifier(ChatLayoutProbe(identifier: idx == 0 ? "toolSummary|\(turn.id)" : nil))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: bubbleColumnWidth, alignment: .leading)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(isSelected ? theme.accent.opacity(0.45) : theme.border, lineWidth: 1)
        )
        .modifier(ChatLayoutProbe(identifier: "assistantCard|\(turn.id)"))
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onTapGesture {
            onSelectToggle?()
        }
    }

    private func beginInlineEdit() {
        guard !isGenerating else { return }
        draftText = editableRawText
        withAnimation(.easeInOut(duration: 0.15)) {
            isEditing = true
        }
        onEditBegin?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard isEditing else { return }
            isEditFieldFocused = true
        }
    }

    private func compactAvatar(isUser: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isUser ? theme.accent : theme.accent.opacity(0.14))
                .frame(width: 24, height: 24)

            Image(systemName: isUser ? "person.fill" : "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isUser ? .white : theme.accent)
        }
        .padding(.top, 2)
        .contentShape(Circle())
        .modifier(ChatLayoutProbe(identifier: "avatar|\(isUser ? "user" : "assistant")|\(turn.id)"))
    }

    /// 用户消息与 AI 消息共用的唯一点击弹出胶囊菜单
    private var floatingActionPill: some View {
        let copyTarget = editableRawText

        return HStack(spacing: 4) {
            Button {
                guard !isGenerating else { return }
                onRetry?()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("重试")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(isGenerating ? theme.mutedText : theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)

            Divider()
                .frame(height: 12)
                .overlay(theme.border)

            Button {
                beginInlineEdit()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                    Text("编辑")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(isGenerating ? theme.mutedText : theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)

            if !copyTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                    .frame(height: 12)
                    .overlay(theme.border)

                Button {
                    UIPasteboard.general.string = copyTarget
                    withAnimation { isCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { isCopied = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text(isCopied ? "已复制" : "复制")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundColor(isCopied ? theme.accent : theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Divider()
                .frame(height: 12)
                .overlay(theme.border)

            Button {
                guard !isGenerating else { return }
                onDelete?()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                    Text("删除")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(isGenerating ? theme.mutedText : Color.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(theme.cardBackground)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(theme.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(theme.isDark ? 0.22 : 0.05), radius: 5, x: 0, y: 2)
        .modifier(ChatLayoutProbe(identifier: "actionBar|\(turn.id)"))
    }

    private func editEditorBox(allowResend: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("修改消息内容...", text: $draftText, axis: .vertical)
                .lineLimit(2...12)
                .focused($isEditFieldFocused)
                .font(.system(size: 15))
                .foregroundColor(theme.primaryText)
                .padding(12)
                .background(theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(theme.accent.opacity(0.45), lineWidth: 1)
                )

            HStack(spacing: 8) {
                Button {
                    isEditFieldFocused = false
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isEditing = false
                    }
                    onEditEnd?()
                } label: {
                    Text("取消")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(theme.cardBackground)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    isEditFieldFocused = false
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isEditing = false
                    }
                    onEditEnd?()
                    onEditSave?(trimmed)
                } label: {
                    Text("仅保存")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(theme.accent.opacity(0.14))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if allowResend {
                    Button {
                        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        isEditFieldFocused = false
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isEditing = false
                        }
                        onEditEnd?()
                        onEditAndResend?(trimmed)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 10.5))
                            Text("保存并重发")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(theme.accent)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .modifier(ChatLayoutProbe(identifier: "editor|\(turn.id)"))
    }
}

struct CodeBlockCard: View {
    let language: String
    let code: String
    let theme: AppThemePalette
    var cardWidth: CGFloat? = nil
    var isStreaming: Bool = false
    @State private var copied: Bool = false
    @State private var isInlineExpanded: Bool = false
    @State private var showingFullViewer: Bool = false

    private let previewLineThreshold = 10

    private var totalLines: Int {
        var count = 1
        for byte in code.utf8 where byte == 0x0A {
            count += 1
        }
        return count
    }

    private var isCollapsible: Bool {
        totalLines > previewLineThreshold || code.count > 520
    }

    private var displayedCode: String {
        if !isCollapsible || (isInlineExpanded && !isStreaming && totalLines <= 120) {
            return code
        }
        if isStreaming {
            return Self.extractLastLinesStable(from: code, exactLines: previewLineThreshold, maxChars: 1600)
        }
        return Self.extractFirstLinesExact(from: code, exactLines: previewLineThreshold, maxChars: 1600)
    }

    private static func extractFirstLinesExact(from text: String, exactLines: Int, maxChars: Int) -> String {
        guard !text.isEmpty, exactLines > 0 else { return "" }
        var idx = text.startIndex
        let end = text.endIndex
        var lines = 1
        var chars = 0

        while idx < end {
            if text[idx] == "\n" {
                if lines >= exactLines {
                    break
                }
                lines += 1
            }
            idx = text.index(after: idx)
            chars += 1
            if chars >= maxChars {
                break
            }
        }
        return String(text[..<idx])
    }

    private static func extractLastLinesStable(from text: String, exactLines: Int, maxChars: Int) -> String {
        guard !text.isEmpty, exactLines > 0 else { return "" }
        var idx = text.endIndex
        let start = text.startIndex
        var newlinesFound = 0
        var chars = 0

        while idx > start {
            let prev = text.index(before: idx)
            if text[prev] == "\n" {
                newlinesFound += 1
                if newlinesFound >= exactLines {
                    idx = text.index(after: prev)
                    break
                }
            }
            idx = prev
            chars += 1
            if chars >= maxChars {
                break
            }
        }

        let rawSlice = String(text[idx...])
        var lines = rawSlice.components(separatedBy: "\n")
        if lines.count > exactLines {
            lines = Array(lines.suffix(exactLines))
        }
        let cleaned = lines.map { line -> String in
            line.isEmpty ? " " : (line.count > 160 ? String(line.prefix(160)) : line)
        }
        if cleaned.count < exactLines {
            let pad = Array(repeating: " ", count: exactLines - cleaned.count)
            return (pad + cleaned).joined(separator: "\n")
        }
        return cleaned.joined(separator: "\n")
    }

    var body: some View {
        let isClippedPreview = isCollapsible && !(isInlineExpanded && !isStreaming && totalLines <= 120)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Text(language.lowercased())
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(isStreaming && isClippedPreview ? "实时跟随 · \(totalLines) 行" : "\(totalLines) 行")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(isStreaming ? theme.accent : theme.mutedText)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(isStreaming ? theme.accent.opacity(0.12) : theme.cardBackground.opacity(0.7))
                        .clipShape(Capsule())
                        .layoutPriority(1)
                }

                Spacer(minLength: 4)

                HStack(spacing: 8) {
                    if isCollapsible {
                        Button {
                            showingFullViewer = true
                        } label: {
                            HStack(spacing: 2.5) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text("全文")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(theme.secondaryText)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        UIPasteboard.general.string = code
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { copied = false }
                        }
                    } label: {
                        HStack(spacing: 2.5) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(copied ? "已复制" : "复制")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(copied ? theme.accent : theme.secondaryText)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .layoutPriority(2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.elevatedBackground)

            Rectangle()
                .fill(theme.border)
                .frame(height: 1)

            ZStack(alignment: .bottom) {
                ScrollView(.horizontal, showsIndicators: !isStreaming) {
                    Text(displayedCode)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineSpacing(3)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isClippedPreview && !isStreaming {
                    LinearGradient(
                        stops: [
                            .init(color: theme.cardBackground.opacity(0), location: 0),
                            .init(color: theme.cardBackground.opacity(0.92), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 22)
                    .allowsHitTesting(false)
                }
            }

            if isCollapsible {
                Rectangle()
                    .fill(theme.border)
                    .frame(height: 1)

                Button {
                    if !isStreaming && totalLines <= 120 {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isInlineExpanded.toggle()
                        }
                    } else {
                        showingFullViewer = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: (!isStreaming && totalLines <= 120)
                              ? (isInlineExpanded ? "chevron.up" : "chevron.down")
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text((!isStreaming && totalLines <= 120)
                             ? (isInlineExpanded ? "收起代码" : "展开全部 \(totalLines.formatted()) 行代码")
                             : "查看全部 \(totalLines.formatted()) 行完整代码")
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundColor(theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7.5)
                    .background(theme.elevatedBackground.opacity(0.65))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: cardWidth)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
        .sheet(isPresented: $showingFullViewer) {
            AttachmentFilePreviewSheet(
                attachment: ChatAttachment(
                    kind: .file,
                    fileName: "code.\(language.isEmpty ? "txt" : language.lowercased())",
                    mimeType: "text/plain",
                    fileSize: code.utf8.count,
                    textContent: code
                ),
                theme: theme
            )
        }
    }
}
