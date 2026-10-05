import ServiceManagement
import SwiftUI

/// App-wide preferences: opening at login, and using the volume keys for iMix.
struct GeneralSettingsView: View {
    @Environment(AudioEngine.self) private var engine
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open iMix at login", isOn: Binding(get: { status == .enabled }, set: setOpenAtLogin))
                if status == .requiresApproval {
                    HStack {
                        Text("macOS needs you to allow iMix in Login Items.")
                            .foregroundStyle(.orange)
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .font(.callout)
                }
                if let error {
                    Text(error).font(.callout).foregroundStyle(Theme.danger)
                }
            } footer: {
                Text("iMix starts with your Mac and picks up where you left off, including routing if it was on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                @Bindable var engine = engine
                Toggle("Use the volume keys for iMix while routing", isOn: $engine.volumeKeysEnabled)
                if !engine.volumeKeysAllowed {
                    HStack {
                        Text("iMix needs Accessibility access to catch the volume keys.")
                            .foregroundStyle(.orange)
                        Button("Allow…") { engine.requestVolumeKeyAccess() }
                    }
                    .font(.callout)
                }
            } footer: {
                Text("While routing, the volume keys change iMix's master volume instead of the Mac's output device. When routing is off they work as normal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        // The user may change it in System Settings while this window is open.
        .onAppear { status = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = "Couldn't change the login item: \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }
}

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            VStack(spacing: 4) {
                Text("iMix")
                    .font(.system(size: 28, weight: .semibold))
                Text("Version \(version)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Split your Mac's audio across speakers by frequency.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer().frame(height: 8)
            Text("Designed by Siddhant Tandon, 2026")
                .font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
