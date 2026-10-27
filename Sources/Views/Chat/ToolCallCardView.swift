import SwiftUI
import UIKit

struct ToolCallSummaryGroupView: View {
    let toolCalls: [ToolCallItem]
    let theme: AppThemePalette
    @State private var isGroupExpanded: Bool = false
    @State private var isShowingAllCalls: Bool = false

    private var latestCall: ToolCallItem? {
        if let executing = toolCalls.last(where: { $0.isExecuting }) {
            return executing
        }
        return toolCalls.last
    }

    private var completedCount: Int {
        toolCalls.filter { !$0.isExecuting }.count
    }

    private var summaryStatusColor: Color {
        guard let latest = latestCall else { return theme.accent }
        if latest.isExecuting { return theme.accent }
        if latest.error != nil { return .orange }
        return theme.accent
    }

    private var summaryStatusIcon: String {
        guard let latest = latestCall else { return "checkmark.circle.fill" }
        if latest.error != nil { return "exclamationmark.triangle.fill" }
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
            return "正在调用: \(cleanName)"
        }
        if latest.error != nil {
            return "调用异常: \(cleanName)"
        }
        if toolCalls.count == 1 {
            return "已调用工具: \(cleanName)"
        }
        return "最新完成: \(cleanName)"
    }

    private var summarySubtext: String {
        guard let latest = latestCall else { return "" }
        if latest.isExecuting {
            return "进度 \(completedCount)/\(toolCalls.count) · 点击展开详情"
        }
        if let err = latest.error {
            return "最新状态: \(err)"
        }
        return "最新工具执行成功 · 共调用 \(toolCalls.count) 次"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                if isGroupExpanded {
                    isShowingAllCalls = false
                }
                isGroupExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    if latestCall?.isExecuting == true {
                        ProgressView()
                            .scaleEffect(0.68)
                            .tint(theme.accent)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: summaryStatusIcon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(summaryStatusColor)
                            .frame(width: 16, height: 16)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(summaryHeadline)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        Text(summarySubtext)
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Text("\(completedCount)/\(toolCalls.count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundColor(summaryStatusColor)

                    Image(systemName: isGroupExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.mutedText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isGroupExpanded {
                let firstDisplayedIndex = isShowingAllCalls ? 0 : max(0, toolCalls.count - 4)

                VStack(alignment: .leading, spacing: 4) {
                    if isShowingAllCalls && toolCalls.count > 4 {
                        Button {
                            isShowingAllCalls = false
                        } label: {
                            Label("收起至最近 4 次工具调用", systemImage: "arrow.down")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(theme.accent)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(firstDisplayedIndex..<toolCalls.count, id: \.self) { index in
                            ToolCallCardView(toolCall: toolCalls[index], theme: theme, stepNumber: index + 1)
                        }
                    }

                    if !isShowingAllCalls && firstDisplayedIndex > 0 {
                        Button {
                            isShowingAllCalls = true
                        } label: {
                            Label("显示全部 \(toolCalls.count) 次工具调用", systemImage: "arrow.up")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(theme.accent)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }
                .padding(.leading, 7)
            }
        }
    }
}

struct ToolCallCardView: View {
    let toolCall: ToolCallItem
    let theme: AppThemePalette
    var stepNumber: Int? = nil
    @State private var isExpanded: Bool = false
    @State private var isCopied: Bool = false
    @State private var areArgumentsCopied: Bool = false

    private static let previewCharacterLimit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
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
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.mutedText)
                }
                .contentShape(Rectangle())
                .frame(minHeight: 28)
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("调用参数")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(theme.secondaryText)

                            Spacer()

                            Button {
                                UIPasteboard.general.string = toolCall.arguments
                                withAnimation { areArgumentsCopied = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation { areArgumentsCopied = false }
                                }
                            } label: {
                                Text(areArgumentsCopied ? "已复制" : "复制参数")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(theme.accent)
                            }
                            .buttonStyle(.plain)
                        }

                        ScrollView(.vertical, showsIndicators: true) {
                            Text(Self.preview(toolCall.arguments))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxHeight: 96)
                    }

                    if let res = toolCall.result {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("执行结果")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.secondaryText)

                                Spacer()

                                Button {
                                    UIPasteboard.general.string = res
                                    withAnimation { isCopied = true }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        withAnimation { isCopied = false }
                                    }
                                } label: {
                                    Text(isCopied ? "已复制" : "复制结果")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(theme.accent)
                                }
                                .buttonStyle(.plain)
                            }

                            ScrollView(.vertical, showsIndicators: true) {
                                Text(Self.preview(res))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(theme.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxHeight: 96)
                        }
                    }
                }
                .padding(.leading, stepNumber == nil ? 0 : 15)
            }
        }
    }

    private static func preview(_ text: String) -> String {
        let end = text.index(text.startIndex, offsetBy: previewCharacterLimit, limitedBy: text.endIndex) ?? text.endIndex
        guard end < text.endIndex else { return text }
        return String(text[..<end]) + "\n\n… 内容较长，仅显示前 \(previewCharacterLimit) 个字符。可复制完整内容。"
    }

    private var statusColor: Color {
        if toolCall.isExecuting { return theme.accent }
        if toolCall.error != nil { return .orange }
        return theme.accent
    }

    private var statusLabel: String {
        if toolCall.isExecuting { return "正在执行 MCP 工具调用..." }
        if let err = toolCall.error { return "执行异常: \(err)" }
        return "调用成功"
    }
}
