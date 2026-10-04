import CoreAudio
import Foundation
import Observation

/// Owns the live audio session: taps all system audio (or just Spotify), feeds the spectrum, and when
/// routing is on, mutes that audio at the source and plays each clip through its output.
@Observable
final class AudioEngine {
    /// What gets captured and routed.
    enum CaptureMode: String, CaseIterable, Identifiable {
        case allAudio, spotify
        var id: String { rawValue }
        var label: String { self == .allAudio ? "All audio" : "Spotify" }
    }

    enum Source: Equatable {
        case starting
        case spotify
        case system
        case suspended
        case failed(String)
    }

    private(set) var source: Source = .starting
    private(set) var spotifyPlaying = false
    /// True when the captured audio is being muted and re-played through the clip outputs.
    private(set) var routingActive = false
    private(set) var routedOutputs: [String] = []

    var captureMode: CaptureMode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: "captureMode") ?? "") ?? .allAudio {
        didSet {
            UserDefaults.standard.set(captureMode.rawValue, forKey: "captureMode")
            reconcile()
        }
    }

    var routingEnabled: Bool = UserDefaults.standard.bool(forKey: "routingEnabled") {
        didSet {
            UserDefaults.standard.set(routingEnabled, forKey: "routingEnabled")
            reconcile()
        }
    }

    @ObservationIgnored let feed = LiveSpectrumFeed()
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var spotifyProcesses: [AudioObjectID] = []
    @ObservationIgnored private var ownProcess: AudioObjectID?
    @ObservationIgnored private var profile = Profile()
    @ObservationIgnored private var connected: [OutputDevice] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var suspended = false

    static let spotifyBundlePrefix = "com.spotify.client"

    func start() {
        guard timer == nil else { return }
        refreshSpotify()
        // Spotify can launch or quit at any time; re-check every couple of seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshSpotify()
        }
    }

    /// Called whenever clips, sticker settings or connected devices change.
    func update(profile: Profile, connected: [OutputDevice]) {
        self.profile = profile
        self.connected = connected
        reconcile()
    }

    /// Stops all audio so calibration can take over the devices.
    func suspend() {
        suspended = true
        session = nil
        routingActive = false
        source = .suspended
    }

    func resume() {
        suspended = false
        reconcile()
    }

    private func refreshSpotify() {
        let processes = CoreAudioUtils.processObjects(bundlePrefix: Self.spotifyBundlePrefix)
        let playing = processes.contains(where: CoreAudioUtils.isRunningOutput)
        if playing != spotifyPlaying { spotifyPlaying = playing }
        // SoundStage's own process object can appear only after it first touches audio.
        let own = CoreAudioUtils.ownProcessObject()
        if processes != spotifyProcesses || own != ownProcess {
            spotifyProcesses = processes
            ownProcess = own
            reconcile()
        }
    }

    // MARK: Session management

    /// Outputs that have at least one clip and are connected, wired devices first so one of them is the clock.
    private var desiredOutputs: [String] {
        let used = Set(profile.clips.map(\.deviceUID))
        return AggregateDevice.routingOrder(connected.map(\.uid).filter(used.contains))
    }

    private func reconcile() {
        guard !suspended else { return }
        let tapSpotify = captureMode == .spotify && !spotifyProcesses.isEmpty
        // A whole-system tap must leave SoundStage out, or routing would re-capture its own output.
        let canRoute = captureMode == .spotify ? tapSpotify : ownProcess != nil
        let routing = routingEnabled && canRoute
        let key = Session.Key(
            processes: tapSpotify ? spotifyProcesses : [],
            excluded: ownProcess.map { [$0] } ?? [],
            routing: routing,
            outputs: routing ? desiredOutputs : [])

        if let session, session.key == key {
            publishSnapshots()
            return
        }

        session = nil
        feed.ring.clear()
        do {
            let newSession = try Session(key: key, ring: feed.ring)
            session = newSession
            feed.sampleRate = newSession.sampleRate
            routingActive = routing
            routedOutputs = key.outputs
            source = tapSpotify ? .spotify : .system
            publishSnapshots()
        } catch {
            routingActive = false
            routedOutputs = []
            source = .failed(error.localizedDescription)
        }
    }

    private func publishSnapshots() {
        guard let session, let router = session.router else { return }
        let sampleRate = router.sampleRate

        let latencies = session.key.outputs.compactMap { profile.devices[$0]?.latencyMs }
        let slowest = latencies.max() ?? 0

        var snapshots: [String: DeviceSnapshot] = [:]
        for uid in session.key.outputs {
            guard let settings = profile.devices[uid] else { continue }
            let clips = profile.clips
                .filter { $0.deviceUID == uid }
                .map { DeviceSnapshot.ClipRange(id: $0.id, lower: $0.lower, upper: $0.upper) }
            // Squared so the slider feels closer to perceived loudness.
            let gain = settings.muted ? 0 : Float(settings.masterVolume * settings.masterVolume)
            let delayMs = settings.latencyMs.map { slowest - $0 } ?? 0
            snapshots[uid] = DeviceSnapshot(
                mode: settings.channel,
                gain: gain,
                delaySamples: Int((delayMs / 1000 * sampleRate).rounded()),
                clips: clips)
        }
        router.publish(snapshots)
    }
}

