import SwiftUI

struct AddMCPServerView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var storage: DataStorage

    var server: MCPServer?

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var token: String = ""
    @State private var isTesting: Bool = false
    @State private var testResult: String? = nil
    @State private var isSuccess: Bool = false
    @State private var fetchedTools: [MCPTool] = []

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("服务基本信息")) {
                    TextField("服务名称 (如 GitHub, Memory)", text: $name)
                    TextField("服务 URL (http:// 或 https://)", text: $url)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    SecureField("可选 Auth Token (Bearer)", text: $token)
                        .autocapitalization(.none)
                }

                Section {
                    Button(action: testAndFetch) {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Text(isTesting ? "正在测试并拉取工具..." : "测试连接并拉取工具")
                                .bold()
                        }
                    }
                    .disabled(isTesting || name.isEmpty || url.isEmpty)

                    if let res = testResult {
                        HStack {
                            Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(isSuccess ? .green : .red)
                            Text(res)
                                .font(.footnote)
                                .foregroundColor(isSuccess ? .green : .red)
                        }
                    }
                }

                if !fetchedTools.isEmpty {
                    Section(header: Text("已发现工具 (\(fetchedTools.count))")) {
                        ForEach(fetchedTools) { tool in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name)
                                    .font(.subheadline)
                                    .bold()
                                Text(tool.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(server == nil ? "添加 MCP 服务" : "编辑 MCP 服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveServer()
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
            .onAppear {
                if let s = server {
                    name = s.name
                    url = s.url
                    token = s.token
                    fetchedTools = s.tools
                }
            }
        }
    }

    private func testAndFetch() {
        isTesting = true
        testResult = nil
        let target = MCPServer(name: name, url: url, token: token)

        Task {
            do {
                let tools = try await MCPService.shared.fetchTools(from: target)
                fetchedTools = tools
                isSuccess = true
                testResult = "连接成功！成功获取 \(tools.count) 个工具"
            } catch {
                isSuccess = false
                testResult = "连接失败: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }

    private func saveServer() {
        var s = server ?? MCPServer(name: name, url: url, token: token)
        s.name = name
        s.url = url
        s.token = token
        if !fetchedTools.isEmpty {
            s.tools = fetchedTools
        }
        storage.addOrUpdateServer(s)
        dismiss()
    }
}
