import SwiftUI
import UIKit

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

    private var theme: AppThemePalette {
        storage.settings.currentTheme
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("服务连接配置")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(theme.primaryText)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("服务名称")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.secondaryText)
                                TextField("例如 GitHub、Tavily、Cloudflare", text: $name)
                                    .font(.system(size: 15))
                                    .foregroundColor(theme.primaryText)
                                    .padding(12)
                                    .background(theme.elevatedBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("接口地址 (Endpoint URL)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.secondaryText)
                                TextField("https://example.com/mcp", text: $url)
                                    .autocapitalization(.none)
                                    .keyboardType(.URL)
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundColor(theme.primaryText)
                                    .padding(12)
                                    .background(theme.elevatedBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("认证令牌 (Bearer Token，可选)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.secondaryText)
                                SecureField("选填鉴权密钥", text: $token)
                                    .autocapitalization(.none)
                                    .font(.system(size: 14))
                                    .foregroundColor(theme.primaryText)
                                    .padding(12)
                                    .background(theme.elevatedBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            Button(action: testAndFetch) {
                                HStack(spacing: 8) {
                                    if isTesting {
                                        ProgressView()
                                            .scaleEffect(0.85)
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "bolt.horizontal.fill")
                                    }
                                    Text(isTesting ? "正在握手并拉取工具..." : "测试连接并获取工具")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background((isTesting || name.isEmpty || url.isEmpty) ? theme.mutedText : theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .disabled(isTesting || name.isEmpty || url.isEmpty)

                            if let res = testResult {
                                HStack(spacing: 8) {
                                    Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundColor(isSuccess ? .green : .red)
                                    Text(res)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(isSuccess ? .green : .red)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background((isSuccess ? Color.green : Color.red).opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                        .padding(16)
                        .background(theme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(theme.border, lineWidth: 1)
                        )

                        if !fetchedTools.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("已发现工具 (\(fetchedTools.count))")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(theme.primaryText)

                                ForEach(fetchedTools) { tool in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(tool.name)
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                            .foregroundColor(theme.accent)
                                        Text(tool.description)
                                            .font(.system(size: 12))
                                            .foregroundColor(theme.secondaryText)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(theme.elevatedBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                )
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
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isTesting = true
        testResult = nil
        let target = MCPServer(name: name, url: url, token: token)

        Task {
            do {
                let tools = try await MCPService.shared.fetchTools(from: target)
                await MainActor.run {
                    fetchedTools = tools
                    isSuccess = true
                    testResult = "连接成功，共发现 \(tools.count) 个可用工具"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    isSuccess = false
                    testResult = "连接失败: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }

    private func saveServer() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
