import SwiftUI

struct MCPToolDetailView: View {
    @EnvironmentObject var storage: DataStorage
    @State var server: MCPServer
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool

    private var theme: AppThemePalette {
        storage.settings.currentTheme
    }

    private var filteredToolIndices: [Int] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return server.tools.indices.filter { idx in
            guard !q.isEmpty else { return true }
            let tool = server.tools[idx]
            return tool.name.lowercased().contains(q) || tool.description.lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    isSearchFocused = false
                }

            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.name)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(theme.primaryText)
                                Text(server.url)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(theme.secondaryText)
                            }
                            Spacer()
                            Text("\(server.tools.filter { $0.isEnabled }.count)/\(server.tools.count) 启用")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.accent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(theme.accent.opacity(0.12))
                                .clipShape(Capsule())
                        }

                        if !server.tools.isEmpty {
                            HStack(spacing: 10) {
                                Button(action: { setAllTools(enabled: true) }) {
                                    Text("全部启用")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(theme.accent)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(theme.elevatedBackground)
                                        .clipShape(Capsule())
                                }

                                Button(action: { setAllTools(enabled: false) }) {
                                    Text("全部停用")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(theme.secondaryText)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(theme.elevatedBackground)
                                        .clipShape(Capsule())
                                }

                                Spacer()
                            }
                        }
                    }
                    .padding(16)
                    .background(theme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    )

                    if !server.tools.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(theme.mutedText)
                            TextField("筛选工具名称或描述...", text: $searchText)
                                .focused($isSearchFocused)
                                .submitLabel(.search)
                                .onSubmit { isSearchFocused = false }
                                .font(.system(size: 14))
                                .foregroundColor(theme.primaryText)

                            if !searchText.isEmpty {
                                Button(action: { searchText = "" }) {
                                    Image(systemName: "xmark.circle.fill")
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
                        .padding(12)
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

                    if filteredToolIndices.isEmpty {
                        Text(server.tools.isEmpty ? "尚未获取到工具，请在服务卡片上点击刷新或编辑。" : "没有匹配的工具")
                            .font(.system(size: 14))
                            .foregroundColor(theme.secondaryText)
                            .padding(.vertical, 32)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredToolIndices, id: \.self) { idx in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(server.tools[idx].name)
                                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                                            .foregroundColor(theme.primaryText)
                                        Spacer()
                                        Toggle("", isOn: Binding(
                                            get: { server.tools[idx].isEnabled },
                                            set: { newVal in
                                                server.tools[idx].isEnabled = newVal
                                                storage.addOrUpdateServer(server)
                                            }
                                        ))
                                        .labelsHidden()
                                        .tint(theme.accent)
                                    }

                                    Text(server.tools[idx].description)
                                        .font(.system(size: 13))
                                        .foregroundColor(theme.secondaryText)

                                    DisclosureGroup("参数定义 (JSON Schema)") {
                                        Text(server.tools[idx].inputSchemaJSON)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(theme.primaryText)
                                            .padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(theme.elevatedBackground)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                            .padding(.top, 4)
                                    }
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.accent)
                                }
                                .padding(14)
                                .background(theme.cardBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(theme.border, lineWidth: 1)
                                )
                            }
                        }
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func setAllTools(enabled: Bool) {
        for idx in server.tools.indices {
            server.tools[idx].isEnabled = enabled
        }
        storage.addOrUpdateServer(server)
    }
}
