import AppKit
import SwiftUI

/// The live spectrum on top, a frequency ruler, then clip lanes below (like a video timeline, but for frequency).
struct SpectrumEditorView: View {
    @Environment(ProfileStore.self) private var store
    @Environment(DeviceManager.self) private var devices
    let feed: SpectrumFeed

    @State private var selected: UUID?
    @State private var hovered: UUID?
    @State private var pendingRemove: UUID?
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    static let laneHeight: CGFloat = 34
    static let lanePadding: CGFloat = 6
    static let rulerHeight: CGFloat = 22
    static let space = "editor"

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let rows = max(store.rowCount + 1, 3)
            let lanesHeight = CGFloat(rows) * Self.laneHeight + Self.lanePadding * 2

            let lanesTop = geo.size.height - lanesHeight

            VStack(spacing: 0) {
                SpectrumCanvas(feed: feed, clips: clipPaints, uncovered: store.uncoveredRanges)
                    .frame(maxHeight: .infinity)

                FrequencyRuler()
                    .frame(height: Self.rulerHeight)

                ZStack(alignment: .topLeading) {
                    LaneBackground(rows: rows, uncovered: store.uncoveredRanges)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = nil }

                    if store.profile.clips.isEmpty {
                        Text("Drag an output here")
                            .font(.callout)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }

                    ForEach(store.profile.clips) { clip in
                        ClipBar(
                            clip: clip,
                            editorWidth: width,
                            lanesHeight: lanesHeight,
                            online: devices.isConnected(clip.deviceUID),
                            selected: $selected,
                            hovered: $hovered,
                            pendingRemove: $pendingRemove,
                            focused: $focused)
                    }
                }
                .frame(height: lanesHeight)
                .coordinateSpace(.named(Self.space))
                .clipped()
            }
            .dropDestination(for: String.self) { items, location in
                guard let uid = items.compactMap(DragPayload.deviceUID(from:)).first else { return false }
                let laneY = location.y - lanesTop
                let row = laneY >= 0
                    ? max(Int((laneY - Self.lanePadding) / Self.laneHeight), 0)
                    : nil
                selected = store.addClip(
                    deviceUID: uid,
                    centeredOn: FrequencyRange.frequency(atX: location.x, width: width),
                    preferredRow: row)
                focused = true
                return true
            } isTargeted: { dropTargeted = $0 }
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(dropTargeted ? Theme.accent : Theme.stroke, lineWidth: dropTargeted ? 2 : 1))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand {
            if let id = selected {
                store.removeClip(id)
                selected = nil
            }
        }
    }

    private var clipPaints: [ClipPaint] {
        store.profile.clips.compactMap { clip in
            guard let settings = store.profile.devices[clip.deviceUID] else { return nil }
            return ClipPaint(
                lower: clip.lower,
                upper: clip.upper,
                color: Theme.color(forDevice: settings.colorIndex),
                emphasized: clip.id == selected || clip.id == hovered)
        }
    }
}

/// Lane stripes, grid lines, and red shading over frequencies nothing covers.
private struct LaneBackground: View {
    let rows: Int
    let uncovered: [ClosedRange<Double>]

    var body: some View {
        Canvas { ctx, size in
            for row in 0..<rows {
                let rect = CGRect(
                    x: 0, y: SpectrumEditorView.lanePadding + CGFloat(row) * SpectrumEditorView.laneHeight,
                    width: size.width, height: SpectrumEditorView.laneHeight)
                if row % 2 == 1 {
                    ctx.fill(Path(rect), with: .color(.white.opacity(0.018)))
                }
            }
            for hz in FrequencyRuler.marks.map(\.hz) {
                let x = FrequencyRange.x(of: hz, width: size.width)
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(Theme.grid), lineWidth: 1)
            }
            for gap in uncovered {
                let x0 = FrequencyRange.x(of: gap.lowerBound, width: size.width)
                let x1 = FrequencyRange.x(of: gap.upperBound, width: size.width)
                ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)),
                         with: .color(Theme.uncovered.opacity(0.08)))
            }
        }
    }
}

/// One output's frequency range. Drag the middle to move (sideways or to another row),
/// drag an edge to resize, drag it out of the lanes to remove.
private struct ClipBar: View {
    @Environment(ProfileStore.self) private var store
    let clip: Clip
    let editorWidth: CGFloat
    let lanesHeight: CGFloat
    let online: Bool
    @Binding var selected: UUID?
    @Binding var hovered: UUID?
    @Binding var pendingRemove: UUID?
    var focused: FocusState<Bool>.Binding

    @State private var moveStart: Clip?
    @State private var resizing = false

    private var settings: DeviceSettings? { store.profile.devices[clip.deviceUID] }
    private var color: Color { settings.map { Theme.color(forDevice: $0.colorIndex) } ?? .gray }
    private var name: String { settings?.displayName ?? "Unknown output" }
    private var dimmed: Bool { !online || settings?.muted == true }
    private var removing: Bool { pendingRemove == clip.id }
    private var isSelected: Bool { selected == clip.id }
    private var rangeText: String { "\(FrequencyRange.format(clip.lower)) – \(FrequencyRange.format(clip.upper))" }

