import SwiftUI

/// A draggable output card: name, connection, channel, volume and mute. Settings apply to all of the output's clips.
struct DeviceSticker: View {
    @Environment(ProfileStore.self) private var store
    let uid: String
    let settings: DeviceSettings
    /// nil when the device is remembered but not currently connected.
    let device: OutputDevice?

    @State private var renaming = false
    @State private var draftName = ""

    private var color: Color { Theme.color(forDevice: settings.colorIndex) }
    private var isOnline: Bool { device != nil }

    var body: some View {
        card
            .opacity(isOnline ? 1 : 0.45)
            .draggable(DragPayload.device(uid)) {
                StickerDragPreview(name: settings.displayName, color: color)
            }
            .contextMenu {
                Button("Rename…") {
                    draftName = settings.displayName
                    renaming = true
                }
                if settings.nickname != nil {
                    Button("Reset Name") { store.updateDevice(uid) { $0.nickname = nil } }
                }
                if !isOnline {
                    Divider()
                    Button("Forget Device", role: .destructive) { store.forgetDevice(uid) }
                }
            }
            .alert("Rename Output", isPresented: $renaming) {
                TextField("Name", text: $draftName)
                Button("Save") { store.updateDevice(uid) { $0.nickname = draftName } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(settings.name)
            }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: settings.transport.symbol)
                    .foregroundStyle(color)
                    .frame(width: 18)
                Text(settings.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    store.updateDevice(uid) { $0.muted.toggle() }
                } label: {
                    Image(systemName: settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(settings.muted ? Theme.danger : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(settings.muted ? "Unmute" : "Mute")
            }

            Picker("Channel", selection: Binding(
                get: { settings.channel },
                set: { mode in store.updateDevice(uid) { $0.channel = mode } }
            )) {
                ForEach(ChannelMode.allCases) { Text($0.shortLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help("L: left only · R: right only · L+R: both")

            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { settings.masterVolume },
                    set: { v in store.updateDevice(uid) { $0.masterVolume = v } }
                ), in: 0...1)
                .controlSize(.small)
                .tint(color)
                Text("\(Int((settings.masterVolume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 34, alignment: .trailing)
            }

            HStack(spacing: 6) {
                Text(isOnline ? settings.transport.label : "Disconnected")
                if let device {
                    Text("·")
                    Text("\(device.outputChannels) ch")
                }
                Text("·")
                Text(settings.latencyMs.map { String(format: "%.0f ms", $0) } ?? "not calibrated")
            }
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(12)
        .frame(width: 250)
        .background(Theme.panelRaised)
        // A plain strip, clipped by the card's corners below so it follows their curve.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(color)
                .frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.stroke)
        )
    }
}

struct StickerDragPreview: View {
    let name: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(name).font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.panelRaised))
        .overlay(Capsule().strokeBorder(color.opacity(0.8)))
        .foregroundStyle(Theme.textPrimary)
    }
}
