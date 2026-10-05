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

    // MARK: Volume
    // Each routed speaker's sticker *is* that speaker's own volume slider (the one Control Center
    // shows), one to one. The master is iMix's own: it turns the signal down in software, so it never
    // limits how far a speaker's own volume can go. While routing, iMix catches the keyboard volume
    // keys (with Accessibility access) and uses them for the master.

    private(set) var masterVolume: Double = UserDefaults.standard.object(forKey: "masterVolume") as? Double ?? 1
    private(set) var masterMuted = false
    /// The user's choice; the keys are only caught while routing and with Accessibility access.
    var volumeKeysEnabled: Bool = UserDefaults.standard.object(forKey: "volumeKeysEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(volumeKeysEnabled, forKey: "volumeKeysEnabled") }
    }
    private(set) var volumeKeysAllowed = VolumeKeyTap.isTrusted
    /// Called when a speaker's volume is changed outside iMix, with its new sticker value.
    @ObservationIgnored var onDeviceVolumeChanged: ((String, Double) -> Void)?
    /// Speaker volume iMix last wrote (as read back), to tell our changes from outside ones.
    @ObservationIgnored private var lastSetVolume: [String: Double] = [:]
    @ObservationIgnored private let volumeKeys = VolumeKeyTap()

    func setMasterVolume(_ value: Double) {
        masterVolume = min(max(value, 0), 1)
        UserDefaults.standard.set(masterVolume, forKey: "masterVolume")
        if masterMuted && masterVolume > 0 { masterMuted = false }
        publishSnapshots()
    }

    func toggleMasterMute() {
        masterMuted.toggle()
        publishSnapshots()
    }

    /// Asks macOS for Accessibility access (needed to catch the volume keys).
    func requestVolumeKeyAccess() {
        VolumeKeyTap.requestTrust()
    }

    private func handleVolumeKey(_ key: VolumeKeyTap.Key, isDown: Bool, fine: Bool) -> Bool {
        guard volumeKeysEnabled, routingActive else { return false }
        guard isDown else { return true }
        let step = fine ? 1.0 / 64 : 1.0 / 16
        switch key {
        case .up: setMasterVolume(((masterVolume + step) / step).rounded() * step)
        case .down: setMasterVolume(((masterVolume - step) / step).rounded() * step)
        case .mute: toggleMasterMute()
        }
        VolumeHUD.shared.show(volume: masterVolume, muted: masterMuted)
        return true
    }

    /// Routed speakers whose volume iMix can set directly.
    private var hardwareVolumeOutputs: [(uid: String, device: AudioDeviceID)] {
        guard let session, session.key.routing else { return [] }
        return session.key.outputs.compactMap { uid in
            guard let device = CoreAudioUtils.deviceID(forUID: uid), MasterVolume.isAvailable(on: device) else { return nil }
            return (uid, device)
        }
    }

    /// When routing starts, take each speaker's current volume as its sticker value, so nothing
    /// suddenly gets louder.
    private func adoptSpeakerVolumes() {
        lastSetVolume = [:]
        for (uid, device) in hardwareVolumeOutputs {
            guard let hw = MasterVolume.get(on: device).map(Double.init) else { continue }
            lastSetVolume[uid] = hw
            if abs(hw - (profile.devices[uid]?.masterVolume ?? 1)) > 0.01 {
                profile.devices[uid]?.masterVolume = hw
                onDeviceVolumeChanged?(uid, hw)
            }
        }
    }

    @ObservationIgnored let feed = LiveSpectrumFeed()
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var ownProcess: AudioObjectID?
    @ObservationIgnored private var profile = Profile()
    @ObservationIgnored private var connected: [OutputDevice] = []
    @ObservationIgnored private var appTimer: Timer?
    @ObservationIgnored private var volumeTimer: Timer?
    @ObservationIgnored private var suspended = false
    /// Sessions are only built once `start()` has looked up apps and iMix's own process and the UI has
    /// passed in the profile and connected devices, so launch doesn't build a throwaway session first.
    @ObservationIgnored private var started = false
    @ObservationIgnored private var hasDevices = false

    func start() {
        guard appTimer == nil else { return }
        started = true
        volumeKeys.handler = { [weak self] key, isDown, fine in
            self?.handleVolumeKey(key, isDown: isDown, fine: fine) ?? false
        }
        volumeKeys.start()
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
        hasDevices = true
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

    @ObservationIgnored private var sessionLog: [String] = []

    private func describeChange(from old: Session.Key?, to new: Session.Key) -> String {
        guard let old else { return "first session" }
        var parts: [String] = []
        if old.processes != new.processes { parts.append("processes \(old.processes) -> \(new.processes)") }
        if old.excluded != new.excluded { parts.append("excluded \(old.excluded) -> \(new.excluded)") }
        if old.routing != new.routing { parts.append("routing \(old.routing) -> \(new.routing)") }
        if old.outputs != new.outputs { parts.append("outputs \(old.outputs) -> \(new.outputs)") }
        return parts.isEmpty ? "same key (restart)" : parts.joined(separator: "; ")
    }

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
            "sessionLog": sessionLog,
            "resamplingQuality": session.resamplingQuality,
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
        // Accessibility can be granted at any time in System Settings.
        let allowed = VolumeKeyTap.isTrusted
        if allowed != volumeKeysAllowed {
            volumeKeysAllowed = allowed
            if allowed { volumeKeys.start() }
        }

        // Speaker volumes changed outside iMix (Control Center): move the matching sticker.
        for (uid, device) in hardwareVolumeOutputs {
            guard let hw = MasterVolume.get(on: device).map(Double.init),
                  let last = lastSetVolume[uid], abs(hw - last) > 0.01 else { continue }
            lastSetVolume[uid] = hw
            profile.devices[uid]?.masterVolume = hw
            onDeviceVolumeChanged?(uid, hw)
        }
    }

    // MARK: Session management

    /// Outputs that have at least one clip and are connected, wired devices first so one of them is the clock.
    private var desiredOutputs: [String] {
        let used = Set(profile.clips.map(\.deviceUID))
        return AggregateDevice.routingOrder(connected.map(\.uid).filter(used.contains))
    }

    private func reconcile() {
        guard started, hasDevices, !suspended else { return }
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

        let reason = describeChange(from: session?.key, to: key)
        session = nil
        feed.ring.clear()
        do {
            let newSession = try Session(key: key, ring: feed.ring)
            sessionLog.append("\(ISO8601DateFormatter().string(from: Date())) \(reason)")
            if sessionLog.count > 10 { sessionLog.removeFirst() }
            session = newSession
            feed.sampleRate = newSession.sampleRate
            routingActive = routing
            routedOutputs = key.outputs
            source = newSource
            adoptSpeakerVolumes()
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
        let hardware = Dictionary(uniqueKeysWithValues: hardwareVolumeOutputs.map { ($0.uid, $0.device) })

        var snapshots: [String: DeviceSnapshot] = [:]
        for uid in session.key.outputs {
            guard let settings = profile.devices[uid] else { continue }
            let clips = profile.clips
                .filter { $0.deviceUID == uid }
                .map { DeviceSnapshot.ClipRange(id: $0.id, lower: $0.lower, upper: $0.upper) }
            // Squared so the sliders feel like volume knobs.
            let master = Float(masterVolume * masterVolume)
            var gain: Float
            if let device = hardware[uid] {
                // The sticker is the speaker's own volume, one to one; the master is applied to the signal.
                let sticker = settings.masterVolume
                if abs((lastSetVolume[uid] ?? -1) - sticker) > 0.002 {
                    MasterVolume.set(Float32(sticker), on: device)
                    lastSetVolume[uid] = MasterVolume.get(on: device).map(Double.init) ?? sticker
                }
                gain = master
            } else {
                // No volume control on the speaker: the sticker is applied to the signal too.
                gain = master * Float(settings.masterVolume * settings.masterVolume)
            }
            if settings.muted || masterMuted { gain = 0 }
            if settings.invertPolarity == true { gain = -gain }
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
    var resamplingQuality: [UInt32] { aggregate.resamplingQuality }

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
        let bufferFrames = key.routing ? AggregateDevice.bufferFrames(for: subDevices) : nil
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

        try aggregate.start(queue: queue, inputBuffers: Set(aggregate.tapInputBuffers)) { [unowned self] _, input, _, output, outTime in
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
