import AppKit
import SwiftUI

@main
struct SoundStageApp: App {
    @State private var devices = DeviceManager()
    @State private var store = ProfileStore()
    @State private var capture = CaptureController()

    init() {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    var body: some Scene {
        WindowGroup("SoundStage") {
            MainView()
                .environment(devices)
                .environment(store)
                .environment(capture)
                .onAppear { capture.start() }
                .preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environment(devices)
                .environment(store)
                .preferredColorScheme(.dark)
        }
    }
}
