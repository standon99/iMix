import CoreAudio
import Foundation
import Observation

/// Keeps a tap on Spotify when it's running, otherwise on all system audio, and feeds the spectrum.
@Observable
final class CaptureController {
    enum Source: Equatable {
        case starting
        case spotify
        case system
        case failed(String)
    }

    private(set) var source: Source = .starting
    private(set) var spotifyPlaying = false

    @ObservationIgnored let feed = LiveSpectrumFeed()
    @ObservationIgnored private var capture: ProcessTapCapture?
    @ObservationIgnored private var spotifyProcesses: [AudioObjectID] = []
    @ObservationIgnored private var timer: Timer?

    static let spotifyBundlePrefix = "com.spotify.client"

    func start() {
        guard timer == nil else { return }
        refresh()
        // Spotify can launch or quit at any time; re-check every couple of seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let processes = ProcessTapCapture.processObjects(bundlePrefix: Self.spotifyBundlePrefix)
        let playing = processes.contains(where: ProcessTapCapture.isRunningOutput)
        if playing != spotifyPlaying { spotifyPlaying = playing }

        if capture != nil, processes == spotifyProcesses { return }
        restart(with: processes)
    }

    private func restart(with processes: [AudioObjectID]) {
        capture?.stop()
        capture = nil
        feed.ring.clear()
        spotifyProcesses = processes

        let tap = ProcessTapCapture(ring: feed.ring)
        do {
            try tap.start(processes: processes)
            feed.sampleRate = tap.sampleRate
            capture = tap
            source = processes.isEmpty ? .system : .spotify
        } catch {
            source = .failed(error.localizedDescription)
        }
    }
}
