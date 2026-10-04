import SwiftUI

struct MainView: View {
    @Environment(DeviceManager.self) private var devices
    @Environment(ProfileStore.self) private var store
    @Environment(CaptureController.self) private var capture

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SpectrumEditorView(feed: capture.feed)
            OutputShelf()
        }
        .padding(16)
        .background(Theme.background)
        .onChange(of: devices.outputs, initial: true) { _, outputs in
            store.register(outputs)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                CaptureStatus()
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings & calibration")
            }
        }
    }
}

/// The row of output stickers along the bottom of the window.
struct OutputShelf: View {
    @Environment(DeviceManager.self) private var devices
    @Environment(ProfileStore.self) private var store

    private var knownUIDs: [String] {
        let connected = devices.outputs.map(\.uid)
        let offline = store.profile.devices
            .filter { !devices.isConnected($0.key) }
            .sorted { $0.value.colorIndex < $1.value.colorIndex }
            .map(\.key)
        return connected + offline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("OUTPUTS")
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textTertiary)
                Text("Drag an output onto the timeline, then drag its edges to choose which frequencies it plays. Red means nothing plays those frequencies.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(knownUIDs, id: \.self) { uid in
                        if let settings = store.profile.devices[uid] {
                            DeviceSticker(
                                uid: uid,
                                settings: settings,
                                device: devices.outputs.first { $0.uid == uid })
                        }
                    }
                    if knownUIDs.isEmpty {
                        Text("No output devices found")
                            .foregroundStyle(Theme.textSecondary)
                            .padding()
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// Shows what the spectrum is listening to.
struct CaptureStatus: View {
    @Environment(CaptureController.self) private var capture

    private var status: (color: Color, text: String) {
        switch capture.source {
        case .starting: (Theme.textTertiary, "Starting capture…")
        case .spotify where capture.spotifyPlaying: (Color(hex: 0x1ED760), "Listening to Spotify")
        case .spotify: (Color(hex: 0x1ED760).opacity(0.5), "Spotify open · paused")
        case .system: (Theme.accent, "Spotify not open · showing all system audio")
        case .failed(let message): (Theme.danger, "Capture failed: \(message)")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(status.color).frame(width: 8, height: 8)
            Text(status.text)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            Text("· routing not connected yet")
                .font(.callout)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
