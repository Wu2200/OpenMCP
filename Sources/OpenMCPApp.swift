import SwiftUI

@main
struct OpenMCPApp: App {
    @StateObject private var storage = DataStorage.shared

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(storage)
        }
    }
}
