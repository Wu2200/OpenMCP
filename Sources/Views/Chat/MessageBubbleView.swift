import SwiftUI
import UIKit

struct MessageDisplayTurn: Identifiable, Equatable {
    var id: String
    var role: MessageRole
    var primaryMessageId: String
    var content: String
    var attachments: [ChatAttachment]
    var toolCalls: [ToolCallItem]
    var createdAt: Date
    var underlyingMessageIds: [String]
}

struct MessageBubbleView: View {
    @EnvironmentObject var storage: DataStorage
    let turn: MessageDisplayTurn
    var modelName: String = "Assistant"
    var isGenerating: Bool = false
    var isActiveGeneratingTurn: Bool = false
    var statusText: String = ""
    var thinkingStartTime: Date? = nil
    var isSelected: Bool = false
    var onSelectToggle: (() -> Void)? = nil
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

    private var theme: AppThemePalette {
        storage.settings.currentTheme
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

        return VStack(alignment: .trailing, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Spacer(minLength: 24)

                if isEditing {
                    editEditorBox(allowResend: true)
                } else {
                    VStack(alignment: .trailing, spacing: 6) {
                        if !imageAtts.isEmpty {
                            AttachmentImageGridView(
                                attachments: imageAtts,
                                theme: theme,
                                onSelectImage: { img in
                                    previewingImageAttachment = img
                                }
                            )
                        }

                        ForEach(fileAtts) { fileAtt in
                            AttachmentFileCardView(
                                attachment: fileAtt,
                                theme: theme,
                                onTap: {
                                    previewingFileAttachment = fileAtt
                                }
                            )
                        }

                        if let packaged = autoPackagedLongText {
                            AttachmentFileCardView(
                                attachment: packaged,
                                theme: theme,
                                onTap: {
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
                                        .stroke(isSelected ? theme.accent.opacity(0.45) : theme.accent.opacity(0.18), lineWidth: 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                .onTapGesture {
                                    onSelectToggle?()
                                }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelectToggle?()
                    }
                }

                compactAvatar(isUser: true)
                    .onTapGesture {
                        onSelectToggle?()
                    }
            }

            if isSelected && !isEditing {
                floatingActionPill
                    .padding(.trailing, 30)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
            }
        }
    }

    private var assistantTurnView: some View {
        let trimmed = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPureThinking = isActiveGeneratingTurn && trimmed.isEmpty && turn.toolCalls.isEmpty

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                compactAvatar(isUser: false)
                    .onTapGesture {
                        onSelectToggle?()
                    }

                if isEditing {
                    editEditorBox(allowResend: false)
                } else if isPureThinking {
                    ThinkingStatusView(
                        statusText: statusText,
                        startDate: thinkingStartTime ?? turn.createdAt,
                        theme: theme
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

                    Spacer(minLength: 36)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if !turn.toolCalls.isEmpty {
                            ToolCallSummaryGroupView(toolCalls: turn.toolCalls)
                        }

                        if !trimmed.isEmpty {
                            MarkdownDocumentView(content: trimmed, theme: theme)
                        } else if isActiveGeneratingTurn {
                            ThinkingStatusView(
                                statusText: statusText,
                                startDate: thinkingStartTime ?? turn.createdAt,
                                theme: theme
                            )
                            .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                }
            }

            if isSelected && !isEditing {
                floatingActionPill
                    .padding(.leading, 30)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
            }
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
    }

    private var floatingActionPill: some View {
        let copyTarget = editableRawText

        return HStack(spacing: 4) {
            Button(action: {
                onRetry?()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("重试")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)

            Divider()
                .frame(height: 12)
                .overlay(theme.border)

            Button(action: {
                draftText = editableRawText
                withAnimation(.easeInOut(duration: 0.15)) {
                    isEditing = true
                }
                isEditFieldFocused = true
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                    Text("编辑")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
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

                Button(action: {
                    UIPasteboard.general.string = copyTarget
                    withAnimation { isCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { isCopied = false }
                    }
                }) {
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

            Button(action: {
                onDelete?()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                    Text("删除")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(Color.red.opacity(0.8))
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
                Button(action: {
                    isEditFieldFocused = false
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isEditing = false
                    }
                }) {
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

                Button(action: {
                    let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    isEditFieldFocused = false
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isEditing = false
                    }
                    onEditSave?(trimmed)
                }) {
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
                    Button(action: {
                        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        isEditFieldFocused = false
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isEditing = false
                        }
                        onEditAndResend?(trimmed)
                    }) {
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
        .frame(maxWidth: .infinity)
    }
}

struct CodeBlockCard: View {
    let language: String
    let code: String
    let theme: AppThemePalette
    @State private var copied: Bool = false
    @State private var isExpanded: Bool = false
    @State private var showingFullViewer: Bool = false

    private let previewLineThreshold = 8

    private var codeLines: [Substring] {
        code.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private var totalLines: Int {
        max(1, codeLines.count)
    }

    private var isCollapsible: Bool {
        totalLines > previewLineThreshold || code.count > 360
    }

    private var displayedCode: String {
        if !isCollapsible || isExpanded {
            return code
        }
        return codeLines.prefix(previewLineThreshold).joined(separator: "\n")
    }

    private var hiddenLineCount: Int {
        max(1, totalLines - previewLineThreshold)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text(language.lowercased())
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.secondaryText)

                    Text("\(totalLines) 行")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.mutedText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(theme.cardBackground.opacity(0.7))
                        .clipShape(Capsule())
                }

                Spacer()

                if isCollapsible {
                    Button(action: {
                        showingFullViewer = true
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("查看全文")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded.toggle()
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: isExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(isExpanded ? "收起" : "展开")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.accent)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    UIPasteboard.general.string = code
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copied = false }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(copied ? theme.accent : theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(theme.elevatedBackground)

            Rectangle()
                .fill(theme.border)
                .frame(height: 1)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(displayedCode)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(10)
            }

            if isCollapsible {
                Rectangle()
                    .fill(theme.border.opacity(0.75))
                    .frame(height: 1)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10.5, weight: .bold))
                        Text(isExpanded ? "收起代码" : "展开剩余 \(hiddenLineCount) 行代码")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundColor(theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(theme.elevatedBackground.opacity(0.6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
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
