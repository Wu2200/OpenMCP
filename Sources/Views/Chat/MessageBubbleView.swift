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

struct MessageBubbleView: View {
    @EnvironmentObject var storage: DataStorage
    let message: ChatMessage
    var modelName: String = "Assistant"
    @State private var isCopied: Bool = false

    private var theme: AppThemePalette {
        storage.settings.currentTheme
    }

    var body: some View {
        if message.role == .user {
            userPromptCard
        } else {
            assistantStudioCard
        }
    }

    private var userPromptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("提问")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(theme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(theme.accent.opacity(0.14))
                .clipShape(Capsule())

                Text(message.createdAt, style: .time)
                    .font(.system(size: 11))
                    .foregroundColor(theme.mutedText)

                Spacer()

                Button(action: copyFullContent) {
                    HStack(spacing: 3) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "已复制" : "复制")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isCopied ? theme.accent : theme.secondaryText)
                }
            }

            Text(message.content)
                .font(.system(size: 15, weight: .regular))
                .lineSpacing(4)
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                        .fill(theme.accent)
                        .frame(width: 24, height: 24)
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }

                Text(modelName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Text(message.createdAt, style: .time)
                    .font(.system(size: 11))
                    .foregroundColor(theme.mutedText)

                Spacer()

                if !message.content.isEmpty {
                    Button(action: copyFullContent) {
                        HStack(spacing: 4) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            Text(isCopied ? "已复制" : "复制")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isCopied ? theme.accent : theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.elevatedBackground)
                        .clipShape(Capsule())
                    }
                }
            }

            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                VStack(spacing: 8) {
                    ForEach(toolCalls) { call in
                        ToolCallCardView(toolCall: call)
                    }
                }
            }

            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let segments = parseSegments(from: trimmed)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(segments) { segment in
                        switch segment {
                        case .text(_, let textContent):
                            formattedTextBlock(textContent)
                        case .code(_, let lang, let codeContent):
                            CodeBlockCardView(language: lang, code: codeContent, theme: theme)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func formattedTextBlock(_ rawText: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attr = try? AttributedString(markdown: rawText, options: options) {
            Text(attr)
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(rawText)
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func parseSegments(from text: String) -> [MessageSegment] {
        var results: [MessageSegment] = []
        let lines = text.components(separatedBy: "\n")
        var inCode = false
        var currentLang = "code"
        var buffer: [String] = []
        var nextId = 0

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") {
                if inCode {
                    let codeText = buffer.joined(separator: "\n")
                    results.append(.code(id: nextId, language: currentLang, content: codeText))
                    nextId += 1
                    buffer.removeAll()
                    inCode = false
                } else {
                    if !buffer.isEmpty {
                        let normalText = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
                        if !normalText.isEmpty {
                            results.append(.text(id: nextId, content: normalText))
                            nextId += 1
                        }
                        buffer.removeAll()
                    }
                    let langTag = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    currentLang = langTag.isEmpty ? "code" : langTag
                    inCode = true
                }
            } else {
                buffer.append(line)
            }
        }

        if !buffer.isEmpty {
            let remaining = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !remaining.isEmpty {
                if inCode {
                    results.append(.code(id: nextId, language: currentLang, content: remaining))
                } else {
                    results.append(.text(id: nextId, content: remaining))
                }
            }
        }

        return results
    }

    private func copyFullContent() {
        UIPasteboard.general.string = message.content
        withAnimation {
            isCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                isCopied = false
            }
        }
    }
}

struct CodeBlockCardView: View {
    let language: String
    let code: String
    let theme: AppThemePalette
    @State private var copiedCode: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.accent)
                    Text(language.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Button(action: {
                    UIPasteboard.general.string = code
                    withAnimation { copiedCode = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copiedCode = false }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: copiedCode ? "checkmark" : "doc.on.doc")
                        Text(copiedCode ? "已复制代码" : "复制代码")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(copiedCode ? theme.accent : theme.secondaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.border.opacity(0.45))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(3)
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
