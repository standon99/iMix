import Foundation

/// The app used to be called SoundStage (bundle ID local.soundstage.app). Carry its saved profile
/// and preferences over once, so the rename doesn't lose clips, calibration or EQ.
enum LegacyMigration {
    private static let doneKey = "migratedFromSoundStage"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        if let old = UserDefaults(suiteName: "local.soundstage.app") {
            for key in ["routingEnabled", "selectedApps", "appVolume", "page"] where defaults.object(forKey: key) == nil {
                if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldProfile = support.appendingPathComponent("SoundStage/profile.json")
        let newDir = support.appendingPathComponent("iSound", isDirectory: true)
        let newProfile = newDir.appendingPathComponent("profile.json")
        if FileManager.default.fileExists(atPath: oldProfile.path), !FileManager.default.fileExists(atPath: newProfile.path) {
            try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: oldProfile, to: newProfile)
        }
    }
}
