import Accelerate
import AVFoundation
import CoreAudio
import Foundation

struct CalibrationResult: Identifiable, Hashable {
    let uid: String
    /// Median sweep arrival time at the mic, or nil if no sweep was heard.
    let latencyMs: Double?
    /// Standard deviation across runs.
    let jitterMs: Double?
    /// Loudness at the mic, relative to full scale (only meaningful compared between outputs).
    let levelDB: Double?
    let inverted: Bool
    let detections: Int
    let runs: Int
    var id: String { uid }
}

/// Plays a log sweep through each output in turn, records the microphone on the same clock,
/// and finds each sweep's arrival by cross-correlation.
final class CalibrationRun {
    static let runsPerDevice = 5
    static let sweepSeconds = 0.5
    static let gapSeconds = 0.9
    static let warmupSeconds = 0.6
    static let maxLatencySeconds = 0.8
    static let amplitude: Float = 0.25

    let outputUIDs: [String]
    let micUID: String

    private let aggregate: AggregateDevice
    private let sweep: [Float]
    private let starts: [[Int]] // [device][run], in aggregate frames from the session origin
    private let totalFrames: Int
    private let micLayout: AggregateDevice.SubLayout
    private let outputLayouts: [AggregateDevice.SubLayout]
    private let queue = DispatchQueue(label: "iMix.calibration", qos: .userInteractive)

    // Written on the audio thread.
    private var recording: [Float]
    private var origin: Double?
    private var recordedUpTo = 0
    private var finished = false

    var sampleRate: Double { aggregate.sampleRate }

    init(outputUIDs: [String], micUID: String) throws {
        self.outputUIDs = outputUIDs
        self.micUID = micUID

        // Same outputs, order and clock as the router, with the mic added last, so the latencies
        // measured here are the ones the router will actually see.
        let ordered = AggregateDevice.routingOrder(outputUIDs)
        let subDevices = ordered.contains(micUID) ? ordered : ordered + [micUID]
        let bufferFrames = AggregateDevice.prepareForBluetooth(ordered)
        let aggregate = try AggregateDevice(name: "iMix Calibration", subDeviceUIDs: subDevices, tapUUID: nil)
        if let bufferFrames { aggregate.setBufferFrameSize(bufferFrames) }
        self.aggregate = aggregate
        let sr = aggregate.sampleRate

        guard let mic = aggregate.subs.first(where: { $0.uid == micUID }), !mic.inputBuffers.isEmpty else {
            throw CoreAudioUtils.Failure(step: "Opening microphone", status: -1)
        }
        micLayout = mic
        outputLayouts = outputUIDs.compactMap { uid in aggregate.subs.first { $0.uid == uid } }

        sweep = Self.makeSweep(sampleRate: sr)
        let period = Int(((Self.sweepSeconds + Self.gapSeconds) * sr).rounded())
        let warmup = Int((Self.warmupSeconds * sr).rounded())
        starts = outputUIDs.indices.map { d in
            (0..<Self.runsPerDevice).map { r in warmup + (d * Self.runsPerDevice + r) * period }
        }
        totalFrames = warmup + outputUIDs.count * Self.runsPerDevice * period + Int(Self.maxLatencySeconds * sr)
        recording = Array(repeating: 0, count: totalFrames + sweep.count)
    }

    static func totalSeconds(_ devices: Int) -> Double {
        warmupSeconds + Double(devices * runsPerDevice) * (sweepSeconds + gapSeconds) + maxLatencySeconds
    }

