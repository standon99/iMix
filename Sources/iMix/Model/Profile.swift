import Foundation

/// Which side of the stereo signal an output plays.
enum ChannelMode: String, Codable, CaseIterable, Identifiable {
    case left, right, both
    var id: String { rawValue }
    var shortLabel: String {
        switch self {
        case .left: "L"
        case .right: "R"
        case .both: "L+R"
        }
    }
}

/// A frequency range assigned to one output, shown as a resizable bar in the lanes.
struct Clip: Codable, Identifiable, Hashable {
    var id = UUID()
    var deviceUID: String
    var lower: Double
    var upper: Double
    /// Lane row, 0 = top. Clips in the same row never overlap.
    var row: Int

    func overlaps(_ other: Clip) -> Bool {
        lower < other.upper && other.lower < upper
    }

    func touchesOrOverlaps(_ other: Clip) -> Bool {
        lower <= other.upper * 1.001 && other.lower <= upper * 1.001
    }
}

/// Per-output settings that apply to all of its clips.
struct DeviceSettings: Codable, Hashable {
    var name: String
    var nickname: String?
    var transport: Transport
    var colorIndex: Int
    var channel: ChannelMode = .both
    var masterVolume: Double = 1.0
    var muted = false
    /// Measured by calibration; nil until calibrated.
    var latencyMs: Double?
    /// Flip the signal for a speaker wired or built the opposite way to the others, so shared bass
    /// adds up instead of cancelling. Optional so older profiles still decode.
    var invertPolarity: Bool?

    var displayName: String { nickname?.isEmpty == false ? nickname! : name }
}

enum Transport: String, Codable {
    case builtIn, bluetooth, usb, hdmi, virtual, other
}

struct Profile: Codable, Equatable {
    var clips: [Clip] = []
    var devices: [String: DeviceSettings] = [:]
    var eq = EQSettings()

    init() {}

    // Decoded field by field so profiles saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        devices = try c.decodeIfPresent([String: DeviceSettings].self, forKey: .devices) ?? [:]
        eq = try c.decodeIfPresent(EQSettings.self, forKey: .eq) ?? EQSettings()
    }
}

/// The 31-band graphic equalizer, applied to everything before it's split across outputs.
struct EQSettings: Codable, Equatable {
    var enabled = true
    var gains: [Double] = Array(repeating: 0, count: EQBands.centers.count)
}

enum EQBands {
    /// ISO 1/3-octave centre frequencies.
    static let centers: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
        1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000,
    ]
    static let labels: [String] = [
        "20", "25", "31", "40", "50", "63", "80", "100", "125", "160", "200", "250", "315", "400", "500", "630", "800",
        "1k", "1.2k", "1.6k", "2k", "2.5k", "3.1k", "4k", "5k", "6.3k", "8k", "10k", "12k", "16k", "20k",
    ]
    static let range: ClosedRange<Double> = -12...12
    /// Bandwidth in octaves: wider than the 1/3-octave spacing so neighbouring bands blend smoothly.
    /// The overlap is undone by solving for the filter gains (see `GraphicEQ.filterGains`).
    static let bandwidth = 0.5

    struct Region {
        let name: String
        let bands: ClosedRange<Int>
        let color: UInt32
    }

    static let regions: [Region] = [
        Region(name: "Sub-bass", bands: 0...4, color: 0x8B5CF6),
        Region(name: "Bass", bands: 5...11, color: 0x6366F1),
        Region(name: "Low mids", bands: 12...14, color: 0x0EA5E9),
        Region(name: "Mids", bands: 15...20, color: 0x14B8A6),
        Region(name: "Upper mids", bands: 21...23, color: 0x84CC16),
        Region(name: "Presence", bands: 24...25, color: 0xF59E0B),
        Region(name: "Brilliance", bands: 26...30, color: 0xF43F5E),
    ]

    static func region(ofBand index: Int) -> Region {
        regions.first { $0.bands.contains(index) } ?? regions[0]
    }

    struct Preset {
        let name: String
        let gains: [Double]

        init(_ name: String, _ curve: (Double) -> Double) {
            self.name = name
            gains = EQBands.centers.map { (curve($0) * 2).rounded() / 2 }
        }
    }

    /// 0 at `from`, 1 at `to`, linear in octaves, clamped.
    private static func ramp(_ hz: Double, from: Double, to: Double) -> Double {
        min(max(log2(hz / from) / log2(to / from), 0), 1)
    }

    static let presets: [Preset] = [
        Preset("Flat") { _ in 0 },
        Preset("Bass Boost") { 6 * ramp($0, from: 250, to: 60) },
        Preset("Bass Reducer") { -6 * ramp($0, from: 250, to: 60) },
        Preset("Treble Boost") { 6 * ramp($0, from: 2000, to: 10000) },
        Preset("Vocal") { hz in
            3.5 * exp(-pow(log2(hz / 2000), 2) / 1.5) - 3 * ramp(hz, from: 150, to: 50)
        },
        Preset("Loudness") { 5 * ramp($0, from: 200, to: 40) + 4 * ramp($0, from: 4000, to: 14000) },
    ]
}

enum FrequencyRange {
    static let min = 20.0
    static let max = 20_000.0
    /// Narrowest clip allowed (~1/6 octave).
    static let minWidthRatio = 1.12

    /// Position 0...1 on a log axis.
    static func position(of hz: Double) -> Double {
        log10(hz / min) / log10(max / min)
    }

    static func frequency(at position: Double) -> Double {
        min * pow(max / min, Swift.min(Swift.max(position, 0), 1))
    }

    static func x(of hz: Double, width: CGFloat) -> CGFloat {
        CGFloat(position(of: hz)) * width
    }

    static func frequency(atX x: CGFloat, width: CGFloat) -> Double {
        frequency(at: Double(x / width))
    }

    static func format(_ hz: Double) -> String {
        if hz >= 1000 {
            let k = hz / 1000
            return k >= 10 ? String(format: "%.0f kHz", k) : String(format: "%.1f kHz", k)
        }
        return String(format: "%.0f Hz", hz)
    }
}
