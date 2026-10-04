import CoreAudio
import Foundation

/// Second-order IIR section (transposed direct form II), RBJ cookbook coefficients.
struct Biquad {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    enum Kind { case lowpass, highpass }

    mutating func configure(_ kind: Kind, frequency: Double, sampleRate: Double) {
        let q = 1 / 2.0.squareRoot() // Butterworth; two in series make a Linkwitz-Riley 4th order slope
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        switch kind {
        case .lowpass:
            b0 = (1 - cosw) / 2 / a0
            b1 = (1 - cosw) / a0
            b2 = b0
        case .highpass:
            b0 = (1 + cosw) / 2 / a0
            b1 = -(1 + cosw) / a0
            b2 = b0
        }
        a1 = -2 * cosw / a0
        a2 = (1 - alpha) / a0
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Band-pass for one clip: LR4 high-pass at its lower edge, LR4 low-pass at its upper edge.
/// Edges at the ends of the audible range are left open.
final class ClipFilter {
    private var highpass = [Biquad](repeating: Biquad(), count: 4) // L1 L2 R1 R2
    private var lowpass = [Biquad](repeating: Biquad(), count: 4)
    private var useHighpass = false
    private var useLowpass = false
    private(set) var lower = 0.0
    private(set) var upper = 0.0

    func configure(lower: Double, upper: Double, sampleRate: Double) {
        guard lower != self.lower || upper != self.upper else { return }
        self.lower = lower
        self.upper = upper
        useHighpass = lower > FrequencyRange.min * 1.01
        useLowpass = upper < FrequencyRange.max / 1.01
        for i in 0..<4 {
            highpass[i].configure(.highpass, frequency: lower, sampleRate: sampleRate)
            lowpass[i].configure(.lowpass, frequency: upper, sampleRate: sampleRate)
        }
    }

    @inline(__always)
    func process(_ l: Float, _ r: Float) -> (Double, Double) {
        var left = Double(l), right = Double(r)
        if useHighpass {
            left = highpass[1].process(highpass[0].process(left))
            right = highpass[3].process(highpass[2].process(right))
        }
        if useLowpass {
            left = lowpass[1].process(lowpass[0].process(left))
            right = lowpass[3].process(lowpass[2].process(right))
        }
        return (left, right)
    }
}

/// Settings for one output, built on the main thread and handed to the audio thread.
struct DeviceSnapshot {
    struct ClipRange {
        let id: UUID
        let lower: Double
        let upper: Double
    }

    var mode: ChannelMode
    var gain: Float
    var delaySamples: Int
    var clips: [ClipRange]
    /// Fresh filters for any clip the audio thread hasn't seen yet (so it never allocates them itself).
    var spareFilters: [UUID: ClipFilter]

    init(mode: ChannelMode, gain: Float, delaySamples: Int, clips: [ClipRange]) {
        self.mode = mode
        self.gain = gain
        self.delaySamples = delaySamples
        self.clips = clips
        spareFilters = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, ClipFilter()) })
    }
}

/// Renders one output device. Owned by the audio thread once the session starts.
final class DeviceProgram {
    let uid: String
    let outputBuffers: Range<Int>
    let outputChannels: [Int]

    private var mode: ChannelMode = .both
    private var targetGain: Float = 0
    private var gain: Float = 0
    private var filters: [ClipFilter] = []
    private var filtersByID: [UUID: ClipFilter] = [:]
    private var delaySamples = 0
    private var delayL: [Float]
    private var delayR: [Float]
    private var delayIndex = 0
    static let maxDelay = 1 << 16

    init(uid: String, outputBuffers: Range<Int>, outputChannels: [Int]) {
        self.uid = uid
        self.outputBuffers = outputBuffers
        self.outputChannels = outputChannels
        delayL = Array(repeating: 0, count: Self.maxDelay)
        delayR = Array(repeating: 0, count: Self.maxDelay)
    }

