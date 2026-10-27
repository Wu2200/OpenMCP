import SwiftUI
import UIKit

struct MessageDisplayTurn: Identifiable, Equatable {
    var id: String
    var role: MessageRole
    var primaryMessageId: String
    var content: String
    var reasoningContent: String
    var attachments: [ChatAttachment]
    var toolCalls: [ToolCallItem]
    var createdAt: Date
    var underlyingMessageIds: [String]
}

struct ReasoningFoldCardView: View {
    let reasoningText: String
    let isStreamingReasoning: Bool
    let isScrollInteracting: Bool
    let startDate: Date
    let theme: AppThemePalette
    var width: CGFloat
    @State private var isExpanded: Bool = false

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(theme.accent)

                if isStreamingReasoning {
                    if isScrollInteracting {
                        let elapsed = max(0, Date().timeIntervalSince(startDate))
                        HStack(spacing: 5) {
                            Text("深度思考中")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            Text(ThinkingStatusView.formatElapsed(elapsed))
                                .font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundColor(theme.secondaryText)
                        }
                    } else {
                        TimelineView(.periodic(from: .now, by: 0.1)) { context in
                            let elapsed = max(0, context.date.timeIntervalSince(startDate))
                            HStack(spacing: 5) {
                                Text("深度思考中")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(theme.primaryText)
                                Text(ThinkingStatusView.formatElapsed(elapsed))
                                    .font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit())
                                    .foregroundColor(theme.secondaryText)
                            }
                        }
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
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                Rectangle()
                    .fill(theme.border.opacity(0.75))
                    .frame(height: 1)

                let displayReasoning = reasoningText.count > 12000
                    ? "...(仅显示末尾思考内容)\n" + String(reasoningText.suffix(12000))
                    : reasoningText
                let maxWindowHeight = min(250, max(150, UIScreen.main.bounds.height * 0.3))

                ScrollView(.vertical, showsIndicators: true) {
                    reasoningBodyText(displayReasoning)
                }
                .frame(height: maxWindowHeight)
            }
        }
        .frame(width: width, alignment: .leading)
        .background(theme.elevatedBackground.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func reasoningBodyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundColor(theme.secondaryText)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }
}

