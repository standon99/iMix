import AppKit

/// Only one iMix may run. Two copies (say, one in /Applications and one in build/, which macOS treats
/// as different apps) each capture the other's output and mute it while routing, so turning Route on
/// in either goes silent, and Route off in one leaves the other still routing.
enum SingleInstance {
    static func enforce() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != me && !$0.isTerminated }
        }
        // A copy that is just quitting (scripts/run.sh kills the old one, then opens the new) gets a
        // moment to finish rather than counting as already running.
        let deadline = Date().addingTimeInterval(2)
        while !others().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        guard let running = others().first else { return }
        running.activate()
        exit(0)
    }
}
