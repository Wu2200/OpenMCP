import SwiftUI
import UIKit

struct ConversationListView: View {
    @EnvironmentObject var storage: DataStorage
    @State private var navigationPath: [String] = []
    @State private var searchText: String = ""
    @State private var renamingConversation: Conversation? = nil
    @State private var renameText: String = ""
    @State private var deletingConversation: Conversation? = nil
    @State private var clearingConversation: Conversation? = nil
    @ObservedObject private var activity = GenerationActivityTracker.shared
    @FocusState private var isSearchFocused: Bool

    private var theme: AppThemePalette {
        storage.settings.currentTheme
    }

    private var activeToolCount: Int {
        storage.servers.filter { $0.isEnabled }.reduce(0) { $0 + $1.tools.filter { $0.isEnabled }.count }
    }

    private var filteredConversations: [Conversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return storage.conversations }
        return storage.conversations.filter { conv in
            if conv.title.lowercased().contains(query) { return true }
            return conv.messages.contains { msg in
                if msg.content.lowercased().contains(query) { return true }
                if let atts = msg.attachments {
                    return atts.contains {
                        $0.fileName.lowercased().contains(query) || ($0.textContent?.lowercased().contains(query) == true)
                    }
                }
                return false
            }
        }
    }

    private func resolveDisplayModelName(for conv: Conversation) -> String {
        if let m = conv.selectedModelName?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            if let pid = conv.selectedProfileId,
               let profile = storage.settings.providerProfiles.first(where: { $0.id == pid }) {
                if profile.enabledModels.isEmpty || profile.enabledModels.contains(m) || profile.availableModels.contains(m) {
                    return m
                }
                if let first = profile.enabledModels.first {
                    return first
                }
            }
            return m
        }
        if let pid = conv.selectedProfileId,
           let profile = storage.settings.providerProfiles.first(where: { $0.id == pid }),
           let first = profile.enabledModels.first {
            return first
        }
        return storage.settings.modelName
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                theme.background
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isSearchFocused = false
                    }

                List {
                    studioHeroCard
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                    searchBar
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                    if filteredConversations.isEmpty {
                        emptyStateCard
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 28, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(filteredConversations) { conv in
                            ConversationRowCardView(
                                conv: conv,
                                modelName: resolveDisplayModelName(for: conv),
                                activityLabel: activity.labels[conv.id],
                                theme: theme,
                                onOpen: {
                                    if isSearchFocused {
                                        isSearchFocused = false
                                    }
                                    navigationPath.append(conv.id)
                                },
                                onRename: {
                                    renameText = conv.title
                                    renamingConversation = conv
                                },
                                onClear: {
                                    clearingConversation = conv
                                },
                                onDelete: {
                                    withTransaction(Transaction(animation: nil)) {
                                        deletingConversation = conv
                                    }
                                }
                            )
                            .equatable()
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    withTransaction(Transaction(animation: nil)) {
                                        deletingConversation = conv
                                    }
                                } label: {
                                    Label("删除", systemImage: "trash.fill")
                                }
                                .tint(theme.isDark ? Color(red: 0.78, green: 0.24, blue: 0.29) : Color(red: 0.76, green: 0.12, blue: 0.16))
                                .accessibilityLabel("删除对话")
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(theme.background)
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("AI 工作台")
            .navigationBarTitleDisplayMode(.large)
            .confirmationDialog("确认删除对话？", isPresented: Binding(
                get: { deletingConversation != nil },
                set: { if !$0 { deletingConversation = nil } }
            ), titleVisibility: .visible) {
                Button("取消", role: .cancel) {
                    deletingConversation = nil
                }
                Button("删除对话", role: .destructive) {
                    guard let target = deletingConversation else { return }
                    deletingConversation = nil
                    storage.deleteConversation(id: target.id)
                }
            } message: {
                Text("将永久删除「\(deletingConversation?.title ?? "该对话")」及其所有消息记录，此操作不可恢复。")
            }
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: String.self) { convId in
                ChatDetailView(conversationId: convId)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: createAndOpenConversation) {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .bold))
                            Text("新对话")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(theme.accent)
                        .clipShape(Capsule())
                    }
                }
            }
            .alert("重命名对话", isPresented: Binding(
                get: { renamingConversation != nil },
                set: { if !$0 { renamingConversation = nil } }
            )) {
                TextField("对话标题", text: $renameText)
                Button("取消", role: .cancel) {
                    renamingConversation = nil
                }
                Button("确定") {
                    if let target = renamingConversation {
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            storage.renameConversation(id: target.id, newTitle: trimmed)
                        }
                    }
                    renamingConversation = nil
                }
            }
            .alert("确认清空对话消息？", isPresented: Binding(
                get: { clearingConversation != nil },
                set: { if !$0 { clearingConversation = nil } }
            )) {
                Button("取消", role: .cancel) {
                    clearingConversation = nil
                }
                Button("清空消息", role: .destructive) {
                    if let target = clearingConversation {
                        storage.clearConversationMessages(id: target.id)
                    }
                    clearingConversation = nil
                }
            } message: {
                Text("将清空「\(clearingConversation?.title ?? "该对话")」中的所有消息内容，但保留此对话。")
            }
        }
    }

    private var studioHeroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(theme.accent.opacity(0.15))
                        .frame(width: 46, height: 46)
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(theme.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("智能对话与工具协同")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(theme.primaryText)
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "cpu")
                                .font(.system(size: 11))
                            Text(storage.settings.modelName)
                                .lineLimit(1)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.accent.opacity(0.12))
                        .clipShape(Capsule())

                        HStack(spacing: 4) {
                            Circle()
                                .fill(activeToolCount > 0 ? theme.accent : theme.mutedText)
                                .frame(width: 6, height: 6)
                            Text(activeToolCount > 0 ? "\(activeToolCount) 个工具就绪" : "纯对话模式")
                        }
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                    }
                }

                Spacer()
            }

            Button(action: createAndOpenConversation) {
                HStack {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("立即开启新对话")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(16)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.mutedText)

            TextField("搜索对话标题或消息内容...", text: $searchText)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .onSubmit { isSearchFocused = false }
                .font(.system(size: 14))
                .foregroundColor(theme.primaryText)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(theme.mutedText)
                }
                .buttonStyle(.plain)
            }

            if isSearchFocused {
                Button(action: { isSearchFocused = false }) {
                    Text("收起")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSearchFocused ? theme.accent : theme.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            isSearchFocused = true
        }
    }

    private var emptyStateCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(theme.elevatedBackground)
                    .frame(width: 64, height: 64)
                Image(systemName: searchText.isEmpty ? "tray" : "magnifyingglass")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(theme.mutedText)
            }
            Text(searchText.isEmpty ? "还没有对话记录" : "未找到匹配的对话")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(searchText.isEmpty ? "点击上方按钮创建你的第一个 AI 会话，支持自由切换柔和主题色与挂载 MCP 工具。" : "请尝试更换关键词重新搜索。")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    private func createAndOpenConversation() {
        isSearchFocused = false
        let newConv = storage.addConversation()
        navigationPath.append(newConv.id)
    }
}

