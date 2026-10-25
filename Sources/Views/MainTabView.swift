import SwiftUI
import UIKit

struct MainTabView: View {
    @EnvironmentObject var storage: DataStorage

    private var theme: AppThemePalette {
        storage.settings.currentTheme
    }

    var body: some View {
        TabView {
            ConversationListView()
                .tabItem {
                    Label("工作台", systemImage: "sparkles.rectangle.stack.fill")
                }

            MCPServersView()
                .tabItem {
                    Label("MCP 工具", systemImage: "cpu.fill")
                }

            SettingsView()
                .tabItem {
                    Label("外观与设置", systemImage: "paintpalette.fill")
                }
        }
        .tint(theme.accent)
        .preferredColorScheme(theme.colorScheme)
        .onAppear {
            applyGlobalBarAppearance(theme: theme)
        }
        .onChange(of: storage.settings.currentTheme) { newTheme in
            applyGlobalBarAppearance(theme: newTheme)
        }
    }

    private func applyGlobalBarAppearance(theme: AppThemePalette) {
        let bgUIColor = UIColor(theme.background)
        let cardUIColor = UIColor(theme.cardBackground)
        let textUIColor = UIColor(theme.primaryText)

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = bgUIColor
        navAppearance.shadowColor = .clear
        navAppearance.titleTextAttributes = [.foregroundColor: textUIColor]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: textUIColor]

        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = cardUIColor
        tabAppearance.shadowColor = UIColor(theme.border)

        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }
}