struct MessageBubbleView: View {
    let turn: MessageDisplayTurn
    let theme: AppThemePalette
    var availableWidth: CGFloat = UIScreen.main.bounds.width - 20
    var modelName: String = "Assistant"
    var isGenerating: Bool = false
    var isActiveGeneratingTurn: Bool = false
    var statusText: String = ""
    var thinkingStartTime: Date? = nil
    @ObservedObject var streamingState: StreamingTurnState
    var isSelected: Bool = false
    var onSelectToggle: (() -> Void)? = nil
    var onEditBegin: (() -> Void)? = nil
    var onDismissSelection: (() -> Void)? = nil
    var onEditSave: ((String) -> Void)? = nil
    var onEditAndResend: ((String) -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

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
        if !turn.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

    private var effectiveAssistantText: String {
        let base = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActiveGeneratingTurn else {
            return base
        }
        let live = streamingState.displayedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty {
            if base.isEmpty || (turn.underlyingMessageIds.contains(streamingState.activeMessageId ?? "") && base == live) {
                return live
            }
            if !base.isEmpty && live != base && !base.hasSuffix(live) {
                return base + "\n\n" + live
            }
            return live
        }
        return base
    }

    private var effectiveReasoningText: String {
        let base = turn.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActiveGeneratingTurn else {
            return base
        }
        let live = streamingState.displayedReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty {
            if base.isEmpty || base == live {
                return live
            }
            if !base.hasSuffix(live) {
                return base + "\n\n" + live
            }
            return live
        }
        return base
    }

    private var assistantTurnView: some View {
        let currentText = effectiveAssistantText
        let currentReasoning = effectiveReasoningText
        let isPureThinking = isActiveGeneratingTurn && currentText.isEmpty && currentReasoning.isEmpty && turn.toolCalls.isEmpty
        let innerContentWidth = max(180, bubbleColumnWidth - 24)
        let scrollInteracting = streamingState.isScrollInteracting

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
                    if isPureThinking {
                        HStack(spacing: 0) {
                            ThinkingStatusView(
                                statusText: statusText,
                                startDate: thinkingStartTime ?? turn.createdAt,
                                theme: theme,
                                isPaused: scrollInteracting
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
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            if !turn.toolCalls.isEmpty {
                                ToolCallSummaryGroupView(toolCalls: turn.toolCalls, theme: theme)
                                    .frame(width: innerContentWidth)
                                    .modifier(ChatLayoutProbe(identifier: "toolSummary|\(turn.id)"))
                            }

                            if !currentReasoning.isEmpty {
                                ReasoningFoldCardView(
                                    reasoningText: currentReasoning,
                                    isStreamingReasoning: isActiveGeneratingTurn && currentText.isEmpty,
                                    isScrollInteracting: scrollInteracting,
                                    startDate: thinkingStartTime ?? turn.createdAt,
                                    theme: theme,
                                    width: innerContentWidth
                                )
                                .modifier(ChatLayoutProbe(identifier: "reasoning|\(turn.id)"))
                            }

                            if !currentText.isEmpty {
                                MarkdownDocumentView(
                                    content: currentText,
                                    theme: theme,
                                    contentWidth: innerContentWidth,
                                    isStreaming: isActiveGeneratingTurn,
                                    diagnosticIDPrefix: turn.id
                                )
                                .frame(width: innerContentWidth, alignment: .leading)
                                .modifier(ChatLayoutProbe(identifier: "markdown|\(turn.id)"))
                            } else if isActiveGeneratingTurn && currentReasoning.isEmpty {
                                ThinkingStatusView(
                                    statusText: statusText,
                                    startDate: thinkingStartTime ?? turn.createdAt,
                                    theme: theme,
                                    isPaused: scrollInteracting
                                )
                                .padding(.top, 2)
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

                    if isSelected {
                        floatingActionPill
                    }
                }
            }
            .frame(width: bubbleColumnWidth, alignment: .leading)
            .modifier(ChatLayoutProbe(identifier: "assistantColumn|\(turn.id)"))
        }
        .modifier(ChatLayoutProbe(identifier: "assistantRowContent|\(turn.id)"))
        .frame(width: availableWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ChatLayoutProbe(identifier: "assistantRow|\(turn.id)"))
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

    private var floatingActionPill: some View {
        let copyTarget = editableRawText

        return HStack(spacing: 4) {
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
            .onTapGesture {
                guard !isGenerating else { return }
                onRetry?()
            }

            Divider()
                .frame(height: 12)
                .overlay(theme.border)

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
            .onTapGesture {
                guard !isGenerating else { return }
                draftText = editableRawText
                withAnimation(.easeInOut(duration: 0.15)) {
                    isEditing = true
                }
                onEditBegin?()
                isEditFieldFocused = true
            }

            if !copyTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                    .frame(height: 12)
                    .overlay(theme.border)

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
                .onTapGesture {
                    UIPasteboard.general.string = copyTarget
                    withAnimation { isCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { isCopied = false }
                    }
                }
            }

            Divider()
                .frame(height: 12)
                .overlay(theme.border)

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
            .onTapGesture {
                guard !isGenerating else { return }
                onDelete?()
            }
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
                Text("取消")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.cardBackground)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(theme.border, lineWidth: 1))
                    .contentShape(Capsule())
                    .onTapGesture {
                        isEditFieldFocused = false
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isEditing = false
                        }
                    }

                Spacer()

                Text("仅保存")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.accent.opacity(0.14))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                    .onTapGesture {
                        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        isEditFieldFocused = false
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isEditing = false
                        }
                        onEditSave?(trimmed)
                    }

                if allowResend {
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
                    .contentShape(Capsule())
                    .onTapGesture {
                        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        isEditFieldFocused = false
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isEditing = false
                        }
                        onEditAndResend?(trimmed)
                    }
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
    @State private var showingFullViewer: Bool = false

    private let previewLineThreshold = 8

    private var totalLines: Int {
        var count = 1
        for byte in code.utf8 where byte == 0x0A {
            count += 1
        }
        return count
    }

    private var isCollapsible: Bool {
        totalLines > previewLineThreshold || code.count > 360
    }

    private var displayedCode: String {
        if !isCollapsible {
            return code
        }
        if isStreaming {
            return Self.extractLastLinesStable(from: code, exactLines: previewLineThreshold, maxChars: 1400)
        }
        return Self.extractFirstLines(from: code, maxLines: previewLineThreshold, maxChars: 1400)
    }

    private static func extractFirstLines(from text: String, maxLines: Int, maxChars: Int) -> String {
        guard !text.isEmpty, maxLines > 0 else { return "" }
        var idx = text.startIndex
        let end = text.endIndex
        var lines = 1
        var chars = 0

        while idx < end {
            if text[idx] == "\n" {
                if lines >= maxLines {
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
            let safeLine = line.isEmpty ? " " : (line.count > 160 ? String(line.prefix(160)) : line)
            return safeLine
        }
        if cleaned.count < exactLines {
            let pad = Array(repeating: " ", count: exactLines - cleaned.count)
            return (pad + cleaned).joined(separator: "\n")
        }
        return cleaned.joined(separator: "\n")
    }

    var body: some View {
        let isStreamingCollapsedWindow = isStreaming && isCollapsible

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Text(language.lowercased())
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(isStreamingCollapsedWindow ? "实时跟随 · \(totalLines) 行" : "\(totalLines) 行")
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

                HStack(spacing: 4) {
                    if isCollapsible {
                        HStack(spacing: 2.5) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("全文")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showingFullViewer = true
                        }
                    }

                    HStack(spacing: 2.5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(copied ? theme.accent : theme.secondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIPasteboard.general.string = code
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { copied = false }
                        }
                    }
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
                if isStreaming {
                    Text(displayedCode)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineSpacing(3)
                        .lineLimit(isStreamingCollapsedWindow ? previewLineThreshold : nil)
                        .truncationMode(.tail)
                        .padding(10)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: isStreamingCollapsedWindow ? 164 : nil,
                            maxHeight: isStreamingCollapsedWindow ? 164 : nil,
                            alignment: .topLeading
                        )
                        .clipped()
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(displayedCode)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .lineSpacing(3)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isCollapsible && !isStreaming {
                    LinearGradient(
                        stops: [
                            .init(color: theme.cardBackground.opacity(0), location: 0),
                            .init(color: theme.cardBackground.opacity(0.92), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 24)
                    .allowsHitTesting(false)
                }
            }

            if isCollapsible {
                Rectangle()
                    .fill(theme.border)
                    .frame(height: 1)

                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("查看全部 \(totalLines.formatted()) 行完整代码")
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundColor(theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(theme.elevatedBackground.opacity(0.65))
                .contentShape(Rectangle())
                .onTapGesture {
                    showingFullViewer = true
                }
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
