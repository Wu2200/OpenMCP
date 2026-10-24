import SwiftUI
import UIKit

struct MessageBubbleView: View {
    let message: ChatMessage
    @State private var isCopied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 48)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(message.content)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        Button(action: copyContent) {
                            HStack(spacing: 3) {
                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                Text(isCopied ? "已复制" : "复制")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.trailing, 4)
                        }
                    }
                }
                .padding(.horizontal, 16)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(LinearGradient(colors: [Color.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 20, height: 20)
                            .overlay(
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white)
                            )

                        Text("助手")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)

                        Spacer()

                        Button(action: copyContent) {
                            HStack(spacing: 3) {
                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                Text(isCopied ? "已复制" : "复制")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        }
                    }

                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(.system(size: 15))
                            .lineSpacing(4)
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }

                    if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(toolCalls) { call in
                                ToolCallCardView(toolCall: call)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private func copyContent() {
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
