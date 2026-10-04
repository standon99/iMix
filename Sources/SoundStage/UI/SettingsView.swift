import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            CalibrationSettingsView()
                .tabItem { Label("Calibrate", systemImage: "waveform.badge.mic") }
        }
        .frame(width: 560, height: 420)
    }
}

/// Placeholder for step 4: shows each output's measured latency and will run the sweep measurement.
struct CalibrationSettingsView: View {
    @Environment(DeviceManager.self) private var devices
    @Environment(ProfileStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speaker calibration")
                    .font(.title3.weight(.semibold))
                Text("Sit where you normally listen with the Mac's microphone nearby. SoundStage plays a short sweep through each output, listens for it, and measures how long it takes to arrive. Every output is then delayed to line up with the slowest one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Table(devices.outputs) {
                TableColumn("Output") { device in
                    HStack(spacing: 6) {
                        if let settings = store.profile.devices[device.uid] {
                            Circle().fill(Theme.color(forDevice: settings.colorIndex)).frame(width: 8, height: 8)
                            Text(settings.displayName)
                        } else {
                            Text(device.name)
                        }
                    }
                }
                TableColumn("Connection") { device in
                    Text(device.transport.label).foregroundStyle(.secondary)
                }
                .width(90)
                TableColumn("Latency") { device in
                    Text(store.profile.devices[device.uid]?.latencyMs.map { String(format: "%.1f ms", $0) } ?? "—")
                        .monospacedDigit()
                }
                .width(80)
            }

            HStack {
                Text("Calibration is coming in step 4.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start Calibration") {}
                    .disabled(true)
            }
        }
        .padding(20)
    }
}
