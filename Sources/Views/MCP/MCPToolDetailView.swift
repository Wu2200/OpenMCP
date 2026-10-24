import SwiftUI

struct MCPToolDetailView: View {
    @EnvironmentObject var storage: DataStorage
    @State var server: MCPServer

    var body: some View {
        List {
            Section(header: Text("服务详情")) {
                LabeledContent("服务名称", value: server.name)
                LabeledContent("接口地址", value: server.url)
                if let last = server.lastChecked {
                    LabeledContent("上次校验", value: last, format: .dateTime)
                }
            }

            Section(header: Text("工具列表 (\(server.tools.count))")) {
                if server.tools.isEmpty {
                    Text("未发现工具，请在编辑页面点击测试与拉取")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(server.tools.indices, id: \.self) { idx in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(server.tools[idx].name)
                                    .font(.headline)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { server.tools[idx].isEnabled },
                                    set: { newVal in
                                        server.tools[idx].isEnabled = newVal
                                        storage.addOrUpdateServer(server)
                                    }
                                ))
                                .labelsHidden()
                            }
                            Text(server.tools[idx].description)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            DisclosureGroup("查看参数格式 (Schema)") {
                                Text(server.tools[idx].inputSchemaJSON)
                                    .font(.system(.caption2, design: .monospaced))
                                    .padding(6)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(6)
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle(server.name)
    }
}
