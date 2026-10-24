import SwiftUI

struct ToolCallCardView: View {
    let toolCall: ToolCallItem
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    if toolCall.isExecuting {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else if toolCall.error != nil {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.orange)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }

                    Text("工具: \(toolCall.name)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("输入参数:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(toolCall.arguments)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(6)

                    if let res = toolCall.result {
                        Text("返回结果:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                        Text(res)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(12)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.tertiarySystemBackground))
                            .cornerRadius(6)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }
}
