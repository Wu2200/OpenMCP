import SwiftUI
import AVFoundation

@main
struct OpenMCPApp: App {
    @StateObject private var storage = DataStorage.shared

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(storage)
        }
    }
}
