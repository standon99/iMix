import SwiftUI

struct MainView: View {
    @Environment(DeviceManager.self) private var devices
    @Environment(ProfileStore.self) private var store
    @Environment(AudioEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SpectrumEditorView(feed: engine.feed)
            OutputShelf()
        }
        .padding(16)
        .background(Theme.background)
        .onChange(of: devices.outputs, initial: true) { _, outputs in
            store.register(outputs)
            engine.update(profile: store.profile, connected: outputs)
        }
        .onChange(of: store.profile) { _, profile in
            engine.update(profile: profile, connected: devices.outputs)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                CaptureStatus()
            }
            ToolbarItem(placement: .primaryAction) {
                CaptureModePicker()
            }
            ToolbarItem(placement: .primaryAction) {
                RoutingToggle()
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

/// Shows what the spectrum is listening to and whether audio is being routed.
struct CaptureStatus: View {
    @Environment(AudioEngine.self) private var engine
    @Environment(ProfileStore.self) private var store

    private var status: (color: Color, text: String) {
        let green = Color(hex: 0x1ED760)
        let outputs = engine.routedOutputs.count
        let outputsText = "\(outputs) output\(outputs == 1 ? "" : "s")"
        switch engine.source {
        case .starting: return (Theme.textTertiary, "Starting…")
        case .suspended: return (Theme.textTertiary, "Paused for calibration")
        case .failed(let message): return (Theme.danger, "Audio error: \(message)")
        case .system, .spotify:
            let what = engine.source == .spotify ? "Spotify" : "all audio"
            if engine.routingActive {
                return outputs == 0
                    ? (Theme.danger, "Routing \(what) · no outputs on the timeline (silent)")
                    : (green, "Routing \(what) to \(outputsText)")
            }
            if engine.routingEnabled && engine.captureMode == .spotify {
                return (Theme.accent, "Waiting for Spotify · showing all audio")
            }
            return (Theme.accent, "Listening to \(what) · playing normally")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(status.color).frame(width: 8, height: 8)
            Text(status.text)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }
}

/// Turns routing on/off: on mutes the captured audio's normal output and plays it through the timeline.
struct RoutingToggle: View {
    @Environment(AudioEngine.self) private var engine

    var body: some View {
        @Bindable var engine = engine
        HStack(spacing: 6) {
            Text("Route")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            Toggle("Route", isOn: $engine.routingEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .controlSize(.small)
        .help("On: audio plays through the outputs on the timeline, split by frequency. Off: audio plays normally.")
    }
}

/// Chooses whether SoundStage captures and routes everything the Mac plays, or only Spotify.
struct CaptureModePicker: View {
    @Environment(AudioEngine.self) private var engine

    var body: some View {
        @Bindable var engine = engine
        Picker("Source", selection: $engine.captureMode) {
            ForEach(AudioEngine.CaptureMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("All audio: everything the Mac plays. Spotify: only Spotify; everything else plays normally.")
    }
}
