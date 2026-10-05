import Accelerate
import Foundation

/// One frame for the spectrum view: log-spaced points from 20 Hz to 20 kHz, in dB.
struct SpectrumFrame {
    var levels: [Float]
    var peaks: [Float]
}

protocol SpectrumFeed: AnyObject {
    func frame(at time: TimeInterval) -> SpectrumFrame
}

enum SpectrumScale {
    /// The spectrum redraws 5 times a second: plenty to follow the music, at a fraction of the CPU of 60.
    static let refreshInterval: TimeInterval = 1.0 / 5
    static let minDB: Float = -100
    static let maxDB: Float = 0
}

/// Runs an FFT over the latest captured samples each time the view asks for a frame.
final class LiveSpectrumFeed: SpectrumFeed {
    let ring = SampleRing(capacity: 1 << 15)
    /// Set by the capture before samples arrive.
    var sampleRate: Double = 48_000 {
        didSet { if sampleRate != oldValue { buildMapping() } }
    }

    private let log2n: vDSP_Length = 13
    private let fftSize = 1 << 13
    private let pointCount = 720
    private let setup: FFTSetup
    private let window: [Float]
    private var samples: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var binDB: [Float]

    /// For each display point: the FFT bin range it covers (or a fractional bin to interpolate at).
    private var mapping: [(lo: Int, hi: Int, fractional: Float)] = []
    private var levels: [Float]
    private var peaks: [Float]
    private var lastTime: TimeInterval?

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        samples = Array(repeating: 0, count: fftSize)
        real = Array(repeating: 0, count: fftSize / 2)
        imag = Array(repeating: 0, count: fftSize / 2)
        binDB = Array(repeating: SpectrumScale.minDB, count: fftSize / 2)
        levels = Array(repeating: SpectrumScale.minDB, count: pointCount)
        peaks = Array(repeating: SpectrumScale.minDB, count: pointCount)
        buildMapping()
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func frame(at time: TimeInterval) -> SpectrumFrame {
        let dt = Float(min(max(time - (lastTime ?? time), 0), 0.5))
        lastTime = time

        computeBins()

        for j in 0..<pointCount {
            let m = mapping[j]
            var value: Float
            if m.hi > m.lo {
                value = binDB[m.lo]
                for k in (m.lo + 1)...m.hi { value = max(value, binDB[k]) }
            } else {
                let a = binDB[m.lo], b = binDB[min(m.lo + 1, binDB.count - 1)]
                value = a + (b - a) * m.fractional
            }
            value = min(max(value, SpectrumScale.minDB), SpectrumScale.maxDB)

            // Instant attack, quick release keeps detail without flicker.
            levels[j] = value > levels[j] ? value : levels[j] + (value - levels[j]) * min(1, 18 * dt)
            // Peak hold falls slowly.
            peaks[j] = max(levels[j], peaks[j] - 12 * dt)
        }
        return SpectrumFrame(levels: levels, peaks: peaks)
    }

    private func computeBins() {
        ring.readLatest(into: &samples)
        vDSP.multiply(samples, window, result: &samples)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                samples.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                binDB.withUnsafeMutableBufferPointer { out in
                    vDSP_zvmags(&split, 1, out.baseAddress!, 1, vDSP_Length(fftSize / 2))
                }
            }
        }
        binDB[0] = 0 // packed DC / Nyquist

        // zrip returns 2x the DFT; with a Hann window a full-scale sine reads 0 dB after this scaling.
        let scale = 2 / Float(fftSize)
        vDSP.add(1e-20, binDB, result: &binDB)
        vDSP.convert(power: binDB, toDecibels: &binDB, zeroReference: 1)
        vDSP.add(20 * log10(scale), binDB, result: &binDB)
    }

    private func buildMapping() {
        let binHz = sampleRate / Double(fftSize)
        let maxBin = fftSize / 2 - 1
        mapping = (0..<pointCount).map { j in
            let p0 = (Double(j) - 0.5) / Double(pointCount - 1)
            let p1 = (Double(j) + 0.5) / Double(pointCount - 1)
            let center = FrequencyRange.frequency(at: Double(j) / Double(pointCount - 1)) / binHz
            let lo = Int((FrequencyRange.frequency(at: p0) / binHz).rounded(.up))
            let hi = Int((FrequencyRange.frequency(at: p1) / binHz).rounded(.down))
            if hi >= lo, lo >= 1 {
                return (min(lo, maxBin), min(hi, maxBin), 0)
            }
            let base = min(max(Int(center), 1), maxBin - 1)
            return (base, base, Float(center - Double(base)))
        }
    }
}
