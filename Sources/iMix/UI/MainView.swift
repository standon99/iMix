import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case mixer, equalizer
    var id: String { rawValue }
    var label: String { self == .mixer ? "Mixer" : "Equalizer" }
}

struct MainView: View {
    @Environment(DeviceManager.self) private var devices
    @Environment(ProfileStore.self) private var store
    @Environment(AudioEngine.self) private var engine
    @AppStorage("page") private var page: Page = .mixer

    var body: some View {
        Group {
            switch page {
            case .mixer:
                VStack(alignment: .leading, spacing: 14) {
                    SpectrumEditorView(feed: engine.feed)
                    OutputShelf()
                }
            case .equalizer:
                EqualizerView(feed: engine.feed)
            }
        }
        .padding(16)
        .background(Theme.background)
        .onAppear {
            // A speaker's volume changed outside iMix (e.g. Control Center): move its sticker to match.
            engine.onDeviceVolumeChanged = { uid, volume in
                store.updateDevice(uid) { $0.masterVolume = volume }
            }
        }
        .onChange(of: devices.outputs, initial: true) { _, outputs in
            store.register(outputs)
            engine.update(profile: store.profile, connected: outputs)
        }
        .onChange(of: store.profile) { _, profile in
            engine.update(profile: profile, connected: devices.outputs)
        }
        .hidingWindowTitle()
        .toolbar {
            ToolbarItem(placement: .navigation) {
                CaptureStatus()
            }
            ToolbarItem(placement: .principal) {
                Picker("Page", selection: $page) {
                    ForEach(Page.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                SourceMenu()
            }
            ToolbarItem(placement: .primaryAction) {
                RoutingToggle()
            }
            ToolbarItem(placement: .primaryAction) {
                MasterVolumeControl()
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


private extension View {
    /// The toolbar is full; the window title isn't needed (macOS 15+).
    @ViewBuilder
    func hidingWindowTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}
