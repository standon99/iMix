import SwiftUI

/// 31-band graphic equalizer, grouped into labelled regions (sub-bass, bass, …) over the live spectrum.
struct EqualizerView: View {
    @Environment(ProfileStore.self) private var store
    @Environment(AudioEngine.self) private var engine
    let feed: SpectrumFeed

    private var eq: EQSettings { store.profile.eq }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            GeometryReader { geo in
                let layout = EQLayout(size: geo.size)
                ZStack(alignment: .topLeading) {
                    RegionBackgrounds(layout: layout)
                    EQCanvas(feed: feed, layout: layout,
                             curve: eq.enabled ? EQCurve.points(gains: eq.gains) : [],
                             enabled: eq.enabled)
                    ForEach(EQBands.centers.indices, id: \.self) { band in
                        Fader(
                            value: Binding(get: { eq.gains[band] }, set: { store.setEQGain(band, $0) }),
                            label: EQBands.labels[band],
                            color: Color(hex: EQBands.region(ofBand: band).color),
                            layout: layout)
                        .frame(width: layout.columnWidth, height: layout.size.height)
                        .position(x: layout.x(band: band), y: layout.size.height / 2)
                    }
                    .opacity(eq.enabled ? 1 : 0.4)
                }
            }
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))

            frequencyLabels
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Toggle("Equalizer", isOn: Binding(get: { eq.enabled }, set: { store.setEQEnabled($0) }))
                .toggleStyle(.switch)
                .font(.headline)
            Menu("Presets") {
                ForEach(EQBands.presets, id: \.name) { preset in
                    Button(preset.name) { store.setEQGains(preset.gains) }
                }
            }
            .fixedSize()
            Button("Reset") { store.setEQGains(EQBands.presets[0].gains) }
            Spacer()
            if !engine.routingActive {
                Label("The EQ applies while Route is on", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            let preamp = EQSnapshot(eq).preampDB
            if preamp < -0.05 {
                Text(String(format: "Headroom %.1f dB", preamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .help("Boosts are offset by turning everything down this much first, so loud music doesn't clip. Raise the master volume to compensate.")
            }
        }
    }

    private var frequencyLabels: some View {
        GeometryReader { geo in
            let layout = EQLayout(size: CGSize(width: geo.size.width, height: 0))
            ForEach(EQBands.labels.indices, id: \.self) { band in
                Text(EQBands.labels[band])
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                    .position(x: layout.x(band: band), y: 6)
            }
        }
        .frame(height: 14)
    }
}

/// Shared geometry: a log frequency axis padded half a band each side, and the fader travel.
struct EQLayout {
    let size: CGSize
    static let minHz = EQBands.centers.first! / pow(2, 1.0 / 6)
    static let maxHz = EQBands.centers.last! * pow(2, 1.0 / 6)
    static let top: CGFloat = 46
    static let bottom: CGFloat = 16

    var columnWidth: CGFloat { size.width / CGFloat(EQBands.centers.count) }
    var travelTop: CGFloat { Self.top }
    var travelBottom: CGFloat { size.height - Self.bottom }

    func x(hz: Double) -> CGFloat {
        CGFloat(log(hz / Self.minHz) / log(Self.maxHz / Self.minHz)) * size.width
    }

    func x(band: Int) -> CGFloat { x(hz: EQBands.centers[band]) }

    /// dB (−12…+12) to y, within the fader travel.
    func y(db: Double) -> CGFloat {
        let t = (db - EQBands.range.lowerBound) / (EQBands.range.upperBound - EQBands.range.lowerBound)
        return travelBottom - CGFloat(t) * (travelBottom - travelTop)
    }

    func db(y: CGFloat) -> Double {
        let t = Double((travelBottom - y) / max(travelBottom - travelTop, 1))
        return EQBands.range.lowerBound + t * (EQBands.range.upperBound - EQBands.range.lowerBound)
    }
}

enum EQCurve {
    /// (frequency, dB) samples of the combined response, for drawing.
    static func points(gains: [Double]) -> [(Double, Double)] {
        let filterGains = GraphicEQ.filterGains(for: gains)
        return (0..<160).map { i in
            let hz = EQLayout.minHz * pow(EQLayout.maxHz / EQLayout.minHz, Double(i) / 159)
            return (hz, GraphicEQ.responseDB(gains: filterGains, at: min(hz, 20_000)))
        }
    }
}

private struct RegionBackgrounds: View {
    let layout: EQLayout

    var body: some View {
        ForEach(EQBands.regions, id: \.name) { region in
            let x0 = layout.x(band: region.bands.lowerBound) - layout.columnWidth / 2
            let x1 = layout.x(band: region.bands.upperBound) + layout.columnWidth / 2
            let color = Color(hex: region.color)
            ZStack(alignment: .top) {
                Rectangle().fill(color.opacity(0.07))
                Rectangle().fill(color.opacity(0.8)).frame(height: 2)
                Text(region.name.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.top, 9)
                    .padding(.horizontal, 2)
            }
            .frame(width: x1 - x0, height: layout.size.height)
            .offset(x: x0)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.stroke).frame(width: 1).offset(x: x0)
            }
        }
    }
}

