import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Observation

/// A running app the user can choose to capture, with the Core Audio processes that play its sound.
struct AudioApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let processes: [AudioObjectID]
    let playing: Bool
    var id: String { bundleID }
}

/// Owns the live audio session: taps all system audio (or chosen apps), feeds the spectrum, and when
/// routing is on, mutes that audio at the source and plays it through the timeline's outputs.
@Observable
final class AudioEngine {
    enum Source: Equatable {
        case starting
        case allAudio
        case apps
        /// Specific apps are selected but none of them has audio running yet.
        case waitingForApps
        case suspended
        case failed(String)
    }

    private(set) var source: Source = .starting
    /// True when the captured audio is being muted and re-played through the clip outputs.
    private(set) var routingActive = false
    private(set) var routedOutputs: [String] = []
    /// Regular apps that are running, playing ones first.
    private(set) var runningApps: [AudioApp] = []

    /// Bundle IDs to capture; empty means all audio.
    var selectedApps: [String] = UserDefaults.standard.stringArray(forKey: "selectedApps") ?? [] {
        didSet {
            UserDefaults.standard.set(selectedApps, forKey: "selectedApps")
            reconcile()
        }
    }

    var routingEnabled: Bool = UserDefaults.standard.bool(forKey: "routingEnabled") {
        didSet {
            UserDefaults.standard.set(routingEnabled, forKey: "routingEnabled")
            reconcile()
        }
    }

    // MARK: Master volume
    // Follows the volume of the Mac's current output device, which is what the keyboard volume keys
    // change. That device already gets the change in hardware; every other output gets it in software.

    private(set) var masterVolume: Double = 1
    private(set) var masterMuted = false
    /// False when the current output (e.g. a Multi-Output Device) has no volume the keys can change.
    private(set) var masterFollowsKeys = false
    @ObservationIgnored private var appVolume: Double = UserDefaults.standard.object(forKey: "appVolume") as? Double ?? 1

