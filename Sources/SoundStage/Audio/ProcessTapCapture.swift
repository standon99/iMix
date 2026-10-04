import AudioToolbox
import CoreAudio
import Foundation

/// Captures audio from specific processes (or the whole system) with a Core Audio process tap,
/// and hands mono samples to a ring buffer. The tap is unmuted, so playback is unaffected.
final class ProcessTapCapture {
    enum CaptureError: LocalizedError {
        case coreAudio(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .coreAudio(let step, let status): "\(step) failed (\(status))"
            }
        }
    }

    private(set) var sampleRate: Double = 48_000
    private let ring: SampleRing
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "SoundStage.capture", qos: .userInteractive)
    private var scratch = [Float](repeating: 0, count: 8192)

    init(ring: SampleRing) {
        self.ring = ring
    }

    deinit { stop() }

    /// Empty `processes` captures all system audio.
    func start(processes: [AudioObjectID]) throws {
        let description = processes.isEmpty
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            : CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "SoundStage"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw CaptureError.coreAudio("Creating process tap", status) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw CaptureError.coreAudio("Reading tap format", status) }
        sampleRate = format.mSampleRate

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundStage Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw CaptureError.coreAudio("Creating capture device", status) }

        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.consume(input, nonInterleaved: nonInterleaved)
        }
        guard status == noErr else { throw CaptureError.coreAudio("Creating capture callback", status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw CaptureError.coreAudio("Starting capture", status) }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Mixes the tap's stereo input to mono and writes it to the ring.
    private func consume(_ input: UnsafePointer<AudioBufferList>, nonInterleaved: Bool) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let firstData = first.mData else { return }

        if nonInterleaved {
            let frames = min(Int(first.mDataByteSize) / MemoryLayout<Float>.size, scratch.count)
            let channels = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            let gain = 1 / Float(channels.count)
            scratch.withUnsafeMutableBufferPointer { out in
                for i in 0..<frames {
                    var sum: Float = 0
                    for channel in channels { sum += channel[i] }
                    out[i] = sum * gain
                }
                ring.write(out.baseAddress!, count: frames)
            }
        } else {
            let channels = max(Int(first.mNumberChannels), 1)
            let frames = min(Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels), scratch.count)
            let samples = firstData.assumingMemoryBound(to: Float.self)
            let gain = 1 / Float(channels)
            scratch.withUnsafeMutableBufferPointer { out in
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += samples[i * channels + c] }
                    out[i] = sum * gain
                }
                ring.write(out.baseAddress!, count: frames)
            }
        }
    }

    // MARK: Process lookup

    /// Core Audio process objects whose bundle ID starts with `bundlePrefix` (an app plus its helpers).
    static func processObjects(bundlePrefix: String) -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { bundleID(of: $0)?.hasPrefix(bundlePrefix) == true }.sorted()
    }

    static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func defaultOutputUID() throws -> String {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device)
        guard status == noErr else { throw CaptureError.coreAudio("Finding default output", status) }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw CaptureError.coreAudio("Reading output UID", status) }
        return uid.takeRetainedValue() as String
    }
}

/// Fixed-size mono sample history shared between the capture thread and the analyzer.
final class SampleRing {
    private var buffer: [Float]
    private var writeIndex = 0
    private let lock = NSLock()

    init(capacity: Int) {
        buffer = Array(repeating: 0, count: capacity)
    }

    func write(_ samples: UnsafePointer<Float>, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<count {
            buffer[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) % buffer.count
        }
    }

    /// Copies the most recent `destination.count` samples, oldest first.
    func readLatest(into destination: inout [Float]) {
        lock.lock()
        defer { lock.unlock() }
        let n = min(destination.count, buffer.count)
        var index = (writeIndex - n + buffer.count) % buffer.count
        for i in 0..<n {
            destination[i] = buffer[index]
            index = (index + 1) % buffer.count
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        for i in buffer.indices { buffer[i] = 0 }
    }
}
