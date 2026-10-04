import SwiftUI

/// What the canvas needs to know about each clip to colour its range.
struct ClipPaint: Equatable {
    var lower: Double
    var upper: Double
    var color: Color
    var emphasized: Bool
}

/// The live spectrum (higher = louder) on a log frequency axis.
/// Each clip's range is projected down in its colour; frequencies no clip covers are shaded red.
struct SpectrumCanvas: View {
    let feed: SpectrumFeed
    let clips: [ClipPaint]
    let uncovered: [ClosedRange<Double>]

    static let topInset: CGFloat = 10
    static let bottomInset: CGFloat = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            Canvas { ctx, size in
                let frame = feed.frame(at: timeline.date.timeIntervalSinceReferenceDate)
                draw(frame, in: &ctx, size: size)
            }
        }
    }

    private func draw(_ frame: SpectrumFrame, in ctx: inout GraphicsContext, size: CGSize) {
        for gap in uncovered {
            ctx.fill(Path(rect(for: gap.lowerBound, gap.upperBound, size: size)),
                     with: .color(Theme.uncovered.opacity(0.13)))
        }

        drawGrid(in: &ctx, size: size)
        let (fill, line) = curve(bins: frame.levels, size: size)
        let (_, peakLine) = curve(bins: frame.peaks, size: size)

        // Peak hold, then the live trace: neutral base, each clip's slice in its colour. Overlaps blend.
        ctx.stroke(peakLine, with: .color(Color(hex: 0xF0A3D0).opacity(0.45)), lineWidth: 1)
        ctx.fill(fill, with: .color(.white.opacity(0.04)))
        ctx.stroke(line, with: .color(.white.opacity(0.35)), lineWidth: 1)
        for clip in clips {
            let r = rect(for: clip.lower, clip.upper, size: size)
            var clipped = ctx
            clipped.clip(to: Path(r))
            clipped.fill(fill, with: .linearGradient(
                Gradient(colors: [clip.color.opacity(clip.emphasized ? 0.4 : 0.25), clip.color.opacity(0.03)]),
                startPoint: CGPoint(x: 0, y: Self.topInset),
                endPoint: CGPoint(x: 0, y: size.height)))
            clipped.stroke(line, with: .color(clip.color.opacity(clip.emphasized ? 1 : 0.85)), lineWidth: 1.1)
        }

        for gap in uncovered {
            var clipped = ctx
            clipped.clip(to: Path(rect(for: gap.lowerBound, gap.upperBound, size: size)))
            clipped.stroke(line, with: .color(Theme.uncovered.opacity(0.75)), lineWidth: 1.1)
        }

        // Dashed edge guides continuing each clip's edges down from the lanes.
        for clip in clips {
            for hz in [clip.lower, clip.upper] where hz > FrequencyRange.min * 1.001 && hz < FrequencyRange.max / 1.001 {
                let x = FrequencyRange.x(of: hz, width: size.width)
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(clip.color.opacity(clip.emphasized ? 0.8 : 0.35)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
        }
    }

    private func rect(for lower: Double, _ upper: Double, size: CGSize) -> CGRect {
        let x0 = FrequencyRange.x(of: lower, width: size.width)
        let x1 = FrequencyRange.x(of: upper, width: size.width)
        return CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)
    }

    private func y(for db: Float, height: CGFloat) -> CGFloat {
        let t = CGFloat((db - SpectrumScale.minDB) / (SpectrumScale.maxDB - SpectrumScale.minDB))
        let top = Self.topInset
        let bottom = height - Self.bottomInset
        return bottom - t * (bottom - top)
    }

    private func curve(bins: [Float], size: CGSize) -> (fill: Path, line: Path) {
        var line = Path()
        guard bins.count > 1 else { return (Path(), Path()) }
        for (i, db) in bins.enumerated() {
            let point = CGPoint(
                x: CGFloat(i) / CGFloat(bins.count - 1) * size.width,
                y: y(for: db, height: size.height))
            if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        var fill = line
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: size.height))
        fill.closeSubpath()
        return (fill, line)
    }

    private func drawGrid(in ctx: inout GraphicsContext, size: CGSize) {
        let gridColor = GraphicsContext.Shading.color(Theme.grid)

        let firstLine = Int(SpectrumScale.minDB) + 10
        for db in stride(from: firstLine, to: Int(SpectrumScale.maxDB), by: 10) {
            let yPos = y(for: Float(db), height: size.height)
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: yPos)); $0.addLine(to: CGPoint(x: size.width, y: yPos)) },
                       with: gridColor, lineWidth: 1)
            if db % 20 == 0 {
                ctx.draw(Text("\(db) dB").font(.system(size: 9)).foregroundStyle(Theme.textTertiary),
                         at: CGPoint(x: size.width - 6, y: yPos - 7), anchor: .trailing)
            }
        }

        for hz in FrequencyRuler.marks.map(\.hz) {
            let x = FrequencyRange.x(of: hz, width: size.width)
            ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                       with: gridColor, lineWidth: 1)
        }
    }
}

/// Frequency labels between the lanes and the spectrum, like a timeline ruler.
struct FrequencyRuler: View {
    static let marks: [(hz: Double, label: String)] = [
        (50, "50"), (100, "100"), (200, "200"), (500, "500"),
        (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k"),
    ]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.panelRaised))
            for (hz, label) in Self.marks {
                let x = FrequencyRange.x(of: hz, width: size.width)
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: size.height - 5)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(Theme.textTertiary), lineWidth: 1)
                ctx.draw(Text(label).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textSecondary),
                         at: CGPoint(x: x, y: size.height / 2 - 2))
            }
            ctx.draw(Text("Hz").font(.system(size: 10)).foregroundStyle(Theme.textTertiary),
                     at: CGPoint(x: 8, y: size.height / 2 - 2), anchor: .leading)
        }
    }
}
