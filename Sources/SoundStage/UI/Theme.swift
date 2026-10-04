import SwiftUI

enum Theme {
    static let background = Color(hex: 0x0D0E11)
    static let panel = Color(hex: 0x15171C)
    static let panelRaised = Color(hex: 0x1D2027)
    static let stroke = Color(hex: 0x2A2E37)
    static let grid = Color.white.opacity(0.06)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)
    static let accent = Color(hex: 0x5EEAD4)
    static let danger = Color(hex: 0xF87171)
    static let uncovered = Color(hex: 0xEF4444)

    /// Device colours, assigned in the order devices are first seen.
    static let devicePalette: [Color] = [
        Color(hex: 0x2DD4BF), // teal
        Color(hex: 0xF59E0B), // amber
        Color(hex: 0xA78BFA), // violet
        Color(hex: 0xF472B6), // pink
        Color(hex: 0x38BDF8), // sky
        Color(hex: 0xA3E635), // lime
        Color(hex: 0xFB923C), // orange
    ]

    static func color(forDevice index: Int) -> Color {
        devicePalette[index % devicePalette.count]
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

extension Transport {
    var symbol: String {
        switch self {
        case .builtIn: "laptopcomputer"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        case .usb: "cable.connector"
        case .hdmi: "tv"
        case .virtual: "waveform"
        case .other: "hifispeaker"
        }
    }

    var label: String {
        switch self {
        case .builtIn: "Built-in"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .hdmi: "HDMI"
        case .virtual: "Virtual"
        case .other: "Other"
        }
    }
}

/// Drag payload for an output sticker, encoded as a plain string for SwiftUI's built-in String transfer.
enum DragPayload {
    static let devicePrefix = "device:"

    static func device(_ uid: String) -> String { devicePrefix + uid }

    static func deviceUID(from string: String) -> String? {
        string.hasPrefix(devicePrefix) ? String(string.dropFirst(devicePrefix.count)) : nil
    }
}
