import Foundation

/// The app was previously called iSound (local.isound.app) and before that SoundStage
/// (local.soundstage.app). Carry the most recent one's saved profile and preferences over once,
/// so renaming doesn't lose clips, calibration or EQ.
enum LegacyMigration {
    private static let doneKey = "migratedLegacySettings"
    /// Newest first.
    private static let previous = [
        (bundleID: "local.isound.app", folder: "iSound"),
        (bundleID: "local.soundstage.app", folder: "SoundStage"),
    ]

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard let source = previous.first(where: {
            FileManager.default.fileExists(atPath: support.appendingPathComponent("\($0.folder)/profile.json").path)
        }) else { return }

        if let old = UserDefaults(suiteName: source.bundleID) {
            for key in ["routingEnabled", "selectedApps", "appVolume", "page"] where defaults.object(forKey: key) == nil {
                if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }

        let oldProfile = support.appendingPathComponent("\(source.folder)/profile.json")
        let newDir = support.appendingPathComponent("iMix", isDirectory: true)
        let newProfile = newDir.appendingPathComponent("profile.json")
        if !FileManager.default.fileExists(atPath: newProfile.path) {
            try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: oldProfile, to: newProfile)
        }
    }
}
