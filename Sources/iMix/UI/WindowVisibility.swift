import AppKit
import Observation
import SwiftUI

/// Whether the main window can actually be seen. macOS reports this as the window's occlusion state:
/// it's false when the window is minimized, hidden, on another Space or fully covered.
/// The spectrum stops drawing (and stops running its FFT) while it's false.
@Observable
final class WindowVisibility {
    private(set) var isVisible = true

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var observer: NSObjectProtocol?

    func attach(to window: NSWindow) {
        guard window !== self.window else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        self.window = window
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.update()
        }
        update()
    }

    private func update() {
        let visible = window?.occlusionState.contains(.visible) ?? true
        if visible != isVisible { isVisible = visible }
    }
}

/// Hands the hosting NSWindow to `WindowVisibility` once the view is in a window.
struct WindowVisibilityReader: NSViewRepresentable {
    let visibility: WindowVisibility

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { visibility.attach(to: window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { visibility.attach(to: window) }
    }
}
