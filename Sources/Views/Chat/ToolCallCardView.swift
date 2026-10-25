import SwiftUI
import UIKit

struct ToolCallCardView: View {
    @EnvironmentObject var storage: DataStorage
    let toolCall: ToolCallItem
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
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.15))
                            .frame(width: 26, height: 26)
                        if toolCall.isExecuting {
                            ProgressView()
                                .scaleEffect(0.65)
                                .tint(theme.accent)
                        } else {
                            Image(systemName: statusIcon)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(statusColor)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(toolCall.name)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        Text(statusLabel)
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                    }

                    Spacer()

                    Text(isExpanded ? "收起详情" : "查看参数")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.mutedText)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.mutedText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                        .overlay(theme.border)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("调用参数 (Arguments)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.secondaryText)

                        Text(toolCall.arguments)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    if let res = toolCall.result {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("执行结果 (Output)")
                                    .font(.system(size: 11, weight: .semibold))
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
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(theme.accent)
                                }
                            }

                            Text(res)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(14)
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.cardBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(theme.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    private var statusColor: Color {
        if toolCall.isExecuting { return theme.accent }
        if toolCall.error != nil { return .orange }
        return .green
    }

    private var statusIcon: String {
        if toolCall.error != nil { return "exclamationmark.triangle.fill" }
        return "checkmark"
    }

    private var statusLabel: String {
        if toolCall.isExecuting { return "正在执行 MCP 工具调用..." }
        if let err = toolCall.error { return "执行异常: \(err)" }
        return "已完成工具调用"
    }
}