    private var label: some View {
        Text(removing ? "Release to remove" : name)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
    }

    private var rangeLabel: some View {
        Text(rangeText)
            .font(.system(size: 11).monospacedDigit())
            .lineLimit(1)
            .opacity(0.75)
            .fixedSize()
    }

    var body: some View {
        let x0 = FrequencyRange.x(of: clip.lower, width: editorWidth)
        let x1 = FrequencyRange.x(of: clip.upper, width: editorWidth)
        let barWidth = max(x1 - x0, 8)

        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(dimmed ? 0.35 : 0.88))

            // Show the range beside the name when there's room; while resizing, the range wins.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    label
                    Spacer(minLength: 0)
                    rangeLabel
                }
                if resizing { rangeLabel } else { label }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color.black.opacity(dimmed ? 0.6 : 0.82))
            .padding(.horizontal, 14)

            HStack(spacing: 0) {
                EdgeHandle(clip: clip, edge: .lower, editorWidth: editorWidth, resizing: $resizing)
                Spacer(minLength: 0)
                EdgeHandle(clip: clip, edge: .upper, editorWidth: editorWidth, resizing: $resizing)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(removing ? Theme.danger : (isSelected ? Color.white : .clear), lineWidth: 2))
        .opacity(removing ? 0.45 : 1)
        .frame(width: barWidth, height: SpectrumEditorView.laneHeight - 6)
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? clip.id : (hovered == clip.id ? nil : hovered) }
        .gesture(moveGesture)
        .simultaneousGesture(TapGesture().onEnded {
            selected = clip.id
            focused.wrappedValue = true
        })
        .contextMenu {
            Button("Remove", role: .destructive) { store.removeClip(clip.id) }
        }
        .help("\(name): \(rangeText)")
        .offset(x: x0, y: SpectrumEditorView.lanePadding + CGFloat(clip.row) * SpectrumEditorView.laneHeight + 3)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(SpectrumEditorView.space))
            .onChanged { value in
                if moveStart == nil {
                    moveStart = clip
                    selected = clip.id
                    focused.wrappedValue = true
                }
                guard let start = moveStart else { return }

                let outOfLanes = value.location.y < -20 || value.location.y > lanesHeight + 24
                pendingRemove = outOfLanes ? clip.id : nil
                guard !outOfLanes else { return }

                // Shift on the log axis, keeping the clip's width in octaves.
                let p0 = FrequencyRange.position(of: start.lower)
                let p1 = FrequencyRange.position(of: start.upper)
                let shift = min(max(Double(value.translation.width / editorWidth), -p0), 1 - p1)
                let row = min(max(Int((value.location.y - SpectrumEditorView.lanePadding) / SpectrumEditorView.laneHeight), 0),
                              store.rowCount)
                store.updateClip(clip.id) {
                    $0.lower = FrequencyRange.frequency(at: p0 + shift)
                    $0.upper = FrequencyRange.frequency(at: p1 + shift)
                    $0.row = row
                }
            }
            .onEnded { _ in
                if pendingRemove == clip.id {
                    store.removeClip(clip.id)
                    if selected == clip.id { selected = nil }
                } else {
                    store.finalize(clip.id)
                }
                pendingRemove = nil
                moveStart = nil
            }
    }
}

private struct EdgeHandle: View {
    enum Edge { case lower, upper }

    @Environment(ProfileStore.self) private var store
    let clip: Clip
    let edge: Edge
    let editorWidth: CGFloat
    @Binding var resizing: Bool

    @State private var limits: (lowerMin: Double, upperMax: Double)?

    var body: some View {
        HStack(spacing: 2) {
            Capsule().frame(width: 1.5, height: 12)
            Capsule().frame(width: 1.5, height: 12)
        }
        .foregroundStyle(Color.black.opacity(0.4))
        .frame(width: 10)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .columnResizeCursor()
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(SpectrumEditorView.space))
                .onChanged { value in
                    if limits == nil { limits = store.resizeLimits(for: clip.id) }
                    guard let limits else { return }
                    resizing = true
                    let hz = FrequencyRange.frequency(atX: value.location.x, width: editorWidth)
                    store.updateClip(clip.id) { c in
                        switch edge {
                        case .lower: c.lower = min(max(hz, limits.lowerMin), c.upper / FrequencyRange.minWidthRatio)
                        case .upper: c.upper = max(min(hz, limits.upperMax), c.lower * FrequencyRange.minWidthRatio)
                        }
                    }
                }
                .onEnded { _ in
                    limits = nil
                    resizing = false
                    store.finalize(clip.id)
                }
        )
    }
}

private extension View {
    @ViewBuilder
    func columnResizeCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.columnResize)
        } else {
            onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
        }
    }
}