    /// Runs the measurement. `progress` is called on the main actor with 0...1.
    func perform(progress: @MainActor @escaping (Double) -> Void) async throws -> [CalibrationResult] {
        try aggregate.start(queue: queue) { [unowned self] _, input, inTime, output, outTime in
            self.process(input: input, inTime: inTime.pointee, output: output, outTime: outTime.pointee)
        }
        defer { aggregate.stop() }

        let deadline = Date().addingTimeInterval(Self.totalSeconds(outputUIDs.count) + 5)
        while !queue.sync(execute: { finished }) {
            if Task.isCancelled { throw CancellationError() }
            if Date() > deadline {
                throw CoreAudioUtils.Failure(step: "Recording from the microphone (timed out)", status: -1)
            }
            let done = queue.sync { Double(recordedUpTo) / Double(totalFrames) }
            await progress(min(done, 1))
            try await Task.sleep(for: .milliseconds(100))
        }
        aggregate.stop()
        await progress(1)

        let recording = self.recording
        return outputUIDs.indices.map { analyze(device: $0, recording: recording) }
    }

    // MARK: Audio thread

    private func process(input: UnsafePointer<AudioBufferList>, inTime: AudioTimeStamp,
                         output: UnsafeMutablePointer<AudioBufferList>, outTime: AudioTimeStamp) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard !finished else { return }
        if origin == nil { origin = outTime.mSampleTime }
        guard let origin else { return }

        // Output: write any sweep that overlaps this buffer to its device's first two channels.
        let outStart = Int(outTime.mSampleTime - origin)
        if let firstOut = outs.first {
            let firstChannels = max(Int(firstOut.mNumberChannels), 1)
            let frames = Int(firstOut.mDataByteSize) / (MemoryLayout<Float>.size * firstChannels)
            for (d, layout) in outputLayouts.enumerated() {
                for start in starts[d] where start < outStart + frames && start + sweep.count > outStart {
                    let from = max(start, outStart)
                    let to = min(start + sweep.count, outStart + frames)
                    for t in from..<to {
                        let sample = sweep[t - start]
                        write(sample, channel: 0, frame: t - outStart, layout: layout, outs)
                        write(sample, channel: 1, frame: t - outStart, layout: layout, outs)
                    }
                }
            }
        }

