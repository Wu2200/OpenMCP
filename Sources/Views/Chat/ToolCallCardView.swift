import SwiftUI
import UIKit

struct ToolCallSummaryGroupView: View, Equatable {
    let toolCalls: [ToolCallItem]
    let theme: AppThemePalette
    @State private var isGroupExpanded: Bool = false
    @State private var isShowingAllCalls: Bool = false

    static func == (lhs: ToolCallSummaryGroupView, rhs: ToolCallSummaryGroupView) -> Bool {
        lhs.toolCalls == rhs.toolCalls && lhs.theme == rhs.theme
    }

    private var latestCall: ToolCallItem? {
        if let executing = toolCalls.last(where: { $0.isExecuting }) {
            return executing
        }
        return toolCalls.last
    }

    private var completedCount: Int {
        toolCalls.filter { !$0.isExecuting }.count
    }

    private var hasAnyError: Bool {
        toolCalls.contains { $0.error != nil }
    }

    private var summaryStatusColor: Color {
        guard let latest = latestCall else { return theme.accent }
        if latest.isExecuting { return theme.accent }
        if latest.error != nil || hasAnyError { return .orange }
        return theme.accent
    }

    private var summaryStatusIcon: String {
        guard let latest = latestCall else { return "checkmark.circle.fill" }
        if latest.error != nil || hasAnyError { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    static func cleanToolDisplayName(_ rawName: String) -> String {
        let parts = rawName.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[0].count == 6,
           parts[0].allSatisfy({ $0.isHexDigit }) {
            return String(parts[1])
        }
        return rawName
    }

    private var summaryHeadline: String {
        guard let latest = latestCall else { return "工具调用" }
        let cleanName = Self.cleanToolDisplayName(latest.name)
        if latest.isExecuting {
            return "正在调用 \(cleanName)"
        }
        if latest.error != nil {
            return "调用异常 · \(cleanName)"
        }
        if toolCalls.count == 1 {
            return "已调用 \(cleanName)"
        }
        return "已完成 \(toolCalls.count) 次工具调用"
    }

    private var summarySubtext: String {
        guard let latest = latestCall else { return "" }
        if latest.isExecuting {
            return "已完成 \(completedCount)/\(toolCalls.count) · 点击查看详情"
        }
        if let err = latest.error {
            return err
        }
        if toolCalls.count > 1 {
            let names = toolCalls.map { Self.cleanToolDisplayName($0.name) }
            let preview = Array(names.suffix(3)).joined(separator: " → ")
            return preview
        }
        return "点击查看参数与返回结果"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if isGroupExpanded {
                        isShowingAllCalls = false
                    }
                    isGroupExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if latestCall?.isExecuting == true {
                        ProgressView()
                            .scaleEffect(0.68)
                            .tint(theme.accent)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: summaryStatusIcon)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(summaryStatusColor)
                            .frame(width: 16, height: 16)
                    }

                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(summaryHeadline)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        Text(summarySubtext)
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    Text("\(completedCount)/\(toolCalls.count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundColor(summaryStatusColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(summaryStatusColor.opacity(0.12))
                        .clipShape(Capsule())

                    Image(systemName: isGroupExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.mutedText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isGroupExpanded {
                Rectangle()
                    .fill(theme.border.opacity(0.75))
                    .frame(height: 1)

                let firstDisplayedIndex = isShowingAllCalls ? 0 : max(0, toolCalls.count - 5)

                VStack(alignment: .leading, spacing: 4) {
                    if !isShowingAllCalls && firstDisplayedIndex > 0 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isShowingAllCalls = true
                            }
                        } label: {
                            Label("展开更早的 \(firstDisplayedIndex) 次工具调用", systemImage: "arrow.up")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(theme.accent)
                                .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    } else if isShowingAllCalls && toolCalls.count > 5 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isShowingAllCalls = false
                            }
                        } label: {
                            Label("收起至最近 5 次工具调用", systemImage: "arrow.down")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(theme.accent)
                                .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(firstDisplayedIndex..<toolCalls.count, id: \.self) { index in
                            ToolCallCardView(toolCall: toolCalls[index], theme: theme, stepNumber: index + 1)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.elevatedBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }
}

struct ToolCallCardView: View {
    let toolCall: ToolCallItem
    let theme: AppThemePalette
    var stepNumber: Int? = nil
    @State private var isExpanded: Bool = false
    @State private var isCopied: Bool = false
    @State private var areArgumentsCopied: Bool = false
    @State private var fullPreviewAttachment: ChatAttachment? = nil

    private static let previewCharacterLimit = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    if let step = stepNumber {
                        Text("#\(step)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(statusColor)
                    }

                    Text(ToolCallSummaryGroupView.cleanToolDisplayName(toolCall.name))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Text(statusLabel)
                        .font(.system(size: 10))
                        .foregroundColor(statusLabelColor)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.mutedText)
                }
                .contentShape(Rectangle())
                .frame(minHeight: 26)
                .padding(.vertical, 1)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    payloadSection(
                        title: "调用参数",
                        rawText: toolCall.arguments,
                        fileName: "\(ToolCallSummaryGroupView.cleanToolDisplayName(toolCall.name))_args.json",
                        copiedFlag: areArgumentsCopied,
                        onCopy: {
                            UIPasteboard.general.string = toolCall.arguments
                            withAnimation { areArgumentsCopied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { areArgumentsCopied = false }
                            }
                        }
                    )

                    if let res = toolCall.result {
                        payloadSection(
                            title: "执行结果",
                            rawText: res,
                            fileName: "\(ToolCallSummaryGroupView.cleanToolDisplayName(toolCall.name))_result.txt",
                            copiedFlag: isCopied,
                            onCopy: {
                                UIPasteboard.general.string = res
                                withAnimation { isCopied = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation { isCopied = false }
                                }
                            }
                        )
                    }
                }
                .padding(.leading, stepNumber == nil ? 0 : 12)
                .padding(.bottom, 4)
            }
        }
        .sheet(item: $fullPreviewAttachment) { att in
            AttachmentFilePreviewSheet(attachment: att, theme: theme)
        }
    }

    @ViewBuilder
    private func payloadSection(
        title: String,
        rawText: String,
        fileName: String,
        copiedFlag: Bool,
        onCopy: @escaping () -> Void
    ) -> some View {
        let isLong = rawText.count > Self.previewCharacterLimit

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.secondaryText)

                Spacer()

                if isLong {
                    Button {
                        fullPreviewAttachment = ChatAttachment(
                            kind: .file,
                            fileName: fileName,
                            mimeType: "text/plain",
                            fileSize: rawText.utf8.count,
                            textContent: rawText
                        )
                    } label: {
                        Text("全文 (\(rawText.count)字)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.accent)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onCopy) {
                    Text(copiedFlag ? "已复制" : "复制")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.accent)
                }
                .buttonStyle(.plain)
            }

            // 直接内联渲染截断预览文本，避免嵌套纵向 ScrollView 抢夺外层列表滚动手势
            Text(Self.preview(rawText))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .lineLimit(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
                .background(theme.cardBackground.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(theme.border.opacity(0.75), lineWidth: 1)
                )
        }
    }

    private static func preview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = trimmed.index(trimmed.startIndex, offsetBy: previewCharacterLimit, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
        guard end < trimmed.endIndex else { return trimmed }
        return String(trimmed[..<end]) + "…"
    }

    private var statusColor: Color {
        if toolCall.isExecuting { return theme.accent }
        if toolCall.error != nil { return .orange }
        return theme.accent
    }

    private var statusLabelColor: Color {
        if toolCall.error != nil { return .orange }
        return theme.secondaryText
    }

    private var statusLabel: String {
        if toolCall.isExecuting { return "执行中..." }
        if let err = toolCall.error { return "异常: \(err)" }
        return "完成"
    }
}
