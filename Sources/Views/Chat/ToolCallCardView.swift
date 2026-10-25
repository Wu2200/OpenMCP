import SwiftUI
import UIKit

struct ToolCallSummaryGroupView: View {
    @EnvironmentObject var storage: DataStorage
    let toolCalls: [ToolCallItem]
    @State private var isGroupExpanded: Bool = false

    private var theme: AppThemePalette {
        storage.settings.currentTheme
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

    private var summaryStatusColor: Color {
        guard let latest = latestCall else { return .green }
        if latest.isExecuting { return theme.accent }
        if latest.error != nil { return .orange }
        return .green
    }

    private var summaryStatusIcon: String {
        guard let latest = latestCall else { return "checkmark.circle.fill" }
        if latest.error != nil { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var summaryHeadline: String {
        guard let latest = latestCall else { return "工具调用" }
        if latest.isExecuting {
            return "正在调用: \(latest.name)"
        }
        if latest.error != nil {
            return "调用异常: \(latest.name)"
        }
        if toolCalls.count == 1 {
            return "已调用工具: \(latest.name)"
        }
        return "最新完成: \(latest.name)"
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
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isGroupExpanded.toggle()
                }
            }) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(summaryStatusColor.opacity(0.15))
                            .frame(width: 28, height: 28)

                        if latestCall?.isExecuting == true {
                            ProgressView()
                                .scaleEffect(0.68)
                                .tint(theme.accent)
                        } else {
                            Image(systemName: summaryStatusIcon)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(summaryStatusColor)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(summaryHeadline)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        Text(summarySubtext)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text("\(completedCount)/\(toolCalls.count)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(summaryStatusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(summaryStatusColor.opacity(0.12))
                        .clipShape(Capsule())

                    Image(systemName: isGroupExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.mutedText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isGroupExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                        .overlay(theme.border)

                    ForEach(Array(toolCalls.enumerated()), id: \.element.id) { index, tc in
                        ToolCallCardView(toolCall: tc, stepNumber: index + 1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(theme.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }
}

struct ToolCallCardView: View {
    @EnvironmentObject var storage: DataStorage
    let toolCall: ToolCallItem
    var stepNumber: Int? = nil
    @State private var isExpanded: Bool = false
    @State private var isCopied: Bool = false

    private var theme: AppThemePalette {
        storage.settings.currentTheme
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    if let step = stepNumber {
                        Text("#\(step)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(statusColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(statusColor.opacity(0.14))
                            .clipShape(Capsule())
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(toolCall.name)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        Text(statusLabel)
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                    }

                    Spacer()

                    Text(isExpanded ? "收起参数" : "展开参数")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.mutedText)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.mutedText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                        .overlay(theme.border)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("调用参数 (Arguments)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.secondaryText)

                        Text(toolCall.arguments)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    if let res = toolCall.result {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("执行结果 (Output)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(theme.secondaryText)
                                Spacer()
                                Button(action: {
                                    UIPasteboard.general.string = res
                                    withAnimation { isCopied = true }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        withAnimation { isCopied = false }
                                    }
                                }) {
                                    Text(isCopied ? "已复制" : "复制结果")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(theme.accent)
                                }
                            }

                            Text(res)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(12)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.cardBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    private var statusColor: Color {
        if toolCall.isExecuting { return theme.accent }
        if toolCall.error != nil { return .orange }
        return .green
    }

    private var statusLabel: String {
        if toolCall.isExecuting { return "正在执行 MCP 工具调用..." }
        if let err = toolCall.error { return "执行异常: \(err)" }
        return "调用成功"
    }
}