        // Input: store the mic's first channel on the same timeline.
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let micBuffer = micLayout.inputBuffers.lowerBound
        guard micBuffer < ins.count, let data = ins[micBuffer].mData else { return }
        let stride = max(Int(ins[micBuffer].mNumberChannels), 1)
        let frames = Int(ins[micBuffer].mDataByteSize) / (MemoryLayout<Float>.size * stride)
        let samples = data.assumingMemoryBound(to: Float.self)
        let inStart = Int(inTime.mSampleTime - origin)
        for i in 0..<frames {
            let t = inStart + i
            if t >= 0 && t < recording.count { recording[t] = samples[i * stride] }
        }
        recordedUpTo = max(recordedUpTo, inStart + frames)
        if recordedUpTo >= totalFrames { finished = true }
    }

    private func write(_ sample: Float, channel: Int, frame: Int, layout: AggregateDevice.SubLayout,
                       _ outs: UnsafeMutableAudioBufferListPointer) {
        var remaining = channel
        for (i, count) in layout.outputChannels.enumerated() {
            if remaining < count {
                let b = layout.outputBuffers.lowerBound + i
                guard b < outs.count, let data = outs[b].mData else { return }
                data.assumingMemoryBound(to: Float.self)[frame * count + remaining] = sample
                return
            }
            remaining -= count
        }
    }

    // MARK: Analysis

    private func analyze(device d: Int, recording: [Float]) -> CalibrationResult {
        let sr = sampleRate
        let maxLag = Int(Self.maxLatencySeconds * sr)
        var lags: [Double] = []
        var levels: [Double] = []
        var invertedVotes = 0

        let correlator = Correlator(length: sweep.count + maxLag + sweep.count)
        for start in starts[d] {
            let end = min(start + sweep.count + maxLag, recording.count)
            guard end > start else { continue }
            let segment = Array(recording[start..<end])
            let r = correlator.correlate(segment, with: sweep, maxLag: maxLag)
            guard let hit = Self.firstArrival(in: r) else { continue }
            lags.append(hit.lag)
            levels.append(hit.level)
            if hit.negative { invertedVotes += 1 }
        }

        guard !lags.isEmpty else {
            return CalibrationResult(uid: outputUIDs[d], latencyMs: nil, jitterMs: nil, levelDB: nil,
                                     inverted: false, detections: 0, runs: Self.runsPerDevice)
        }
        let ms = lags.map { $0 / sr * 1000 }.sorted()
        let median = ms[ms.count / 2]
        let mean = ms.reduce(0, +) / Double(ms.count)
        let sd = (ms.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(ms.count)).squareRoot()
        let level = levels.sorted()[levels.count / 2]

        return CalibrationResult(
            uid: outputUIDs[d], latencyMs: median, jitterMs: sd,
            levelDB: 20 * log10(max(level, 1e-9)),
            inverted: invertedVotes * 2 > lags.count,
            detections: lags.count, runs: Self.runsPerDevice)
    }

    /// The direct sound: the first strong peak (reflections arrive later and are often weaker).
    private static func firstArrival(in r: [Float]) -> (lag: Double, level: Double, negative: Bool)? {
        let magnitudes = r.map(abs)
        guard let maxValue = magnitudes.max(), maxValue > 0 else { return nil }
        let median = magnitudes.sorted()[magnitudes.count / 2]
        // Require the peak to stand well clear of the noise (≈ 20 dB).
        guard maxValue > median * 10 else { return nil }

        let threshold = maxValue * 0.5
        var index = magnitudes.firstIndex { $0 >= threshold }!
        while index + 1 < magnitudes.count && magnitudes[index + 1] > magnitudes[index] { index += 1 }

        // Parabolic interpolation for sub-sample timing.
        var lag = Double(index)
        if index > 0 && index + 1 < magnitudes.count {
            let a = Double(magnitudes[index - 1]), b = Double(magnitudes[index]), c = Double(magnitudes[index + 1])
            let denom = a - 2 * b + c
            if denom != 0 { lag += 0.5 * (a - c) / denom }
        }
        return (lag, Double(magnitudes[index]), r[index] < 0)
    }

    private static func makeSweep(sampleRate: Double) -> [Float] {
        let count = Int(sweepSeconds * sampleRate)
        let f1 = 150.0, f2 = 12_000.0
        let k = log(f2 / f1)
        let fade = Int(0.01 * sampleRate)
        var sweep = (0..<count).map { n -> Float in
            let t = Double(n) / sampleRate
            let phase = 2 * Double.pi * f1 * sweepSeconds / k * (exp(t / sweepSeconds * k) - 1)
            return Float(sin(phase))
        }
        for i in 0..<fade {
            let g = Float(i) / Float(fade)
            sweep[i] *= g
            sweep[count - 1 - i] *= g
        }
        return sweep.map { $0 * amplitude }
    }
}

/// FFT cross-correlation: r[lag] = Σ x[t + lag] · y[t], for lag in 0..<maxLag.
private final class Correlator {
    private let log2n: vDSP_Length
    private let n: Int
    private let setup: FFTSetup

    init(length: Int) {
        var log2n: vDSP_Length = 1
        while (1 << log2n) < length { log2n += 1 }
        self.log2n = log2n
        n = 1 << Int(log2n)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func correlate(_ x: [Float], with y: [Float], maxLag: Int) -> [Float] {
        var xr = [Float](repeating: 0, count: n / 2), xi = xr
        var yr = xr, yi = xr
        forward(x, &xr, &xi)
        forward(y, &yr, &yi)

        // X · conj(Y). Bin 0 packs DC (real) and Nyquist (imag), both real-valued.
        let dc = xr[0] * yr[0], nyquist = xi[0] * yi[0]
        for k in 1..<(n / 2) {
            let re = xr[k] * yr[k] + xi[k] * yi[k]
            let im = xi[k] * yr[k] - xr[k] * yi[k]
            xr[k] = re
            xi[k] = im
        }
        xr[0] = dc
        xi[0] = nyquist

        var out = [Float](repeating: 0, count: n)
        xr.withUnsafeMutableBufferPointer { rp in
            xi.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(n / 2))
                }
            }
        }
        // Undo the transform's scaling and the sweep's energy so peaks are comparable between outputs.
        let energy = y.reduce(0) { $0 + $1 * $1 }
        let scale = 1 / (4 * Float(n) * max(energy, 1e-9))
        return Array(out[0..<min(maxLag, n)]).map { $0 * scale }
    }

    private func forward(_ signal: [Float], _ real: inout [Float], _ imag: inout [Float]) {
        var padded = [Float](repeating: 0, count: n)
        padded.replaceSubrange(0..<min(signal.count, n), with: signal.prefix(n))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                padded.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
    }
}

