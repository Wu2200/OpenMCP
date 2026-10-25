import SwiftUI
import UIKit

struct LogViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var logger = AppLogManager.shared
    let theme: AppThemePalette
    var filterConversationId: String? = nil

    @State private var selectedCategory: AppLogCategory = .all
    @State private var onlyCurrentConversation: Bool = false
    @State private var searchText: String = ""
    @State private var expandedEntryIds: Set<String> = []
    @State private var isCopiedAll: Bool = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var filteredLogs: [AppLogEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return logger.logs.filter { entry in
            if onlyCurrentConversation, let cid = filterConversationId {
                if entry.conversationId != cid {
                    return false
                }
            }
            if selectedCategory != .all && entry.category != selectedCategory {
                return false
            }
            if !q.isEmpty {
                let hay = "\(entry.title) \(entry.summary) \(entry.details)".lowercased()
                if !hay.contains(q) {
                    return false
                }
            }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13))
                                .foregroundColor(theme.mutedText)
                            TextField("搜索日志关键词（如 finish_reason、length、HTTP）...", text: $searchText)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .font(.system(size: 13.5))
                                .foregroundColor(theme.primaryText)
                            if !searchText.isEmpty {
                                Button(action: { searchText = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(theme.mutedText)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(theme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.border, lineWidth: 1))

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                if filterConversationId != nil {
                                    Button(action: {
                                        onlyCurrentConversation.toggle()
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: onlyCurrentConversation ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 11))
                                            Text("仅当前对话")
                                                .font(.system(size: 12, weight: .semibold))
                                        }
                                        .foregroundColor(onlyCurrentConversation ? .white : theme.primaryText)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(onlyCurrentConversation ? theme.accent : theme.cardBackground)
                                        .clipShape(Capsule())
                                        .overlay(Capsule().stroke(theme.border, lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                }

                                ForEach(AppLogCategory.allCases, id: \.rawValue) { cat in
                                    let isSel = (selectedCategory == cat)
                                    Button(action: {
                                        selectedCategory = cat
                                    }) {
                                        Text(cat.rawValue)
                                            .font(.system(size: 12, weight: isSel ? .semibold : .regular))
                                            .foregroundColor(isSel ? .white : theme.primaryText)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(isSel ? theme.accent : theme.cardBackground)
                                            .clipShape(Capsule())
                                            .overlay(Capsule().stroke(theme.border, lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(theme.elevatedBackground)

                    Rectangle()
                        .fill(theme.border)
                        .frame(height: 1)

                    if filteredLogs.isEmpty {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "doc.text.Below.ecg")
                                .font(.system(size: 32))
                                .foregroundColor(theme.mutedText)
                            Text("暂无诊断日志记录")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            Text("发起对话或调用工具后，这里会详细记录请求参数、SSE 流式帧统计、finish_reason 结束原因以及是否收到完整 [DONE] 标记，方便排查是上游模型截断还是网络中断。")
                                .font(.system(size: 12.5))
                                .foregroundColor(theme.secondaryText)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)
                        }
                        Spacer()
                    } else {
                        ScrollView {
                            VStack(spacing: 10) {
                                ForEach(filteredLogs) { entry in
                                    logCard(for: entry)
                                }
                            }
                            .padding(14)
                        }
                    }
                }
            }
            .navigationTitle("运行与流式诊断日志 (\(filteredLogs.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 10) {
                        Button(action: {
                            let text = logger.exportAllText(filterConversationId: onlyCurrentConversation ? filterConversationId : nil)
                            UIPasteboard.general.string = text
                            withAnimation { isCopiedAll = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { isCopiedAll = false }
                            }
                        }) {
                            Text(isCopiedAll ? "已复制" : "复制全部")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.accent)
                        }
                        .disabled(filteredLogs.isEmpty)

                        Button(role: .destructive, action: {
                            logger.clearLogs()
                        }) {
                            Text("清空")
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                        }
                        .disabled(logger.logs.isEmpty)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func levelBadgeColor(_ level: AppLogLevel) -> Color {
        switch level {
        case .info: return theme.accent
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func logCard(for entry: AppLogEntry) -> some View {
        let isExpanded = expandedEntryIds.contains(entry.id)
        let badgeColor = levelBadgeColor(entry.level)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(entry.level.rawValue)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(badgeColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.14))
                    .clipShape(Capsule())

                Text(entry.category.rawValue)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.elevatedBackground)
                    .clipShape(Capsule())

                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.mutedText)

                Spacer()

                Button(action: {
                    let full = "[\(Self.timeFormatter.string(from: entry.timestamp))] [\(entry.level.rawValue)] \(entry.title)\n\(entry.summary)\n\n\(entry.details)"
                    UIPasteboard.general.string = full
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)

                if !entry.details.isEmpty {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.mutedText)
                }
            }

            Text(entry.title)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundColor(theme.primaryText)

            Text(entry.summary)
                .font(.system(size: 12.5))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if isExpanded && !entry.details.isEmpty {
                Divider()
                    .overlay(theme.border)

                Text(entry.details)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(theme.elevatedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(12)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(entry.level == .info ? theme.border : badgeColor.opacity(0.45), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            guard !entry.details.isEmpty else { return }
            if expandedEntryIds.contains(entry.id) {
                expandedEntryIds.remove(entry.id)
            } else {
                expandedEntryIds.insert(entry.id)
            }
        }
    }
}
