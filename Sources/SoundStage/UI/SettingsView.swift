import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            CalibrationSettingsView()
                .tabItem { Label("Calibrate", systemImage: "waveform.badge.mic") }
        }
        .frame(width: 640, height: 500)
    }
}

/// Measures each output's latency with a sweep + the microphone, then saves it so the router
/// can delay every output to line up with the slowest one.
struct CalibrationSettingsView: View {
    @Environment(DeviceManager.self) private var devices
    @Environment(ProfileStore.self) private var store
    @Environment(AudioEngine.self) private var engine

    private enum Phase: Equatable {
        case idle
        case running(Double)
        case done
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var excluded: Set<String> = []
    @State private var results: [String: CalibrationResult] = [:]
    @State private var task: Task<Void, Never>?

    @State private var mics: [MicrophoneAccess.Mic] = []
    @State private var micUID: String?
    private var mic: MicrophoneAccess.Mic? { mics.first { $0.uid == micUID } }
    private var selected: [String] { devices.outputs.map(\.uid).filter { !excluded.contains($0) } }
    private var isRunning: Bool { if case .running = phase { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speaker calibration")
                    .font(.title3.weight(.semibold))
                Text("Sit where you listen, keep the room quiet, and set a moderate volume. SoundStage plays a short sweep through each output five times, listens with the microphone, and measures how long each one takes to arrive. Outputs are then delayed to line up with the slowest (usually Bluetooth).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            micRow

            Table(devices.outputs) {
                TableColumn("") { device in
                    Toggle("", isOn: Binding(
                        get: { !excluded.contains(device.uid) },
                        set: { on in if on { excluded.remove(device.uid) } else { excluded.insert(device.uid) } }))
                    .labelsHidden()
                    .disabled(isRunning)
                }
                .width(24)
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
                TableColumn("Saved") { device in
                    Text(store.profile.devices[device.uid]?.latencyMs.map { String(format: "%.1f ms", $0) } ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(70)
                TableColumn("Measured") { device in
                    resultText(results[device.uid])
                }
                .width(min: 150)
            }

            footer
        }
        .padding(20)
        .onAppear(perform: loadMics)
        .onChange(of: devices.outputs) { loadMics() }
        .onDisappear { cancel() }
    }

    @ViewBuilder
    private var micRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic")
            if mics.isEmpty {
                Text("No microphone found").foregroundStyle(Theme.danger)
            } else {
                Picker("Listen with", selection: $micUID) {
                    ForEach(mics) { mic in
                        Text(mic.name).tag(Optional(mic.uid))
                    }
                }
                .fixedSize()
                .disabled(isRunning)
                if mic?.transport == .bluetooth {
                    Text("Bluetooth mics add their own delay; the Mac's mic is better.")
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.callout)
    }

    /// Refreshes the mic list, keeping the current choice if it's still connected.
    private func loadMics() {
        mics = MicrophoneAccess.inputDevices()
        if mic == nil { micUID = MicrophoneAccess.preferredMic(from: mics)?.uid }
    }

    @ViewBuilder
    private func resultText(_ result: CalibrationResult?) -> some View {
        if let result {
            if let latency = result.latencyMs {
                HStack(spacing: 6) {
                    Text(String(format: "%.1f ms", latency)).monospacedDigit().fontWeight(.semibold)
                    if let jitter = result.jitterMs {
                        Text(String(format: "±%.1f", jitter)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let level = relativeLevel(result) {
                        Text(String(format: "%+.0f dB", level)).monospacedDigit().foregroundStyle(.secondary)
                            .help("Loudness at the mic compared with the loudest output")
                    }
                    if isPolarityOutlier(result) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .help("This speaker's polarity is opposite to the others, so it may cancel bass where they overlap.")
                    }
                    if result.detections < result.runs {
                        Text("\(result.detections)/\(result.runs)").foregroundStyle(.orange)
                            .help("Some sweeps weren't heard clearly")
                    }
                }
            } else {
                Text("Not heard").foregroundStyle(Theme.danger)
                    .help("The microphone didn't pick this output up. Check its volume and that it's on.")
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    /// The mic itself may flip polarity, so only flag outputs that disagree with the others.
    private func isPolarityOutlier(_ result: CalibrationResult) -> Bool {
        let heard = results.values.filter { $0.latencyMs != nil }
        let invertedCount = heard.filter(\.inverted).count
        let majorityInverted = invertedCount * 2 > heard.count
        return heard.count > 1 && result.inverted != majorityInverted
    }

    private func relativeLevel(_ result: CalibrationResult) -> Double? {
        guard let level = result.levelDB,
              let loudest = results.values.compactMap(\.levelDB).max() else { return nil }
        return level - loudest
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            switch phase {
            case .idle:
                Text("Takes about \(Int(CalibrationRun.totalSeconds(selected.count).rounded())) s. Pause Spotify first.")
                    .font(.caption).foregroundStyle(.secondary)
            case .running(let progress):
                ProgressView(value: progress).frame(maxWidth: 260)
                Text("Measuring…").font(.caption).foregroundStyle(.secondary)
            case .done:
                Text("Done. Apply to save these latencies and re-align the outputs.")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(Theme.danger).lineLimit(2)
            }
            Spacer()
            if isRunning {
                Button("Cancel") { cancel() }
            } else {
                if phase == .done {
                    Button("Apply") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!results.values.contains { $0.latencyMs != nil })
                }
                Button(phase == .done ? "Run Again" : "Start Calibration") { start() }
                    .disabled(selected.isEmpty || mic == nil)
            }
        }
    }

    private func start() {
        guard let mic else { return }
        let outputs = selected
        results = [:]
        phase = .running(0)
        task = Task { @MainActor in
            guard await MicrophoneAccess.request() else {
                phase = .failed("Microphone access is off. Allow SoundStage in System Settings → Privacy & Security → Microphone.")
                return
            }
            engine.suspend()
            defer { engine.resume() }
            do {
                // Let the router's devices settle before taking them over.
                try await Task.sleep(for: .milliseconds(300))
                let run = try CalibrationRun(outputUIDs: outputs, micUID: mic.uid)
                let measured = try await run.perform { progress in phase = .running(progress) }
                results = Dictionary(uniqueKeysWithValues: measured.map { ($0.uid, $0) })
                phase = .done
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
    }

    private func apply() {
        for result in results.values {
            guard let latency = result.latencyMs else { continue }
            store.updateDevice(result.uid) { $0.latencyMs = latency }
        }
        phase = .idle
    }
}
