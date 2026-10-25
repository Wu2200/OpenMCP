import SwiftUI
import UIKit

enum MessageSegment: Identifiable {
    case text(id: Int, content: String)
    case code(id: Int, language: String, content: String)

    var id: Int {
        switch self {
        case .text(let id, _): return id
        case .code(let id, _, _): return id
        }
    }
}

struct MessageDisplayTurn: Identifiable, Equatable {
    var id: String
    var role: MessageRole
    var primaryMessageId: String
    var content: String
    var toolCalls: [ToolCallItem]
    var createdAt: Date
    var underlyingMessageIds: [String]
}

struct MessageBubbleView: View {
    @EnvironmentObject var storage: DataStorage
    let turn: MessageDisplayTurn
    var modelName: String = "Assistant"
    var isGenerating: Bool = false
    var onEditSave: ((String) -> Void)? = nil
    var onEditAndResend: ((String) -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isCopied: Bool = false
    @State private var isEditing: Bool = false
    @State private var draftText: String = ""
    @FocusState private var isEditFieldFocused: Bool

    private var theme: AppThemePalette {
        storage.settings.currentTheme
    }

    var body: some View {
        if turn.role == .user {
            userPromptCard
        } else {
            assistantStudioCard
        }
    }

    private var userPromptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("我的提问")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(theme.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(theme.accent.opacity(0.14))
                .clipShape(Capsule())

                Spacer()

                Text(turn.createdAt, format: .dateTime.hour().minute())
                    .font(.system(size: 11))
                    .foregroundColor(theme.mutedText)
            }

            if isEditing {
                editEditorBox(allowResend: true)
            } else {
                Text(turn.content)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                actionButtonsBar
            }
        }
        .padding(14)
        .background(theme.userMessageBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.accent.opacity(0.22), lineWidth: 1)
        )
    }

    private var assistantStudioCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accent.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(theme.accent)
                }

                Text(modelName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Text(turn.createdAt, format: .dateTime.hour().minute())
                    .font(.system(size: 11))
                    .foregroundColor(theme.mutedText)

                Spacer()
            }

            if !turn.toolCalls.isEmpty {
                ToolCallSummaryGroupView(toolCalls: turn.toolCalls)
            }

            if isEditing {
                editEditorBox(allowResend: false)
            } else {
                let trimmed = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let segments = parseSegments(from: trimmed)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(segments) { seg in
                            switch seg {
                            case .text(_, let textContent):
                                formattedMarkdownText(textContent)
                            case .code(_, let lang, let codeContent):
                                CodeBlockCard(language: lang, code: codeContent, theme: theme)
                            }
                        }
                    }
                }

                actionButtonsBar
            }
        }
        .padding(15)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    private var actionButtonsBar: some View {
        HStack(spacing: 8) {
            Button(action: {
                draftText = turn.content
                withAnimation(.easeInOut(duration: 0.15)) {
                    isEditing = true
                }
                isEditFieldFocused = true
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                    Text("编辑")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.elevatedBackground)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)

            Button(action: {
                onRetry?()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("重试")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.accent.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)

            Button(action: {
                onDelete?()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                    Text("删除")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.red.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.red.opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)

            Spacer()

            if !turn.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: {
                    UIPasteboard.general.string = turn.content
                    withAnimation { isCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { isCopied = false }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(isCopied ? "已复制" : "复制")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(isCopied ? theme.accent : theme.secondaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(theme.elevatedBackground)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    private func editEditorBox(allowResend: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("修改消息内容...", text: $draftText, axis: .vertical)
                .lineLimit(2...10)
                .focused($isEditFieldFocused)
                .font(.system(size: 14.5))
                .foregroundColor(theme.primaryText)
                .padding(10)
                .background(theme.elevatedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.accent.opacity(0.4), lineWidth: 1)
                )

            HStack(spacing: 8) {
                Button(action: {
                    isEditFieldFocused = false
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isEditing = false
                    }
                }) {
                    Text("取消")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(theme.elevatedBackground)
                        .clipShape(Capsule())
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
                        .font(.system(size: 12, weight: .semibold))
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
                                .font(.system(size: 10))
                            Text("保存并重发")
                                .font(.system(size: 12, weight: .semibold))
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
    }

    @ViewBuilder
    private func formattedMarkdownText(_ rawText: String) -> some View {
        if let attr = try? AttributedString(
            markdown: rawText,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr)
                .font(.system(size: 15))
                .foregroundColor(theme.primaryText)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(rawText)
                .font(.system(size: 15))
                .foregroundColor(theme.primaryText)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func parseSegments(from text: String) -> [MessageSegment] {
        var result: [MessageSegment] = []
        let components = text.components(separatedBy: "```")
        for (idx, part) in components.enumerated() {
            if idx % 2 == 0 {
                let cleaned = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    result.append(.text(id: idx, content: cleaned))
                }
            } else {
                var lines = part.components(separatedBy: .newlines)
                var lang = "code"
                if let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty {
                    lang = first
                    lines.removeFirst()
                } else if !lines.isEmpty {
                    lines.removeFirst()
                }
                let codeBody = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                result.append(.code(id: idx, language: lang, content: codeBody))
            }
        }
        return result
    }
}

struct CodeBlockCard: View {
    let language: String
    let code: String
    let theme: AppThemePalette
    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                Button(action: {
                    UIPasteboard.general.string = code
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copied = false }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(copied ? "已复制代码" : "复制代码")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(copied ? theme.accent : theme.secondaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.border.opacity(0.45))

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(theme.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }
}
