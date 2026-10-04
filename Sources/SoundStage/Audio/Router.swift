import CoreAudio
import Foundation

/// Second-order IIR section (transposed direct form II), RBJ cookbook coefficients.
struct Biquad {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    enum Kind {
        case lowpass
        case highpass
        case peaking(gainDB: Double, q: Double)
    }

    mutating func configure(_ kind: Kind, frequency: Double, sampleRate: Double) {
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let cosw = cos(w0)
        switch kind {
        case .lowpass, .highpass:
            let q = 1 / 2.0.squareRoot() // Butterworth; two in series make a Linkwitz-Riley 4th order slope
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha
            if case .lowpass = kind {
                b0 = (1 - cosw) / 2 / a0
                b1 = (1 - cosw) / a0
            } else {
                b0 = (1 + cosw) / 2 / a0
                b1 = -(1 + cosw) / a0
            }
            b2 = b0
            a1 = -2 * cosw / a0
            a2 = (1 - alpha) / a0
        case .peaking(let gainDB, let q):
            let a = pow(10, gainDB / 40)
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha / a
            b0 = (1 + alpha * a) / a0
            b1 = -2 * cosw / a0
            b2 = (1 - alpha * a) / a0
            a1 = -2 * cosw / a0
            a2 = (1 - alpha / a) / a0
        }
    }

    /// Gain of this section at `frequency`, in dB.
    func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return 10 * log10((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30))
    }

    mutating func reset() {
        z1 = 0
        z2 = 0
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Settings for the graphic EQ, built on the main thread.
struct EQSnapshot {
    var enabled: Bool
    var gains: [Double]
    /// Negative gain applied before the bands so boosts don't clip.
    var preampDB: Double

    init(_ settings: EQSettings) {
        enabled = settings.enabled
        gains = GraphicEQ.filterGains(for: settings.gains)
        preampDB = settings.enabled ? -max(0, GraphicEQ.peakResponseDB(gains: gains)) : 0
    }
}

/// 31 peaking filters, one per 1/3 octave, applied to both channels in place.
final class GraphicEQ {
    private var left = [Biquad](repeating: Biquad(), count: EQBands.centers.count)
    private var right = [Biquad](repeating: Biquad(), count: EQBands.centers.count)
    private var gains = [Double](repeating: 0, count: EQBands.centers.count)
    /// Indices of bands that aren't at 0 dB; only these run.
    private var active: [Int] = []
    private var preamp: Double = 1

    /// Called on the audio thread.
    func apply(_ snapshot: EQSnapshot, sampleRate: Double) {
        var nowActive: [Int] = []
        for i in EQBands.centers.indices {
            let gain = snapshot.enabled ? snapshot.gains[i] : 0
            if abs(gain) < 0.05 { continue }
            if !active.contains(i) {
                left[i].reset()
                right[i].reset()
            }
            if gain != gains[i] || !active.contains(i) {
                let kind = Biquad.Kind.peaking(gainDB: gain, q: EQBands.q)
                left[i].configure(kind, frequency: EQBands.centers[i], sampleRate: sampleRate)
                right[i].configure(kind, frequency: EQBands.centers[i], sampleRate: sampleRate)
            }
            gains[i] = gain
            nowActive.append(i)
        }
        active = nowActive
        preamp = pow(10, snapshot.preampDB / 20)
    }

    func process(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, frames: Int) {
        guard !active.isEmpty || preamp != 1 else { return }
        for n in 0..<frames {
            var x = Double(l[n]) * preamp, y = Double(r[n]) * preamp
            for i in active {
                x = left[i].process(x)
                y = right[i].process(y)
            }
            l[n] = Float(x)
            r[n] = Float(y)
        }
    }

    /// Combined response of all bands at `frequency`, in dB (for the UI and headroom).
    static func responseDB(gains: [Double], at frequency: Double, sampleRate: Double = 48_000) -> Double {
        var total = 0.0
        for (i, gain) in gains.enumerated() where abs(gain) >= 0.05 {
            var band = Biquad()
            band.configure(.peaking(gainDB: gain, q: EQBands.q), frequency: EQBands.centers[i], sampleRate: sampleRate)
            total += band.magnitudeDB(at: frequency, sampleRate: sampleRate)
        }
        return total
    }

    /// Neighbouring bands overlap, so setting each filter to its fader value overshoots (+5 dB on
    /// every fader gives ripples up to ~+8 dB). Instead, solve for filter gains whose combined
    /// response hits each fader value at its centre frequency.
    static func filterGains(for targets: [Double]) -> [Double] {
        guard targets.contains(where: { abs($0) >= 0.05 }) else { return targets }
        var gains = solve(interaction, targets)
        // The bands aren't perfectly linear in dB; one correction pass gets within ~0.1 dB.
        let achieved = EQBands.centers.map { responseDB(gains: gains, at: $0) }
        let error = zip(targets, achieved).map { $0 - $1 }
        gains = zip(gains, solve(interaction, error)).map { $0 + $1 }
        return gains.map { min(max($0, -24), 24) }
    }

    /// interaction[i][j]: dB at band i's centre per dB of band j's gain.
    private static let interaction: [[Double]] = {
        let probe = 12.0
        return EQBands.centers.map { center in
            EQBands.centers.indices.map { j in
                var gains = [Double](repeating: 0, count: EQBands.centers.count)
                gains[j] = probe
                return responseDB(gains: gains, at: center) / probe
            }
        }
    }()

    /// Gaussian elimination with partial pivoting.
    private static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double] {
        let n = rhs.count
        var a = matrix
        var b = rhs
        for col in 0..<n {
            let pivot = (col..<n).max { abs(a[$0][col]) < abs(a[$1][col]) }!
            a.swapAt(col, pivot)
            b.swapAt(col, pivot)
            guard abs(a[col][col]) > 1e-12 else { continue }
            for row in (col + 1)..<n {
                let f = a[row][col] / a[col][col]
                if f == 0 { continue }
                for k in col..<n { a[row][k] -= f * a[col][k] }
                b[row] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = abs(a[row][row]) > 1e-12 ? sum / a[row][row] : 0
        }
        return x
    }

    static func peakResponseDB(gains: [Double]) -> Double {
        guard gains.contains(where: { $0 > 0.05 }) else { return 0 }
        return (0..<240).map { i in
            responseDB(gains: gains, at: FrequencyRange.frequency(at: Double(i) / 239))
        }.max() ?? 0
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
    private let eq = GraphicEQ()
    private let lock = NSLock()
    private var pending: [String: DeviceSnapshot]?
    private var pendingEQ: EQSnapshot?

    init(programs: [DeviceProgram], sampleRate: Double) {
        self.programs = programs
        self.sampleRate = sampleRate
    }

    func publish(_ snapshots: [String: DeviceSnapshot], eq: EQSnapshot) {
        lock.lock()
        pending = snapshots
        pendingEQ = eq
        lock.unlock()
    }

    /// Applies the EQ to `left`/`right` in place, then renders every output.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                output: UnsafeMutableAudioBufferListPointer) {
        if lock.try() {
            if let next = pending {
                pending = nil
                for program in programs { program.apply(next[program.uid], sampleRate: sampleRate) }
            }
            if let nextEQ = pendingEQ {
                pendingEQ = nil
                eq.apply(nextEQ, sampleRate: sampleRate)
            }
            lock.unlock()
        }
        eq.process(left: left, right: right, frames: frames)
        for program in programs {
            program.render(left: left, right: right, frames: frames, output: output)
        }
    }
}
