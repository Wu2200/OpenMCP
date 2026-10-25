import SwiftUI
import UIKit

private struct ConversationTurnLogGroup: Identifiable {
    let id: String
    let turnPrompt: String?
    let latestTimestamp: Date
    let entries: [AppLogEntry]
}

private struct ConversationLogGroupSection: Identifiable {
    let id: String
    let conversationId: String?
    let title: String
    let latestTimestamp: Date
    let entries: [AppLogEntry]
    let turnGroups: [ConversationTurnLogGroup]
    let aiRequestCount: Int
    let toolCallCount: Int
    let issueCount: Int
}

struct LogViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var logger = AppLogManager.shared
    let theme: AppThemePalette
    var filterConversationId: String? = nil

    @State private var selectedCategory: AppLogCategory = .all
    @State private var onlyCurrentConversation: Bool
    @State private var groupByConversation: Bool = true
    @State private var searchText: String = ""
    @State private var expandedConversationKeys: Set<String> = []
    @State private var expandedEntryIds: Set<String> = []
    @State private var expandedToolItemIds: Set<String> = []
    @State private var isCopiedAll: Bool = false
    @State private var copiedConversationKey: String? = nil
    @State private var didInitializeExpansion: Bool = false

    init(theme: AppThemePalette, filterConversationId: String? = nil) {
        self.theme = theme
        self.filterConversationId = filterConversationId
        self._onlyCurrentConversation = State(initialValue: filterConversationId != nil)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
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
            if selectedCategory != .all {
                switch selectedCategory {
                case .aiRequest:
                    if entry.category != .aiRequest && entry.category != .aiStop {
                        return false
                    }
                case .error:
                    if entry.category != .error && entry.level == .info {
                        return false
                    }
                default:
                    if entry.category != selectedCategory {
                        return false
                    }
                }
            }
            if !q.isEmpty {
                let convTitle = logger.resolvedConversationTitle(for: entry.conversationId, fallback: entry.conversationTitle)
                let promptText = entry.turnPrompt ?? ""
                let hay = "\(convTitle) \(promptText) \(entry.title) \(entry.summary) \(entry.details)".lowercased()
                if !hay.contains(q) {
                    return false
                }
            }
            return true
        }
    }

    private var conversationSections: [ConversationLogGroupSection] {
        var bucketOrder: [String] = []
        var buckets: [String: [AppLogEntry]] = [:]

        for entry in filteredLogs {
            let key = entry.conversationId ?? "__global__"
            if buckets[key] == nil {
                bucketOrder.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(entry)
        }

        return bucketOrder.compactMap { key in
            guard let entries = buckets[key], !entries.isEmpty else { return nil }
            let rawConvId: String? = (key == "__global__") ? nil : key
            let fallbackTitle = entries.compactMap { $0.conversationTitle }.first
            let title = logger.resolvedConversationTitle(for: rawConvId, fallback: fallbackTitle)
            let latest = entries.map { $0.timestamp }.max() ?? Date()

            let aiCount = entries.filter { $0.category == .aiRequest || $0.category == .aiStop }.count
            let toolCount = entries.filter { $0.category == .mcpTool }.reduce(0) { acc, item in
                acc + max(1, item.toolItems?.count ?? 1)
            }
            let issues = entries.filter { $0.level != .info || $0.category == .error }.count

            var turnOrder: [String] = []
            var turnMap: [String: [AppLogEntry]] = [:]
            for entry in entries {
                let tKey = entry.turnId ?? "legacy_\(entry.id)"
                if turnMap[tKey] == nil {
                    turnOrder.append(tKey)
                    turnMap[tKey] = []
                }
                turnMap[tKey]?.append(entry)
            }

            let turnGroups: [ConversationTurnLogGroup] = turnOrder.compactMap { tKey in
                guard let tEntries = turnMap[tKey], !tEntries.isEmpty else { return nil }
                let chronological = tEntries.sorted { $0.timestamp < $1.timestamp }
                let prompt = chronological.compactMap { $0.turnPrompt }.first
                let latestTime = chronological.last?.timestamp ?? Date()
                return ConversationTurnLogGroup(
                    id: tKey,
                    turnPrompt: prompt,
                    latestTimestamp: latestTime,
                    entries: chronological
                )
            }

            return ConversationLogGroupSection(
                id: key,
                conversationId: rawConvId,
                title: title,
                latestTimestamp: latest,
                entries: entries,
                turnGroups: turnGroups,
                aiRequestCount: aiCount,
                toolCallCount: toolCount,
                issueCount: issues
            )
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    filterHeaderBar

                    Rectangle()
                        .fill(theme.border)
                        .frame(height: 1)

                    if filteredLogs.isEmpty {
                        emptyStateView
                    } else if groupByConversation {
                        ScrollView {
                            VStack(spacing: 12) {
                                ForEach(conversationSections) { section in
                                    conversationSectionCard(section)
                                }
                            }
                            .padding(14)
                        }
                    } else {
                        ScrollView {
                            VStack(spacing: 10) {
                                ForEach(filteredLogs) { entry in
                                    logCard(for: entry, showConversationBadge: true)
                                }
                            }
                            .padding(14)
                        }
                    }
                }
            }
            .navigationTitle(groupByConversation ? "对话诊断日志 (\(conversationSections.count) 个对话)" : "诊断日志明细 (\(filteredLogs.count))")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                initializeDefaultExpansionIfNeeded()
            }
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
                            logger.clearLogs(forConversationId: onlyCurrentConversation ? filterConversationId : nil)
                        }) {
                            Text("清空")
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                        }
                        .disabled(filteredLogs.isEmpty)
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

    private func initializeDefaultExpansionIfNeeded() {
        guard !didInitializeExpansion else { return }
        didInitializeExpansion = true
        if let cid = filterConversationId {
            expandedConversationKeys.insert(cid)
        } else if let firstKey = conversationSections.first?.id {
            expandedConversationKeys.insert(firstKey)
        }
    }

    private var filterHeaderBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundColor(theme.mutedText)
                TextField("搜索对话标题、工具名称或 finish_reason...", text: $searchText)
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
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            groupByConversation.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: groupByConversation ? "rectangle.stack.fill" : "list.bullet")
                                .font(.system(size: 11, weight: .semibold))
                            Text(groupByConversation ? "按对话聚合" : "按时间平铺")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(theme.accent)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

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
    }

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(theme.mutedText)
            Text("暂无诊断日志记录")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text("发起对话或调用 MCP 工具后，日志会自动按对话与提问轮次聚合收纳，方便集中查看每次对话的流式状态与工具调用明细。")
                .font(.system(size: 12.5))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
    }

    private func conversationSectionCard(_ section: ConversationLogGroupSection) -> some View {
        let isExpanded = expandedConversationKeys.contains(section.id)
        let isCopied = (copiedConversationKey == section.id)

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(section.issueCount > 0 ? Color.orange.opacity(0.16) : theme.accent.opacity(0.14))
                            .frame(width: 28, height: 28)
                        Image(systemName: section.conversationId == nil ? "gearshape.2.fill" : "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(section.issueCount > 0 ? .orange : theme.accent)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title)
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        Text("最近更新 \(Self.dateTimeFormatter.string(from: section.latestTimestamp))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.mutedText)
                    }

                    Spacer()

                    Button(action: {
                        let text = logger.exportAllText(filterConversationId: section.conversationId)
                        UIPasteboard.general.string = text
                        withAnimation { copiedConversationKey = section.id }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if copiedConversationKey == section.id {
                                withAnimation { copiedConversationKey = nil }
                            }
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .semibold))
                            if isCopied {
                                Text("已复制")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                        }
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(theme.elevatedBackground)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    if let cid = section.conversationId {
                        Button(role: .destructive, action: {
                            logger.clearLogs(forConversationId: cid)
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(.red.opacity(0.85))
                                .padding(6)
                                .background(Color.red.opacity(0.1))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .padding(.leading, 2)
                }

                HStack(spacing: 6) {
                    statBadge(text: "\(section.turnGroups.count) 轮对话", color: theme.secondaryText, bg: theme.elevatedBackground)
                    if section.aiRequestCount > 0 {
                        statBadge(text: "\(section.aiRequestCount) 次请求", color: theme.secondaryText, bg: theme.elevatedBackground)
                    }
                    if section.toolCallCount > 0 {
                        statBadge(text: "\(section.toolCallCount) 次工具调用", color: theme.accent, bg: theme.accent.opacity(0.13))
                    }
                    if section.issueCount > 0 {
                        statBadge(text: "\(section.issueCount) 异常/截断", color: .orange, bg: Color.orange.opacity(0.15))
                    } else {
                        statBadge(text: "正常", color: theme.accent, bg: theme.accent.opacity(0.1))
                    }
                    Spacer()
                }
            }
            .padding(13)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if expandedConversationKeys.contains(section.id) {
                        expandedConversationKeys.remove(section.id)
                    } else {
                        expandedConversationKeys.insert(section.id)
                    }
                }
            }

            if isExpanded {
                Divider()
                    .overlay(theme.border)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(section.turnGroups.enumerated()), id: \.element.id) { idx, turnGroup in
                        turnGroupView(turnGroup, roundNumber: section.turnGroups.count - idx)
                    }
                }
                .padding(12)
                .background(theme.background.opacity(0.45))
            }
        }
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(section.issueCount > 0 ? Color.orange.opacity(0.45) : theme.border, lineWidth: 1)
        )
    }

    private func statBadge(text: String, color: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bg)
            .clipShape(Capsule())
    }

    private func turnGroupView(_ turnGroup: ConversationTurnLogGroup, roundNumber: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("第 \(roundNumber) 轮")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(theme.accent)
                    .clipShape(Capsule())

                if let prompt = turnGroup.turnPrompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                } else {
                    Text("交互执行记录")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Text(Self.timeFormatter.string(from: turnGroup.latestTimestamp))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.mutedText)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(turnGroup.entries) { entry in
                    if entry.category == .mcpTool, let items = entry.toolItems, !items.isEmpty {
                        aggregatedToolCard(entry: entry, items: items)
                    } else {
                        logCard(for: entry, showConversationBadge: false)
                    }
                }
            }
        }
        .padding(10)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    private func aggregatedToolCard(entry: AppLogEntry, items: [AppLogToolItem]) -> some View {
        let failCount = items.filter { !$0.isSuccess }.count
        let headerColor: Color = failCount > 0 ? .red : theme.accent

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(headerColor)

                Text(items.count == 1 ? "MCP 工具调用 (1 次)" : "MCP 工具调用聚合 (共 \(items.count) 次)")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(theme.primaryText)

                if failCount > 0 {
                    Text("\(failCount) 失败")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.red.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer()

                Button(action: {
                    UIPasteboard.general.string = entry.details
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let isItemExpanded = expandedToolItemIds.contains(item.id)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("#\(index + 1)")
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundColor(item.isSuccess ? theme.accent : .red)
                                .frame(width: 24, alignment: .leading)

                            Text(item.toolName)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)

                            Text(item.serverName)
                                .font(.system(size: 10.5))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(theme.cardBackground)
                                .clipShape(Capsule())

                            Spacer()

                            Text(item.elapsed)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.mutedText)

                            Image(systemName: item.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(item.isSuccess ? theme.accent : .red)

                            Image(systemName: isItemExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(theme.mutedText)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if expandedToolItemIds.contains(item.id) {
                                expandedToolItemIds.remove(item.id)
                            } else {
                                expandedToolItemIds.insert(item.id)
                            }
                        }

                        if isItemExpanded {
                            Divider()
                                .overlay(theme.border)

                            Text("参数 (Arguments):\n\(item.arguments)\n\n返回结果 (Output):\n\(item.outputPreview)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .background(theme.cardBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(theme.elevatedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(10)
        .background(theme.elevatedBackground.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(failCount > 0 ? Color.red.opacity(0.35) : theme.border, lineWidth: 1)
        )
    }

    private func levelBadgeColor(_ level: AppLogLevel) -> Color {
        switch level {
        case .info: return theme.accent
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func logCard(for entry: AppLogEntry, showConversationBadge: Bool) -> some View {
        let isExpanded = expandedEntryIds.contains(entry.id)
        let badgeColor = levelBadgeColor(entry.level)
        let convTitle = logger.resolvedConversationTitle(for: entry.conversationId, fallback: entry.conversationTitle)

        return VStack(alignment: .leading, spacing: 7) {
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

                if showConversationBadge {
                    Text(convTitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(theme.accent)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.accent.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.mutedText)

                Spacer()

                Button(action: {
                    let full = "[\(Self.timeFormatter.string(from: entry.timestamp))] [\(convTitle)] [\(entry.level.rawValue)] \(entry.title)\n\(entry.summary)\n\n\(entry.details)"
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
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(theme.primaryText)

            Text(entry.summary)
                .font(.system(size: 12))
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
        .padding(10)
        .background(theme.elevatedBackground.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(entry.level == .info ? theme.border : badgeColor.opacity(0.45), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
