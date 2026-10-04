import Foundation
import Observation

/// Owns the current profile, applies edits, and persists it to disk.
@Observable
final class ProfileStore {
    private(set) var profile: Profile {
        didSet { scheduleSave() }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundStage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("profile.json")

        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(Profile.self, from: data) {
            profile = loaded
        } else {
            profile = Profile()
        }
    }

    // MARK: Clips

    var rowCount: Int {
        (profile.clips.map(\.row).max() ?? -1) + 1
    }

    func clip(_ id: UUID) -> Clip? {
        profile.clips.first { $0.id == id }
    }

    /// Drops a new one-octave clip centred on `hz`, in `preferredRow` if it's free, otherwise the first free row.
    @discardableResult
    func addClip(deviceUID: String, centeredOn hz: Double, preferredRow: Int? = nil) -> UUID {
        let center = FrequencyRange.position(of: hz)
        let halfWidth = FrequencyRange.position(of: FrequencyRange.min * 2) / 2
        let start = min(max(center - halfWidth, 0), 1 - 2 * halfWidth)
        var clip = Clip(
            deviceUID: deviceUID,
            lower: FrequencyRange.frequency(at: start),
            upper: FrequencyRange.frequency(at: start + 2 * halfWidth),
            row: preferredRow ?? 0)
        clip.row = freeRow(for: clip, startingAt: clip.row)
        profile.clips.append(clip)
        finalize(clip.id)
        return clip.id
    }

    func updateClip(_ id: UUID, _ change: (inout Clip) -> Void) {
        guard let i = profile.clips.firstIndex(where: { $0.id == id }) else { return }
        change(&profile.clips[i])
    }

    /// Lowest/highest frequency the given edge can reach without overlapping a neighbour in the same row.
    func resizeLimits(for id: UUID) -> (lowerMin: Double, upperMax: Double) {
        guard let clip = clip(id) else { return (FrequencyRange.min, FrequencyRange.max) }
        let rowmates = profile.clips.filter { $0.row == clip.row && $0.id != id }
        let lowerMin = rowmates.filter { $0.upper <= clip.lower * 1.001 }.map(\.upper).max() ?? FrequencyRange.min
        let upperMax = rowmates.filter { $0.lower >= clip.upper / 1.001 }.map(\.lower).min() ?? FrequencyRange.max
        return (lowerMin, upperMax)
    }

    /// Called when a drag ends: merges with same-output clips it touches, moves it off any
    /// clip it now overlaps, and removes empty rows.
    func finalize(_ id: UUID) {
        guard var clip = clip(id) else { return }

        var merged = true
        while merged {
            merged = false
            if let other = profile.clips.first(where: {
                $0.id != clip.id && $0.deviceUID == clip.deviceUID && $0.touchesOrOverlaps(clip)
            }) {
                clip.lower = min(clip.lower, other.lower)
                clip.upper = max(clip.upper, other.upper)
                clip.row = min(clip.row, other.row)
                profile.clips.removeAll { $0.id == other.id }
                merged = true
            }
        }

        clip.row = freeRow(for: clip, startingAt: clip.row)
        updateClip(id) { $0 = clip }
        compactRows()
    }

    func removeClip(_ id: UUID) {
        profile.clips.removeAll { $0.id == id }
        compactRows()
    }

    /// Frequency ranges no clip covers.
    var uncoveredRanges: [ClosedRange<Double>] {
        var gaps: [ClosedRange<Double>] = []
        var cursor = FrequencyRange.min
        for clip in profile.clips.sorted(by: { $0.lower < $1.lower }) {
            if clip.lower > cursor * 1.001 { gaps.append(cursor...clip.lower) }
            cursor = max(cursor, clip.upper)
        }
        if cursor < FrequencyRange.max / 1.001 { gaps.append(cursor...FrequencyRange.max) }
        return gaps
    }

    private func freeRow(for clip: Clip, startingAt preferred: Int) -> Int {
        func isFree(_ row: Int) -> Bool {
            !profile.clips.contains { $0.id != clip.id && $0.row == row && $0.overlaps(clip) }
        }
        if isFree(preferred) { return preferred }
        var row = 0
        while !isFree(row) { row += 1 }
        return row
    }

    private func compactRows() {
        let used = Set(profile.clips.map(\.row)).sorted()
        let remap = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($1, $0) })
        for i in profile.clips.indices {
            let newRow = remap[profile.clips[i].row]!
            if profile.clips[i].row != newRow { profile.clips[i].row = newRow }
        }
    }

    // MARK: Devices

    /// Records newly seen devices so they keep a stable colour and settings while disconnected.
    func register(_ devices: [OutputDevice]) {
        for device in devices {
            if var existing = profile.devices[device.uid] {
                guard existing.name != device.name || existing.transport != device.transport else { continue }
                existing.name = device.name
                existing.transport = device.transport
                profile.devices[device.uid] = existing
            } else {
                let nextColor = (profile.devices.values.map(\.colorIndex).max() ?? -1) + 1
                profile.devices[device.uid] = DeviceSettings(
                    name: device.name, transport: device.transport, colorIndex: nextColor)
            }
        }
    }

    func updateDevice(_ uid: String, _ change: (inout DeviceSettings) -> Void) {
        guard profile.devices[uid] != nil else { return }
        change(&profile.devices[uid]!)
    }

    func forgetDevice(_ uid: String) {
        profile.clips.removeAll { $0.deviceUID == uid }
        profile.devices[uid] = nil
        compactRows()
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = profile
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
