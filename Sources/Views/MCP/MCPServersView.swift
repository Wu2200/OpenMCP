import SwiftUI

struct MCPServersView: View {
    @EnvironmentObject var storage: DataStorage
    @State private var showingAddSheet: Bool = false
    @State private var serverToEdit: MCPServer? = nil
    @State private var isRefreshingAll: Bool = false
    @State private var refreshingServerId: String? = nil

    private var theme: AppThemePalette {
        storage.settings.currentTheme
    }

    private var enabledServerCount: Int {
        storage.servers.filter { $0.isEnabled }.count
    }

    private var totalToolCount: Int {
        storage.servers.reduce(0) { $0 + $1.tools.count }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        overviewDashboardCard

                        if storage.servers.isEmpty {
                            emptyServersCard
                        } else {
                            LazyVStack(spacing: 14) {
                                ForEach(storage.servers) { server in
                                    serverCard(for: server)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("MCP 工具中心")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        serverToEdit = nil
                        showingAddSheet = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .bold))
                            Text("添加服务")
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
            .sheet(isPresented: $showingAddSheet) {
                AddMCPServerView(server: nil)
            }
            .sheet(item: $serverToEdit) { s in
                AddMCPServerView(server: s)
            }
        }
    }

    private var overviewDashboardCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                metricBox(title: "已配置服务", value: "\(storage.servers.count)", icon: "server.rack")
                metricBox(title: "启用中服务", value: "\(enabledServerCount)", icon: "bolt.horizontal.circle.fill")
                metricBox(title: "已发现工具", value: "\(totalToolCount)", icon: "wrench.and.screwdriver.fill")
            }

            if !storage.servers.isEmpty {
                Button(action: refreshAllServers) {
                    HStack(spacing: 6) {
                        if isRefreshingAll {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(theme.accent)
                            Text("正在同步所有 MCP 服务工具...")
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("一键同步全部服务工具")
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(theme.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(isRefreshingAll)
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

    private func metricBox(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.accent)
                Spacer()
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(theme.primaryText)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyServersCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(theme.elevatedBackground)
                    .frame(width: 64, height: 64)
                Image(systemName: "cpu")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(theme.mutedText)
            }
            Text("尚未配置 MCP 服务")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text("支持接入基于 HTTP / JSON-RPC 或 SSE 协议的远程 MCP 工具服务，赋予 AI 实时检索与执行能力。")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Button(action: {
                serverToEdit = nil
                showingAddSheet = true
            }) {
                Text("立即添加第一个服务")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(theme.accent)
                    .clipShape(Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    private func serverCard(for server: MCPServer) -> some View {
        let enabledTools = server.tools.filter { $0.isEnabled }.count

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(server.isEnabled ? theme.accent.opacity(0.14) : theme.elevatedBackground)
                        .frame(width: 42, height: 42)
                    Image(systemName: "Cube.box.fill".lowercased())
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(server.isEnabled ? theme.accent : theme.mutedText)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(server.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(theme.primaryText)

                        Text(server.isEnabled ? "已启用" : "已停用")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(server.isEnabled ? theme.accent : theme.mutedText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(server.isEnabled ? theme.accent.opacity(0.12) : theme.elevatedBackground)
                            .clipShape(Capsule())
                    }

                    Text(server.url)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { server.isEnabled },
                    set: { newVal in
                        var updated = server
                        updated.isEnabled = newVal
                        storage.addOrUpdateServer(updated)
                    }
                ))
                .labelsHidden()
                .tint(theme.accent)
            }

            Divider()
                .overlay(theme.border)

            HStack(spacing: 8) {
                NavigationLink(destination: MCPToolDetailView(server: server)) {
                    HStack(spacing: 5) {
                        Image(systemName: "list.bullet.rectangle")
                        Text("管理 \(enabledTools)/\(server.tools.count) 个工具")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(theme.accent.opacity(0.12))
                    .clipShape(Capsule())
                }

                Spacer()

                Button(action: { refreshSingleServer(server) }) {
                    if refreshingServerId == server.id {
                        ProgressView()
                            .scaleEffect(0.75)
                            .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 32, height: 32)
                            .background(theme.elevatedBackground)
                            .clipShape(Circle())
                    }
                }

                Button(action: { serverToEdit = server }) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 32, height: 32)
                        .background(theme.elevatedBackground)
                        .clipShape(Circle())
                }

                Button(action: { storage.deleteServer(id: server.id) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.red.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .background(Color.red.opacity(0.1))
                        .clipShape(Circle())
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
    }

    private func refreshSingleServer(_ server: MCPServer) {
        refreshingServerId = server.id
        Task {
            if let updatedTools = try? await MCPService.shared.fetchTools(from: server) {
                var s = server
                s.tools = updatedTools
                s.lastChecked = Date()
                s.statusMessage = "连接正常"
                storage.addOrUpdateServer(s)
            }
            await MainActor.run {
                refreshingServerId = nil
            }
        }
    }

    private func refreshAllServers() {
        isRefreshingAll = true
        Task {
            for server in storage.servers {
                if let updatedTools = try? await MCPService.shared.fetchTools(from: server) {
                    var s = server
                    s.tools = updatedTools
                    s.lastChecked = Date()
                    s.statusMessage = "连接正常"
                    storage.addOrUpdateServer(s)
                }
            }
            await MainActor.run {
                isRefreshingAll = false
            }
        }
    }
}
