import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var storage: DataStorage

    var body: some View {
        TabView {
            ConversationListView()
                .tabItem {
                    Label("对话", systemImage: "bubble.left.and.bubble.right.fill")
                }

            MCPServersView()
                .tabItem {
                    Label("MCP 工具", systemImage: "wrench.and.screwdriver.fill")
                }

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
        }
        .tint(Color(red: 0.15, green: 0.45, blue: 0.95))
    }
}
