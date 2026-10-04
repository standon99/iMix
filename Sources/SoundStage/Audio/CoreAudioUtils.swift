import CoreAudio
import Foundation

/// Thin wrappers over AudioObjectGetPropertyData for the handful of properties SoundStage reads.
enum CoreAudioUtils {
    struct Failure: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "\(step) failed (\(status))" }
    }

    static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw Failure(step: step, status: status) }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func float64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var addr = address(selector)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        uint32(system, selector).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        objectList(system, kAudioHardwarePropertyDevices).first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// Channels per buffer, in the order the device presents its streams for the given scope.
    static func bufferChannelCounts(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let transport = uint32(device, kAudioDevicePropertyTransportType)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func supportsSampleRate(_ device: AudioDeviceID, _ rate: Double) -> Bool {
        var addr = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &ranges) == noErr else { return false }
        return ranges.contains { $0.mMinimum <= rate && rate <= $0.mMaximum }
    }

    /// Sets a device's sample rate and waits briefly for it to take effect.
    static func setSampleRate(_ device: AudioDeviceID, _ rate: Double) {
        guard float64(device, kAudioDevicePropertyNominalSampleRate) != rate, supportsSampleRate(device, rate) else { return }
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        for _ in 0..<50 where float64(device, kAudioDevicePropertyNominalSampleRate) != rate {
            usleep(10_000)
        }
    }

    // MARK: Processes

    /// Core Audio process objects whose bundle ID starts with `bundlePrefix` (an app plus its helpers).
    static func processObjects(bundlePrefix: String) -> [AudioObjectID] {
        objectList(system, kAudioHardwarePropertyProcessObjectList)
            .filter { string($0, kAudioProcessPropertyBundleID)?.hasPrefix(bundlePrefix) == true }
            .sorted()
    }

    /// SoundStage's own process object, so a whole-system tap can leave out what SoundStage itself plays
    /// (otherwise routing would capture its own output and feed back).
    static func ownProcessObject() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        (uint32(process, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
    }
}
