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

    var displayName: String { nickname?.isEmpty == false ? nickname! : name }
}

enum Transport: String, Codable {
    case builtIn, bluetooth, usb, hdmi, virtual, other
}

struct Profile: Codable {
    var clips: [Clip] = []
    var devices: [String: DeviceSettings] = [:]
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
