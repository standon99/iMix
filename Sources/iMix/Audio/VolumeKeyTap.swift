import AppKit
import ApplicationServices
import SwiftUI

/// Catches the keyboard volume keys (up, down, mute) so iMix can use them for its own master while
/// routing. Needs Accessibility access. Keys the handler doesn't take pass through to macOS as usual.
final class VolumeKeyTap {
    enum Key { case up, down, mute }

    /// Called for each press and release; return true to consume it (macOS then leaves its own
    /// volume alone). Consume releases whenever you'd consume presses, so macOS never sees half a press.
    var handler: ((Key, _ isDown: Bool, _ fine: Bool) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    func start() {
        guard tap == nil, Self.isTrusted else { return }
        // Media keys arrive as NX_SYSDEFINED (14) events.
        let mask = CGEventMask(1 << 14)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<VolumeKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return owner.handle(type: type, event: event)
            },
            userInfo: me) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches taps off if they're slow or on some user input; turn it straight back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let code = (ns.data1 & 0xFFFF_0000) >> 16
        let isDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
        let key: Key
        switch code {
        case 0: key = .up    // NX_KEYTYPE_SOUND_UP
        case 1: key = .down  // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute  // NX_KEYTYPE_MUTE
        default: return Unmanaged.passUnretained(event)
        }
        let fine = ns.modifierFlags.contains([.option, .shift])
        let consumed = handler?(key, isDown, fine) ?? false
        return consumed ? nil : Unmanaged.passUnretained(event)
    }
}

/// A small volume popup, since macOS doesn't show its own for keys iMix takes.
final class VolumeHUD {
    static let shared = VolumeHUD()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let model = Model()

    @Observable final class Model {
        var volume: Double = 1
        var muted = false
    }

    func show(volume: Double, muted: Bool) {
        model.volume = volume
        model.muted = muted
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + screen.frame.height * 0.14))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel?.animator().alphaValue = 0
            } completionHandler: {
                panel?.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 64),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }

    private struct HUDView: View {
        let model: Model

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: model.muted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 24)
                HStack(spacing: 2) {
                    ForEach(0..<16, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(!model.muted && Double(i) < (model.volume * 16).rounded() ? Color.white : Color.white.opacity(0.18))
                            .frame(width: 7, height: 10)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(width: 220, height: 64)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.12).opacity(0.92)))
            .overlay(alignment: .topLeading) {
                Text("iMix · all speakers")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.leading, 18)
                    .padding(.top, 7)
            }
            .preferredColorScheme(.dark)
        }
    }
}
