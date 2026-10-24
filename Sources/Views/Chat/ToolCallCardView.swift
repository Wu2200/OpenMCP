import SwiftUI

struct ToolCallCardView: View {
    let toolCall: ToolCallItem
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    if toolCall.isExecuting {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else if toolCall.error != nil {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }

                    Text("工具: \(toolCall.name)")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.primary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("参数:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(toolCall.arguments)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(6)
                        .background(Color(.systemBackground))
                        .cornerRadius(6)

                    if let res = toolCall.result {
                        Text("结果:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        ScrollView {
                            Text(res)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                        .padding(6)
                        .background(Color(.systemBackground))
                        .cornerRadius(6)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(.tertiarySystemFill))
        .cornerRadius(8)
    }
}
