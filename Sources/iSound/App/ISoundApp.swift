import AppKit
import SwiftUI

@main
struct ISoundApp: App {
    // Declared first so it runs before the stores below read their saved state.
    private let migrated: Void = LegacyMigration.run()
    @State private var devices = DeviceManager()
    @State private var store = ProfileStore()
    @State private var engine = AudioEngine()

    init() {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    var body: some Scene {
        WindowGroup("iSound") {
            MainView()
                .environment(devices)
                .environment(store)
                .environment(engine)
                .onAppear {
                    engine.start()
                    CalibrationCommandLine.runIfRequested(engine: engine, outputs: devices.outputs)
                }
                .preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environment(devices)
                .environment(store)
                .environment(engine)
                .preferredColorScheme(.dark)
        }
    }
}
