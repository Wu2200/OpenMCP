import SwiftUI

struct MCPServersView: View {
    @EnvironmentObject var storage: DataStorage
    @State private var showingAddSheet: Bool = false
    @State private var serverToEdit: MCPServer? = nil
    @State private var isRefreshingAll: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if storage.servers.isEmpty {
                        VStack(spacing: 8) {
                            Text("未配置 MCP 服务")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("支持标准 HTTP / SSE 形式的 MCP 服务")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        ForEach(storage.servers) { server in
                            NavigationLink(destination: MCPToolDetailView(server: server)) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(server.name)
                                                .font(.headline)
                                            if !server.isEnabled {
                                                Text("已停用")
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.gray.opacity(0.2))
                                                    .cornerRadius(4)
                                            }
                                        }
                                        Text(server.url)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                        Text("\(server.tools.count) 个可用工具")
                                            .font(.caption2)
                                            .foregroundColor(.blue)
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
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button(action: {
                                    serverToEdit = server
                                }) {
                                    Label("编辑", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                        .onDelete(perform: storage.deleteServer)
                    }
                } header: {
                    Text("MCP 服务器列表")
                } footer: {
                    Text("左滑可删除服务，右滑可编辑。开启后 AI 会在提问时自动识别并调用对应工具。")
                }
            }
            .navigationTitle("MCP 服务管理")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: refreshAllServers) {
                        if isRefreshingAll {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshingAll || storage.servers.isEmpty)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        serverToEdit = nil
                        showingAddSheet = true
                    }) {
                        Image(systemName: "plus")
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
            isRefreshingAll = false
        }
    }
}