/// Grid, faint live spectrum, and the EQ's combined response curve.
private struct EQCanvas: View {
    @Environment(WindowVisibility.self) private var visibility
    let feed: SpectrumFeed
    let layout: EQLayout
    let curve: [(Double, Double)]
    let enabled: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: SpectrumScale.refreshInterval, paused: !visibility.isVisible)) { timeline in
            Canvas { ctx, size in
                drawGrid(&ctx, size)
                drawSpectrum(feed.frame(at: timeline.date.timeIntervalSinceReferenceDate), &ctx, size)
                drawCurve(&ctx)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawGrid(_ ctx: inout GraphicsContext, _ size: CGSize) {
        for db in stride(from: -12.0, through: 12.0, by: 6.0) {
            let y = layout.y(db: db)
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                       with: .color(db == 0 ? Color.white.opacity(0.18) : Theme.grid),
                       style: StrokeStyle(lineWidth: 1, dash: db == 0 ? [] : [3, 4]))
            ctx.draw(Text(db > 0 ? "+\(Int(db))" : "\(Int(db))").font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary),
                     at: CGPoint(x: 4, y: y + 7), anchor: .leading)
        }
    }

    /// The spectrum is drawn on its own dB scale, bottom-anchored, just for context.
    private func drawSpectrum(_ frame: SpectrumFrame, _ ctx: inout GraphicsContext, _ size: CGSize) {
        let levels = frame.levels
        guard levels.count > 1 else { return }
        var path = Path()
        let bottom = layout.travelBottom
        let height = layout.travelBottom - layout.travelTop
        path.move(to: CGPoint(x: 0, y: bottom))
        for (i, db) in levels.enumerated() {
            let hz = FrequencyRange.frequency(at: Double(i) / Double(levels.count - 1))
            let t = CGFloat((db - SpectrumScale.minDB) / (SpectrumScale.maxDB - SpectrumScale.minDB))
            path.addLine(to: CGPoint(x: layout.x(hz: hz), y: bottom - t * height))
        }
        path.addLine(to: CGPoint(x: layout.x(hz: FrequencyRange.max), y: bottom))
        path.closeSubpath()
        ctx.fill(path, with: .color(.white.opacity(0.06)))
    }

    private func drawCurve(_ ctx: inout GraphicsContext) {
        guard enabled, curve.count > 1 else { return }
        var line = Path()
        for (i, point) in curve.enumerated() {
            let p = CGPoint(x: layout.x(hz: point.0), y: layout.y(db: min(max(point.1, -14), 14)))
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        var area = line
        area.addLine(to: CGPoint(x: layout.x(hz: curve.last!.0), y: layout.y(db: 0)))
        area.addLine(to: CGPoint(x: layout.x(hz: curve.first!.0), y: layout.y(db: 0)))
        area.closeSubpath()
        ctx.fill(area, with: .color(Theme.accent.opacity(0.12)))
        ctx.stroke(line, with: .color(Theme.accent.opacity(0.35)), lineWidth: 6)
        ctx.stroke(line, with: .color(Theme.accent), lineWidth: 2)
    }
}

/// A vertical fader: drag to set, double-click to return to 0 dB.
private struct Fader: View {
    @Binding var value: Double
    let label: String
    let color: Color
    let layout: EQLayout

    @State private var hovering = false

    var body: some View {
        let knobY = layout.y(db: value)
        let zeroY = layout.y(db: 0)
        ZStack(alignment: .topLeading) {
            // Track.
            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: 3, height: layout.travelBottom - layout.travelTop)
                .position(x: layout.columnWidth / 2, y: (layout.travelTop + layout.travelBottom) / 2)
            // Fill from 0 dB to the current value.
            Rectangle()
                .fill(color)
                .frame(width: 3, height: abs(knobY - zeroY))
                .position(x: layout.columnWidth / 2, y: (knobY + zeroY) / 2)
            // Knob.
            RoundedRectangle(cornerRadius: 3)
                .fill(hovering ? Color.white : Color(white: 0.85))
                .frame(width: min(layout.columnWidth - 8, 22), height: 9)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .overlay(Rectangle().fill(color).frame(height: 2))
                .position(x: layout.columnWidth / 2, y: knobY)
            // Value readout above the travel.
            if abs(value) >= 0.05 || hovering {
                Text(String(format: value > 0 ? "+%.1f" : "%.1f", value))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(abs(value) >= 0.05 ? color : Theme.textTertiary)
                    .fixedSize()
                    .position(x: layout.columnWidth / 2, y: layout.travelTop - 10)
            }
        }
        .frame(width: layout.columnWidth, height: layout.size.height)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    // Half-dB steps.
                    let db = (layout.db(y: drag.location.y) * 2).rounded() / 2
                    value = min(max(db, EQBands.range.lowerBound), EQBands.range.upperBound)
                }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
        .help("\(label) Hz: drag to boost or cut, double-click to reset")
    }
}