    func setMasterVolume(_ value: Double) {
        let v = min(max(value, 0), 1)
        if masterFollowsKeys, let device = CoreAudioUtils.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) {
            MasterVolume.set(Float32(v), on: device)
        } else {
            appVolume = v
            UserDefaults.standard.set(v, forKey: "appVolume")
        }
        masterVolume = v
        publishSnapshots()
    }

    @ObservationIgnored let feed = LiveSpectrumFeed()
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var ownProcess: AudioObjectID?
    @ObservationIgnored private var profile = Profile()
    @ObservationIgnored private var connected: [OutputDevice] = []
    @ObservationIgnored private var appTimer: Timer?
    @ObservationIgnored private var volumeTimer: Timer?
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var defaultOutputUID: String?

    func start() {
        guard appTimer == nil else { return }
        // Leave the user's devices as we found them.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.session = nil
            SampleRateChanges.restoreAll()
        }
        refreshApps()
        refreshVolume()
        // Apps start and stop playing at any time; re-check every couple of seconds.
        appTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshApps()
        }
        // Volume keys: poll often enough to feel immediate.
        volumeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshVolume()
        }
    }

    /// Called whenever clips, sticker settings, the EQ or connected devices change.
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

    func toggleApp(_ bundleID: String) {
        if let i = selectedApps.firstIndex(of: bundleID) {
            selectedApps.remove(at: i)
        } else {
            selectedApps.append(bundleID)
        }
    }

    // MARK: Polling

    /// Writes audio-thread health to Application Support/iMix/diagnostics.json and resets the peaks.
    private func writeDiagnostics() {
        guard let session else { return }
        let s = session.stats
        session.stats.maxLoad = 0
        let info: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "sampleRate": session.sampleRate,
            "framesPerCallback": s.framesPerCallback,
            "callbacks": s.callbacks,
            "maxLoadPercent": (s.maxLoad * 1000).rounded() / 10,
            "heavyCallbacks": s.heavyCallbacks,
            "discontinuities": s.discontinuities,
            "outputs": session.key.outputs,
            "routing": session.key.routing,
        ]
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iMix/diagnostics.json")
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    private func refreshApps() {
        writeDiagnostics()
        let apps = AppDiscovery.runningApps()
        if apps != runningApps { runningApps = apps }

        // iMix's own process object can appear only after it first touches audio.
        let own = CoreAudioUtils.ownProcessObject()
        if own != ownProcess { ownProcess = own }
        reconcile()
    }

    private func refreshVolume() {
        guard let device = CoreAudioUtils.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return }
        let uid = CoreAudioUtils.string(device, kAudioDevicePropertyDeviceUID)
        let followsKeys = MasterVolume.isAvailable(on: device)
        let volume = followsKeys ? Double(MasterVolume.get(on: device) ?? 1) : appVolume
        let muted = followsKeys && MasterVolume.isMuted(device)

        var changed = false
        if uid != defaultOutputUID { defaultOutputUID = uid; changed = true }
        if followsKeys != masterFollowsKeys { masterFollowsKeys = followsKeys; changed = true }
        if abs(volume - masterVolume) > 0.001 { masterVolume = volume; changed = true }
        if muted != masterMuted { masterMuted = muted; changed = true }
        if changed { publishSnapshots() }
    }

    // MARK: Session management

    /// Outputs that have at least one clip and are connected, wired devices first so one of them is the clock.
    private var desiredOutputs: [String] {
        let used = Set(profile.clips.map(\.deviceUID))
        return AggregateDevice.routingOrder(connected.map(\.uid).filter(used.contains))
    }

    private func reconcile() {
        guard !suspended else { return }
        let selectedProcesses = runningApps
            .filter { selectedApps.contains($0.bundleID) }
            .flatMap(\.processes)
            .sorted()
        let wantsApps = !selectedApps.isEmpty
        let tapApps = wantsApps && !selectedProcesses.isEmpty
        // A whole-system tap must leave iMix out, or routing would re-capture its own output.
        let canRoute = wantsApps ? tapApps : ownProcess != nil
        let routing = routingEnabled && canRoute
        let key = Session.Key(
            processes: tapApps ? selectedProcesses : [],
            excluded: ownProcess.map { [$0] } ?? [],
            routing: routing,
            outputs: routing ? desiredOutputs : [])

        let newSource: Source = tapApps ? .apps : (wantsApps ? .waitingForApps : .allAudio)
        if let session, session.key == key {
            if source != newSource { source = newSource }
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
            source = newSource
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
        // Squared so sliders feel closer to perceived loudness.
        let master = masterMuted ? 0 : Float(masterVolume * masterVolume)

        var snapshots: [String: DeviceSnapshot] = [:]
        for uid in session.key.outputs {
            guard let settings = profile.devices[uid] else { continue }
            let clips = profile.clips
                .filter { $0.deviceUID == uid }
                .map { DeviceSnapshot.ClipRange(id: $0.id, lower: $0.lower, upper: $0.upper) }
            // The current output device already gets the master volume in hardware.
            let masterGain: Float = (masterFollowsKeys && uid == defaultOutputUID) ? 1 : master
            let gain = settings.muted ? 0 : Float(settings.masterVolume * settings.masterVolume) * masterGain
            let delayMs = settings.latencyMs.map { slowest - $0 } ?? 0
            snapshots[uid] = DeviceSnapshot(
                mode: settings.channel,
                gain: gain,
                delaySamples: Int((delayMs / 1000 * sampleRate).rounded()),
                clips: clips)
        }
        router.publish(snapshots, eq: EQSnapshot(profile.eq))
    }
}

/// The "virtual main volume" the keyboard volume keys control.
enum MasterVolume {
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    static func isAvailable(on device: AudioDeviceID) -> Bool {
        guard AudioHardwareServiceHasProperty(device, &volumeAddress) else { return false }
        var settable: DarwinBoolean = false
        return AudioHardwareServiceIsPropertySettable(device, &volumeAddress, &settable) == noErr && settable.boolValue
    }

