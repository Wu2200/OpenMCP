import SwiftUI
import UIKit

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
            userTurnView
        } else {
            assistantTurnView
        }
    }

    private var userTurnView: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if isEditing {
                editEditorBox(allowResend: true)
            } else {
                HStack {
                    Spacer(minLength: 42)
                    Text(turn.content)
                        .font(.system(size: 15.5, weight: .regular))
                        .foregroundColor(theme.primaryText)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(theme.userMessageBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(theme.accent.opacity(0.18), lineWidth: 1)
                        )
                }

                HStack {
                    Spacer()
                    floatingActionPill
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var assistantTurnView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !turn.toolCalls.isEmpty {
                ToolCallSummaryGroupView(toolCalls: turn.toolCalls)
            }

            if isEditing {
                editEditorBox(allowResend: false)
            } else {
                let trimmed = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    MarkdownDocumentView(content: trimmed, theme: theme)
                }

                floatingActionPill
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var floatingActionPill: some View {
        HStack(spacing: 4) {
            Button(action: {
                onRetry?()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("重试")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)

            Divider()
                .frame(height: 12)
                .overlay(theme.border)

            Button(action: {
                draftText = turn.content
                withAnimation(.easeInOut(duration: 0.15)) {
                    isEditing = true
                }
                isEditFieldFocused = true
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("编辑")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)

            if !turn.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                    .frame(height: 12)
                    .overlay(theme.border)

                Button(action: {
                    UIPasteboard.general.string = turn.content
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
                    .padding(.horizontal, 9)
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
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("删除")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(Color.red.opacity(0.8))
                .padding(.horizontal, 9)
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
        .shadow(color: Color.black.opacity(theme.isDark ? 0.22 : 0.05), radius: 6, x: 0, y: 2)
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
                Text(language.lowercased())
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
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
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(copied ? "已复制" : "复制代码")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(copied ? theme.accent : theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.elevatedBackground)

            Rectangle()
                .fill(theme.border)
                .frame(height: 1)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }
}
