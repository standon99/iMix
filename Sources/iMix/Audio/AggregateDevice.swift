import AudioToolbox
import CoreAudio
import Foundation

/// A private aggregate device combining real devices (and optionally a process tap) on one clock,
/// so a single IO callback can read the tap / mic and write every output.
final class AggregateDevice {
    /// Where one sub-device's channels sit in the aggregate's buffer lists.
    struct SubLayout {
        let uid: String
        let inputBuffers: Range<Int>
        let outputBuffers: Range<Int>
        let inputChannels: [Int]
        let outputChannels: [Int]
    }

    let id: AudioDeviceID
    let sampleRate: Double
    let subs: [SubLayout]
    /// Input buffers coming from the tap (after all sub-device inputs).
    let tapInputBuffers: Range<Int>

    private var procID: AudioDeviceIOProcID?

    /// Bluetooth speakers crackle if the aggregate has to resample them while also chasing their
    /// jittery clock, so a Bluetooth output is made the aggregate's clock (see `routingOrder`) and the
    /// steadier wired outputs take the drift correction instead. That needs no change to anyone's
    /// device settings. A larger IO buffer gives the correction more slack.
    /// Returns the IO buffer size to use. Shared by routing and calibration so their latencies match.
    static func bufferFrames(for uids: [String]) -> UInt32? {
        uids.compactMap(CoreAudioUtils.deviceID(forUID:)).contains(where: CoreAudioUtils.isBluetooth) ? 1024 : nil
    }

    func setBufferFrameSize(_ frames: UInt32) {
        var addr = CoreAudioUtils.address(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// Sub-device order shared by routing and calibration, so both build the same aggregate:
    /// Bluetooth first (the first device is the clock), then wired, ties by UID.
    static func routingOrder(_ uids: [String]) -> [String] {
        func isBluetooth(_ uid: String) -> Bool {
            CoreAudioUtils.deviceID(forUID: uid).map(CoreAudioUtils.isBluetooth) ?? false
        }
        return uids.sorted { a, b in
            let ab = isBluetooth(a), bb = isBluetooth(b)
            return ab != bb ? ab : a < b
        }
    }

    /// `subDeviceUIDs[0]` is the clock; the rest get drift compensation.
    init(name: String, subDeviceUIDs: [String], tapUUID: UUID?) throws {
        precondition(!subDeviceUIDs.isEmpty)
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: "iMix-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: subDeviceUIDs[0],
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subDeviceUIDs.enumerated().map { index, uid in
                [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: index == 0 ? 0 : 1] as [String: Any]
            },
        ]
        if let tapUUID {
            description[kAudioAggregateDeviceTapAutoStartKey] = true
            description[kAudioAggregateDeviceTapListKey] = [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]]
        }

        var newID = AudioDeviceID(0)
        try CoreAudioUtils.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &newID), "Creating aggregate device")
        id = newID
        sampleRate = CoreAudioUtils.float64(newID, kAudioDevicePropertyNominalSampleRate) ?? 48_000

        // Sub-device buffers appear in sub-device order; tap inputs follow them.
        var subs: [SubLayout] = []
        var inCursor = 0, outCursor = 0
        for uid in subDeviceUIDs {
            let device = CoreAudioUtils.deviceID(forUID: uid) ?? 0
            let ins = CoreAudioUtils.bufferChannelCounts(device, scope: kAudioObjectPropertyScopeInput)
            let outs = CoreAudioUtils.bufferChannelCounts(device, scope: kAudioObjectPropertyScopeOutput)
            subs.append(SubLayout(uid: uid,
                                  inputBuffers: inCursor..<(inCursor + ins.count),
                                  outputBuffers: outCursor..<(outCursor + outs.count),
                                  inputChannels: ins, outputChannels: outs))
            inCursor += ins.count
            outCursor += outs.count
        }
        self.subs = subs

        let aggregateIns = CoreAudioUtils.bufferChannelCounts(newID, scope: kAudioObjectPropertyScopeInput)
        let aggregateOuts = CoreAudioUtils.bufferChannelCounts(newID, scope: kAudioObjectPropertyScopeOutput)
        tapInputBuffers = inCursor..<max(aggregateIns.count, inCursor)

        guard aggregateOuts.count == outCursor, aggregateIns.count >= inCursor else {
            AudioHardwareDestroyAggregateDevice(newID)
            throw CoreAudioUtils.Failure(step: "Matching aggregate channel layout (in \(aggregateIns.count)/\(inCursor), out \(aggregateOuts.count)/\(outCursor))", status: -1)
        }
    }

    /// `inputBuffers` are the input buffers the callback actually reads; every other input stream is
    /// switched off. Otherwise opening an output device that also has a mic (a Bluetooth speaker,
    /// AirPods) starts its mic and drops it into low-quality call mode.
    func start(queue: DispatchQueue, inputBuffers: Set<Int>, _ block: @escaping AudioDeviceIOBlock) throws {
        try CoreAudioUtils.check(AudioDeviceCreateIOProcIDWithBlock(&procID, id, queue, block), "Creating IO callback")
        disableInputStreams(except: inputBuffers)
        try CoreAudioUtils.check(AudioDeviceStart(id, procID), "Starting audio device")
    }

    private func disableInputStreams(except used: Set<Int>) {
        guard let procID else { return }
        var addr = CoreAudioUtils.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return }
        let count = Int(usage.pointee.mNumberStreams)
        let flags = raw.advanced(by: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!)
            .assumingMemoryBound(to: UInt32.self)
        for stream in 0..<count {
            flags[stream] = used.contains(stream) ? 1 : 0
        }
        AudioObjectSetPropertyData(id, &addr, 0, nil, size, raw)
    }

    func stop() {
        if let procID {
            AudioDeviceStop(id, procID)
            AudioDeviceDestroyIOProcID(id, procID)
        }
        procID = nil
    }

    deinit {
        stop()
        AudioHardwareDestroyAggregateDevice(id)
    }
}

/// A Core Audio process tap on a set of processes, or on the whole system.
final class ProcessTap {
    let id: AudioObjectID
    let uuid: UUID

    /// Empty `processes` taps the whole system except `excluding`.
    init(processes: [AudioObjectID], excluding: [AudioObjectID], muted: Bool) throws {
        let description = processes.isEmpty
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: excluding)
            : CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "iMix"
        description.isPrivate = true
        // Muted only while iMix is reading it, so audio comes back if the app quits or crashes.
        description.muteBehavior = muted ? .mutedWhenTapped : .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioUtils.check(AudioHardwareCreateProcessTap(description, &tapID), "Creating process tap")
        id = tapID
        uuid = description.uuid
    }

    deinit {
        AudioHardwareDestroyProcessTap(id)
    }
}