    static func get(on device: AudioDeviceID) -> Float32? {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioHardwareServiceGetPropertyData(device, &volumeAddress, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func set(_ value: Float32, on device: AudioDeviceID) {
        var v = value
        AudioHardwareServiceSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool {
        (CoreAudioUtils.uint32(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) ?? 0) != 0
    }
}

/// Matches Core Audio process objects to the regular apps that own them.
enum AppDiscovery {
    static func runningApps() -> [AudioApp] {
        let ownBundle = Bundle.main.bundleIdentifier
        let regular = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != ownBundle
        }
        let safari = regular.first { $0.bundleIdentifier == "com.apple.Safari" }

        var processes: [String: [AudioObjectID]] = [:]
        var playing: Set<String> = []
        for object in CoreAudioUtils.objectList(CoreAudioUtils.system, kAudioHardwarePropertyProcessObjectList) {
            let bundleID = CoreAudioUtils.string(object, kAudioProcessPropertyBundleID) ?? ""
            let pid = pid_t(bitPattern: CoreAudioUtils.uint32(object, kAudioProcessPropertyPID) ?? 0)
            // Same process, else a helper whose bundle ID extends the app's (Chrome, Electron apps),
            // else Safari's shared WebKit media process.
            let owner = regular.first { $0.processIdentifier == pid }
                ?? regular.filter { bundleID.hasPrefix($0.bundleIdentifier! + ".") }
                    .max { $0.bundleIdentifier!.count < $1.bundleIdentifier!.count }
                ?? (bundleID.hasPrefix("com.apple.WebKit") ? safari : nil)
            guard let owner, let ownerID = owner.bundleIdentifier else { continue }
            processes[ownerID, default: []].append(object)
            if CoreAudioUtils.isRunningOutput(object) { playing.insert(ownerID) }
        }

        return regular.map { app in
            let id = app.bundleIdentifier!
            return AudioApp(bundleID: id, name: app.localizedName ?? id,
                            processes: (processes[id] ?? []).sorted(), playing: playing.contains(id))
        }
        .sorted { a, b in
            if a.playing != b.playing { return a.playing }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
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

    /// Audio-thread health, read (racily, it's only diagnostics) by the engine.
    struct Stats {
        var callbacks = 0
        var framesPerCallback = 0
        /// Worst processing time as a fraction of the buffer's duration, since the last reset.
        var maxLoad = 0.0
        /// Callbacks that used more than 70% of their time.
        var heavyCallbacks = 0
        /// Times the output timeline jumped, i.e. the device skipped or repeated audio.
        var discontinuities = 0
    }
    var stats = Stats()
    private var expectedSampleTime: Double?
    var sampleRate: Double { aggregate.sampleRate }

    private let tap: ProcessTap
    private let aggregate: AggregateDevice
    private let ring: SampleRing
    private let queue = DispatchQueue(label: "iMix.audio", qos: .userInteractive)
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
        let bufferFrames: UInt32?
        if key.routing {
            bufferFrames = AggregateDevice.prepareForBluetooth(subDevices)
        } else {
            SampleRateChanges.restoreAll()
            bufferFrames = nil
        }
        aggregate = try AggregateDevice(name: "iMix", subDeviceUIDs: subDevices, tapUUID: tap.uuid)
        if let bufferFrames { aggregate.setBufferFrameSize(bufferFrames) }

        if key.routing {
            let programs = aggregate.subs
                .filter { key.outputs.contains($0.uid) }
                .map { DeviceProgram(uid: $0.uid, outputBuffers: $0.outputBuffers, outputChannels: $0.outputChannels) }
            router = Router(programs: programs, sampleRate: aggregate.sampleRate)
        } else {
            router = nil
        }

        try aggregate.start(queue: queue) { [unowned self] _, input, _, output, outTime in
            let start = mach_absolute_time()
            let frames = self.process(input: input, output: output)
            self.record(start: start, frames: frames, sampleTime: outTime.pointee.mSampleTime)
        }
    }

    deinit {
        aggregate.stop()
    }

    private static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    private func record(start: UInt64, frames: Int, sampleTime: Double) {
        guard frames > 0 else { return }
        let seconds = Double(mach_absolute_time() - start) / Self.ticksPerSecond
        let load = seconds / (Double(frames) / aggregate.sampleRate)
        stats.callbacks += 1
        stats.framesPerCallback = frames
        stats.maxLoad = max(stats.maxLoad, load)
        if load > 0.7 { stats.heavyCallbacks += 1 }
        if let expected = expectedSampleTime, abs(sampleTime - expected) > 1 { stats.discontinuities += 1 }
        expectedSampleTime = sampleTime + Double(frames)
    }

    /// Returns the number of frames processed.
    @discardableResult
    private func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) -> Int {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let tapBuffers = aggregate.tapInputBuffers
        guard !tapBuffers.isEmpty, tapBuffers.upperBound <= ins.count,
              let firstData = ins[tapBuffers.lowerBound].mData else { return 0 }
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

        // Routing applies the EQ in place first, so the spectrum shows what's actually playing.
        if let router {
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    router.render(left: l.baseAddress!, right: r.baseAddress!, frames: frames, output: outs)
                }
            }
        }

        for i in 0..<frames { mono[i] = (left[i] + right[i]) * 0.5 }
        mono.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: frames) }
        return frames
    }
}