private struct ConversationRowCardView: View, Equatable {
    let conv: Conversation
    let modelName: String
    let activityLabel: String?
    let theme: AppThemePalette
    let onOpen: () -> Void
    let onRename: () -> Void
    let onClear: () -> Void
    let onDelete: () -> Void

    static func == (lhs: ConversationRowCardView, rhs: ConversationRowCardView) -> Bool {
        lhs.conv.id == rhs.conv.id &&
        lhs.conv.title == rhs.conv.title &&
        lhs.conv.updatedAt == rhs.conv.updatedAt &&
        lhs.conv.selectedProfileId == rhs.conv.selectedProfileId &&
        lhs.conv.selectedModelName == rhs.conv.selectedModelName &&
        lhs.conv.messages.count == rhs.conv.messages.count &&
        lhs.conv.messages.last?.id == rhs.conv.messages.last?.id &&
        lhs.conv.messages.last?.content.utf8.count == rhs.conv.messages.last?.content.utf8.count &&
        lhs.modelName == rhs.modelName &&
        lhs.activityLabel == rhs.activityLabel &&
        lhs.theme == rhs.theme
    }

    private var rowSummary: (nonToolCount: Int, hasTools: Bool, previewText: String?) {
        var nonToolCount = 0
        var hasTools = false
        for m in conv.messages {
            if m.role != .tool {
                nonToolCount += 1
            }
            if !hasTools, let tc = m.toolCalls, !tc.isEmpty {
                hasTools = true
            }
        }

        var preview: String? = nil
        for m in conv.messages.reversed() where m.role != .tool {
            let trimmed = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                preview = trimmed.count > 120 ? String(trimmed.prefix(120)) : trimmed
                break
            }
            if let firstAtt = m.attachments?.first {
                if let snippet = firstAtt.textContent?.trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty {
                    let shortSnippet = snippet.count > 90 ? String(snippet.prefix(90)) : snippet
                    preview = "[\(firstAtt.fileName)] \(shortSnippet)"
                } else {
                    preview = "[附件] \(firstAtt.fileName)"
                }
                break
            }
        }
        return (nonToolCount, hasTools, preview)
    }

    var body: some View {
        let info = rowSummary

        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(info.hasTools ? theme.accent.opacity(0.14) : theme.elevatedBackground)
                                .frame(width: 34, height: 34)
                            Image(systemName: info.hasTools ? "wrench.and.screwdriver.fill" : "text.bubble.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(info.hasTools ? theme.accent : theme.secondaryText)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(conv.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                                .lineLimit(1)

                            HStack(spacing: 8) {
                                Text(conv.updatedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.mutedText)

                                if let label = activityLabel {
                                    HStack(spacing: 4) {
                                        ConversationActivityIndicator(color: theme.accent)
                                        Text(label)
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .foregroundColor(theme.accent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(theme.accent.opacity(0.12))
                                    .clipShape(Capsule())
                                }
                            }
                        }

                        Spacer()

                        Color.clear
                            .frame(width: 34, height: 32)
                    }

                    if let preview = info.previewText {
                        Text(preview)
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("空白会话 · 点击开始提问")
                            .font(.system(size: 13))
                            .foregroundColor(theme.mutedText)
                    }

                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "atom")
                                .font(.system(size: 10, weight: .semibold))
                            Text(modelName)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.accent.opacity(0.12))
                        .clipShape(Capsule())

                        Text("\(info.nonToolCount) 条对话")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(theme.elevatedBackground)
                            .clipShape(Capsule())

                        if info.hasTools {
                            Text("含工具调用")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(theme.accent.opacity(0.12))
                                .clipShape(Capsule())
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.mutedText)
                    }
                }
                .padding(14)
                .background(theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(theme.border, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)

            Menu {
                Button(action: onRename) {
                    Label("重命名", systemImage: "pencil")
                }

                Button(action: onClear) {
                    Label("清空消息", systemImage: "eraser")
                }

                Button(role: .destructive, action: onDelete) {
                    Label("删除对话", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(theme.elevatedBackground)
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
    }
}

private struct ConversationActivityIndicator: View {
    let color: Color
    @State private var isVisible = false
    @State private var animationRevision = 0

    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .tint(color)
            .frame(width: 10, height: 10)
            .id(animationRevision)
            .onAppear {
                guard !isVisible else { return }
                isVisible = true
                animationRevision &+= 1
            }
            .onDisappear {
                isVisible = false
            }
    }
}