enum MicrophoneAccess {
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    struct Mic: Identifiable, Hashable {
        let uid: String
        let name: String
        let transport: Transport
        var id: String { uid }
    }

    /// Every input device except aggregates and virtual devices.
    static func inputDevices() -> [Mic] {
        CoreAudioUtils.objectList(CoreAudioUtils.system, kAudioHardwarePropertyDevices).compactMap { device in
            guard !CoreAudioUtils.bufferChannelCounts(device, scope: kAudioObjectPropertyScopeInput).isEmpty,
                  let uid = CoreAudioUtils.string(device, kAudioDevicePropertyDeviceUID),
                  let name = CoreAudioUtils.string(device, kAudioObjectPropertyName) else { return nil }
            let transport: Transport
            switch CoreAudioUtils.uint32(device, kAudioDevicePropertyTransportType) {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transport = .bluetooth
            case kAudioDeviceTransportTypeBuiltIn: transport = .builtIn
            case kAudioDeviceTransportTypeUSB: transport = .usb
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
                return nil
            default: transport = .other
            }
            return Mic(uid: uid, name: name, transport: transport)
        }
    }

    /// The Mac's built-in mic if present, then USB, then anything that isn't Bluetooth. A Bluetooth
    /// speaker's mic would add its own delay and force the speaker into low-quality call mode.
    static func preferredMic(from mics: [Mic]) -> Mic? {
        mics.first { $0.transport == .builtIn }
            ?? mics.first { $0.transport == .usb }
            ?? mics.first { $0.transport != .bluetooth }
            ?? mics.first
    }
}

/// `open iMix.app --args --calibrate-to <file.json>` runs a calibration on every connected output
/// at launch and writes the results, for testing without clicking through Settings.
enum CalibrationCommandLine {
    @MainActor
    static func runIfRequested(engine: AudioEngine, outputs: [OutputDevice]) {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--calibrate-to"), flag + 1 < args.count else { return }
        let path = args[flag + 1]
        Task { @MainActor in
            var report: [String: Any] = [:]
            guard await MicrophoneAccess.request(),
                  let mic = MicrophoneAccess.preferredMic(from: MicrophoneAccess.inputDevices()) else {
                report["error"] = "no microphone access"
                write(report, to: path)
                return
            }
            engine.suspend()
            defer { engine.resume() }
            do {
                try await Task.sleep(for: .milliseconds(300))
                var uids = outputs.map(\.uid)
                if let o = args.firstIndex(of: "--outputs"), o + 1 < args.count {
                    let wanted = args[o + 1].split(separator: ",").map(String.init)
                    uids = uids.filter { uid in wanted.contains { uid.localizedCaseInsensitiveContains($0) } }
                }
                let run = try CalibrationRun(outputUIDs: uids, micUID: mic.uid)
                let results = try await run.perform { _ in }
                report["sampleRate"] = run.sampleRate
                report["mic"] = mic.name
                report["results"] = results.map { r -> [String: Any] in
                    ["uid": r.uid, "latencyMs": r.latencyMs ?? -1, "jitterMs": r.jitterMs ?? -1,
                     "levelDB": r.levelDB ?? -999, "inverted": r.inverted, "detections": r.detections]
                }
            } catch {
                report["error"] = error.localizedDescription
            }
            write(report, to: path)
        }
    }

    private static func write(_ report: [String: Any], to path: String) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
