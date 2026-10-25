import SwiftUI
import UIKit

struct AddMCPServerView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var storage: DataStorage

    var server: MCPServer?

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var token: String = ""
    @State private var showToken: Bool = false
    @State private var isTesting: Bool = false
    @State private var testResult: String? = nil
    @State private var isSuccess: Bool = false
    @State private var fetchedTools: [MCPTool] = []

    private enum ServerField: Hashable {
        case name
        case url
        case token
    }

    @FocusState private var focusedField: ServerField?

    private var theme: AppThemePalette {
        storage.settings.currentTheme
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissKeyboard()
                    }

                ScrollView {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("服务连接配置")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(theme.primaryText)
                                Spacer()
                                if focusedField != nil {
                                    Button(action: dismissKeyboard) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "keyboard.chevron.compact.down")
                                            Text("收起")
                                        }
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundColor(theme.accent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3.5)
                                        .background(theme.accent.opacity(0.12))
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("服务名称")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.secondaryText)

                                HStack(spacing: 8) {
                                    TextField("例如 GitHub、Tavily、Cloudflare", text: $name)
                                        .focused($focusedField, equals: .name)
                                        .submitLabel(.next)
                                        .onSubmit { focusedField = .url }
                                        .font(.system(size: 15))
                                        .foregroundColor(theme.primaryText)

                                    if !name.isEmpty && focusedField == .name {
                                        Button(action: { name = "" }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(theme.mutedText)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(12)
                                .background(theme.elevatedBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(focusedField == .name ? theme.accent : theme.border.opacity(0.6), lineWidth: 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .onTapGesture { focusedField = .name }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("接口地址 (Endpoint URL)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.secondaryText)

                                HStack(spacing: 8) {
                                    TextField("https://example.com/mcp", text: $url)
                                        .focused($focusedField, equals: .url)
                                        .textInputAutocapitalization(.never)
                                        .disableAutocorrection(true)
                                        .keyboardType(.URL)
                                        .submitLabel(.next)
                                        .onSubmit { focusedField = .token }
                                        .font(.system(size: 14, design: .monospaced))
                                        .foregroundColor(theme.primaryText)

                                    if !url.isEmpty && focusedField == .url {
                                        Button(action: { url = "" }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(theme.mutedText)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(12)
                                .background(theme.elevatedBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(focusedField == .url ? theme.accent : theme.border.opacity(0.6), lineWidth: 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .onTapGesture { focusedField = .url }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("认证令牌 (Bearer Token，可选)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(theme.secondaryText)

                                HStack(spacing: 8) {
                                    Group {
                                        if showToken {
                                            TextField("选填鉴权密钥", text: $token)
                                                .textInputAutocapitalization(.never)
                                                .disableAutocorrection(true)
                                                .submitLabel(.done)
                                                .onSubmit { focusedField = nil }
                                        } else {
                                            SecureField("选填鉴权密钥", text: $token)
                                                .textInputAutocapitalization(.never)
                                                .disableAutocorrection(true)
                                                .submitLabel(.done)
                                                .onSubmit { focusedField = nil }
                                        }
                                    }
                                    .focused($focusedField, equals: .token)
                                    .font(.system(size: 14))
                                    .foregroundColor(theme.primaryText)

                                    if !token.isEmpty && focusedField == .token {
                                        Button(action: { token = "" }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(theme.mutedText)
                                        }
                                        .buttonStyle(.plain)
                                    }

                                    Button(action: { showToken.toggle() }) {
                                        Image(systemName: showToken ? "eye.slash.fill" : "eye.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(theme.mutedText)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(12)
                                .background(theme.elevatedBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(focusedField == .token ? theme.accent : theme.border.opacity(0.6), lineWidth: 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .onTapGesture { focusedField = .token }
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
                                        .foregroundColor(isSuccess ? theme.accent : .red)
                                    Text(res)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(isSuccess ? theme.accent : .red)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background((isSuccess ? theme.accent : Color.red).opacity(0.1))
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
                    .background(
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismissKeyboard()
                            }
                    )
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(server == nil ? "添加 MCP 服务" : "编辑 MCP 服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismissKeyboard()
                        dismiss()
                    }
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

    private func dismissKeyboard() {
        focusedField = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func testAndFetch() {
        dismissKeyboard()
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
        dismissKeyboard()
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