    /// Called on the audio thread. Keeps filter state for clips that still exist, so dragging an edge doesn't click.
    func apply(_ snapshot: DeviceSnapshot?, sampleRate: Double) {
        guard let snapshot else {
            targetGain = 0
            return
        }
        mode = snapshot.mode
        targetGain = snapshot.gain
        delaySamples = min(max(snapshot.delaySamples, 0), Self.maxDelay - 1)
        var next: [UUID: ClipFilter] = [:]
        filters = snapshot.clips.compactMap { clip in
            guard let filter = filtersByID[clip.id] ?? snapshot.spareFilters[clip.id] else { return nil }
            filter.configure(lower: clip.lower, upper: clip.upper, sampleRate: sampleRate)
            next[clip.id] = filter
            return filter
        }
        filtersByID = next
    }

    /// Renders `frames` of input into this device's buffers in `output` (already zeroed).
    func render(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int,
                output: UnsafeMutableAudioBufferListPointer) {
        guard !outputBuffers.isEmpty, gain > 0 || targetGain > 0 else { return }
        let totalChannels = outputChannels.reduce(0, +)
        // Device channels 0 and 1 (may live in the same interleaved buffer or two separate buffers).
        let ch0 = locate(channel: 0)
        let ch1 = totalChannels > 1 ? locate(channel: 1) : nil
        let gainStep = (targetGain - gain) / Float(max(frames, 1))
        let delay = delaySamples

        for i in 0..<frames {
            var l = 0.0, r = 0.0
            for filter in filters {
                let (fl, fr) = filter.process(left[i], right[i])
                l += fl
                r += fr
            }
            var outL: Float, outR: Float
            switch mode {
            case .left: outL = Float(l); outR = Float(l)
            case .right: outL = Float(r); outR = Float(r)
            case .both: outL = Float(l); outR = Float(r)
            }
            gain += gainStep
            outL *= gain
            outR *= gain

            delayL[delayIndex] = outL
            delayR[delayIndex] = outR
            let readIndex = (delayIndex - delay + Self.maxDelay) & (Self.maxDelay - 1)
            outL = delayL[readIndex]
            outR = delayR[readIndex]
            delayIndex = (delayIndex + 1) & (Self.maxDelay - 1)

            if let ch1 {
                write(outL, at: ch0, frame: i, output)
                write(outR, at: ch1, frame: i, output)
            } else {
                write((outL + outR) * 0.5, at: ch0, frame: i, output)
            }
        }
        gain = targetGain
    }

    private func locate(channel: Int) -> (buffer: Int, offset: Int, stride: Int) {
        var remaining = channel
        for (i, count) in outputChannels.enumerated() {
            if remaining < count { return (outputBuffers.lowerBound + i, remaining, count) }
            remaining -= count
        }
        return (outputBuffers.lowerBound, 0, max(outputChannels.first ?? 1, 1))
    }

    @inline(__always)
    private func write(_ sample: Float, at slot: (buffer: Int, offset: Int, stride: Int), frame: Int,
                       _ output: UnsafeMutableAudioBufferListPointer) {
        guard slot.buffer < output.count, let data = output[slot.buffer].mData else { return }
        data.assumingMemoryBound(to: Float.self)[frame * slot.stride + slot.offset] = sample
    }
}

/// Renders all outputs for one session. The main thread publishes snapshots; the audio thread
/// picks them up at the start of the next buffer.
final class Router {
    let sampleRate: Double
    private let programs: [DeviceProgram]
    private let lock = NSLock()
    private var pending: [String: DeviceSnapshot]?

    init(programs: [DeviceProgram], sampleRate: Double) {
        self.programs = programs
        self.sampleRate = sampleRate
    }

    func publish(_ snapshots: [String: DeviceSnapshot]) {
        lock.lock()
        pending = snapshots
        lock.unlock()
    }

    func render(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int,
                output: UnsafeMutableAudioBufferListPointer) {
        if lock.try() {
            if let next = pending {
                pending = nil
                for program in programs { program.apply(next[program.uid], sampleRate: sampleRate) }
            }
            lock.unlock()
        }
        for program in programs {
            program.render(left: left, right: right, frames: frames, output: output)
        }
    }
}
