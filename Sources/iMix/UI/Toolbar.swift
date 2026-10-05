import SwiftUI

/// Shows what's being captured and whether it's being routed.
struct CaptureStatus: View {
    @Environment(AudioEngine.self) private var engine

    private var appsText: String {
        let names = engine.runningApps.filter { engine.selectedApps.contains($0.bundleID) }.map(\.name)
        switch names.count {
        case 0: return "selected apps"
        case 1: return names[0]
        default: return "\(names.count) apps"
        }
    }

    private var status: (color: Color, text: String) {
        let green = Color(hex: 0x1ED760)
        let outputs = engine.routedOutputs.count
        let outputsText = "\(outputs) output\(outputs == 1 ? "" : "s")"
        switch engine.source {
        case .starting: return (Theme.textTertiary, "Starting…")
        case .suspended: return (Theme.textTertiary, "Paused for calibration")
        case .failed(let message): return (Theme.danger, "Audio error: \(message)")
        case .waitingForApps: return (Theme.accent, "Waiting for \(appsText) to play")
        case .allAudio, .apps:
            let what = engine.source == .apps ? appsText : "all audio"
            if engine.routingActive {
                return outputs == 0
                    ? (Theme.danger, "Routing \(what) · nothing on the timeline (silent)")
                    : (green, "Routing \(what) to \(outputsText)")
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

/// Chooses what to capture: everything, or a set of running apps.
struct SourceMenu: View {
    @Environment(AudioEngine.self) private var engine

    private var title: String {
        let names = engine.selectedApps.map { id in engine.runningApps.first { $0.bundleID == id }?.name ?? id }
        switch names.count {
        case 0: return "All audio"
        case 1: return names[0]
        default: return "\(names[0]) + \(names.count - 1)"
        }
    }

    var body: some View {
        Menu {
            Toggle("All audio", isOn: Binding(
                get: { engine.selectedApps.isEmpty },
                set: { if $0 { engine.selectedApps = [] } }))
            Divider()
            Section("Running apps") {
                ForEach(engine.runningApps) { app in
                    Toggle(isOn: Binding(
                        get: { engine.selectedApps.contains(app.bundleID) },
                        set: { _ in engine.toggleApp(app.bundleID) })) {
                        Text(app.playing ? "\(app.name)  ♪" : app.name)
                    }
                }
            }
            // Selected apps that have since quit, so they can still be unticked.
            let gone = engine.selectedApps.filter { id in !engine.runningApps.contains { $0.bundleID == id } }
            if !gone.isEmpty {
                Section("Not running") {
                    ForEach(gone, id: \.self) { id in
                        Toggle(id, isOn: Binding(get: { true }, set: { _ in engine.toggleApp(id) }))
                    }
                }
            }
        } label: {
            Label(title, systemImage: "app.badge")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("Capture all audio, or tick specific apps. ♪ = playing now.")
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
        .help("On: audio plays through the outputs on the timeline, split by frequency, with the EQ. Off: audio plays normally.")
    }
}

/// iMix's master volume: scales every speaker. The volume keys control it while routing
/// (with Accessibility access). Click the speaker icon to mute.
struct MasterVolumeControl: View {
    @Environment(AudioEngine.self) private var engine

    var body: some View {
        HStack(spacing: 6) {
            Button { engine.toggleMasterMute() } label: {
                Image(systemName: icon)
                    .foregroundStyle(engine.masterMuted ? Theme.danger : Theme.textSecondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            Slider(value: Binding(get: { engine.masterVolume }, set: { engine.setMasterVolume($0) }), in: 0...1)
                .controlSize(.small)
                .frame(width: 90)
        }
        .help(engine.volumeKeysAllowed
              ? "Master volume: scales every speaker. At 100%, each speaker plays at its sticker volume. While routing, your keyboard volume keys control this."
              : "Master volume: scales every speaker. To use the keyboard volume keys, allow iMix in Settings → General.")
    }

    private var icon: String {
        if engine.masterMuted || engine.masterVolume == 0 { return "speaker.slash.fill" }
        return engine.masterVolume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
    }
}
