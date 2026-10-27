import SwiftUI
import UIKit

enum ChatLayoutCoordinateSpace {
    static let name = "OpenMCP.ChatLayout"
}

private struct ChatLayoutDiagnosticsEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chatLayoutDiagnosticsEnabled: Bool {
        get { self[ChatLayoutDiagnosticsEnabledKey.self] }
        set { self[ChatLayoutDiagnosticsEnabledKey.self] = newValue }
    }
}

struct ChatLayoutFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct ChatLayoutProbe: ViewModifier {
    let identifier: String?
    @Environment(\.chatLayoutDiagnosticsEnabled) private var diagnosticsEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if diagnosticsEnabled, let identifier = identifier {
            content.background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ChatLayoutFramesPreferenceKey.self,
                        value: [identifier: geometry.frame(in: .named(ChatLayoutCoordinateSpace.name))]
                    )
                }
            }
        } else {
            content
        }
    }
}

struct ChatLayoutInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: String
    let theme: AppThemePalette
    @State private var isCopied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("报告包含消息区域的位置、尺寸和间距，不包含消息正文或密钥。请复制后粘贴给我。")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    Text(report)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.border, lineWidth: 1)
                )

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = report
                        isCopied = true
                    } label: {
                        Label(isCopied ? "已复制" : "复制报告", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)

                    ShareLink(item: report) {
                        Label("发送报告", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(theme.accent)
                }
            }
            .padding(16)
            .background(theme.background)
            .navigationTitle("对话布局检查器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