/// One running tap + aggregate device + IO callback. Torn down and rebuilt when the set of
/// devices or the tapped processes change; clip and sticker edits are pushed into its router live.
private final class Session {
    struct Key: Equatable {
        /// Empty = whole system.
        var processes: [AudioObjectID]
        var excluded: [AudioObjectID]
        var routing: Bool
        var outputs: [String]
    }

    let key: Key
    let router: Router?
    var sampleRate: Double { aggregate.sampleRate }

    private let tap: ProcessTap
    private let aggregate: AggregateDevice
    private let ring: SampleRing
    private let queue = DispatchQueue(label: "SoundStage.audio", qos: .userInteractive)
    private var left = [Float](repeating: 0, count: 8192)
    private var right = [Float](repeating: 0, count: 8192)
    private var mono = [Float](repeating: 0, count: 8192)

    init(key: Key, ring: SampleRing) throws {
        self.key = key
        self.ring = ring
        tap = try ProcessTap(processes: key.processes, excluding: key.excluded, muted: key.routing)

        var subDevices = key.outputs
        if subDevices.isEmpty {
            // Nothing to play through (spectrum only, or routing with no clips): just use the default output as the clock.
            guard let device = CoreAudioUtils.defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice),
                  let uid = CoreAudioUtils.string(device, kAudioDevicePropertyDeviceUID) else {
                throw CoreAudioUtils.Failure(step: "Finding default output", status: -1)
            }
            subDevices = [uid]
        }
        aggregate = try AggregateDevice(name: "SoundStage", subDeviceUIDs: subDevices, tapUUID: tap.uuid)

        if key.routing {
            let programs = aggregate.subs
                .filter { key.outputs.contains($0.uid) }
                .map { DeviceProgram(uid: $0.uid, outputBuffers: $0.outputBuffers, outputChannels: $0.outputChannels) }
            router = Router(programs: programs, sampleRate: aggregate.sampleRate)
        } else {
            router = nil
        }

        try aggregate.start(queue: queue) { [unowned self] _, input, _, output, _ in
            self.process(input: input, output: output)
        }
    }

    deinit {
        aggregate.stop()
    }

    private func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let tapBuffers = aggregate.tapInputBuffers
        guard !tapBuffers.isEmpty, tapBuffers.upperBound <= ins.count,
              let firstData = ins[tapBuffers.lowerBound].mData else { return }
        let first = ins[tapBuffers.lowerBound]
        let channels = max(Int(first.mNumberChannels), 1)
        let frames = min(Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels), left.count)
        let samples = firstData.assumingMemoryBound(to: Float.self)

        if channels >= 2 {
            for i in 0..<frames {
                left[i] = samples[i * channels]
                right[i] = samples[i * channels + 1]
            }
        } else if tapBuffers.count >= 2, let secondData = ins[tapBuffers.lowerBound + 1].mData {
            let second = secondData.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                left[i] = samples[i]
                right[i] = second[i]
            }
        } else {
            for i in 0..<frames {
                left[i] = samples[i]
                right[i] = samples[i]
            }
        }

        for i in 0..<frames { mono[i] = (left[i] + right[i]) * 0.5 }
        mono.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: frames) }

        guard let router else { return }
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                router.render(left: l.baseAddress!, right: r.baseAddress!, frames: frames, output: outs)
            }
        }
    }
}
