// Renders the iMix app icon: a shaded waveform on a dark grey squircle.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ white: Double, _ alpha: Double = 1) -> CGColor { CGColor(gray: white, alpha: alpha) }

// macOS icon grid: 824 pt body centred in 1024, continuous-corner radius ~185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0.45))
ctx.addPath(shape)
ctx.setFillColor(color(0.08))
ctx.fillPath()
ctx.restoreGState()

// Background: graphite at the top fading to near-black.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [color(0.23), color(0.12), color(0.05)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Soft radial lift behind the waveform.
let glow = CGGradient(colorsSpace: space, colors: [color(1, 0.09), color(1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 520), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 520), endRadius: 420, options: [])
ctx.restoreGState()

// Waveform: a sine whose amplitude swells in the middle, like a single sound.
func wave(phase: Double, cycles: Double, amplitude: Double) -> CGPath {
    let path = CGMutablePath()
    let left = 196.0, right = 828.0, mid = 512.0
    let steps = 600
    for i in 0...steps {
        let t = Double(i) / Double(steps)
        let envelope = pow(sin(Double.pi * t), 1.6)
        let y = mid + amplitude * envelope * sin(2 * Double.pi * cycles * t + phase)
        let p = CGPoint(x: left + (right - left) * t, y: y)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    return path
}

// Faint echo behind for depth.
ctx.saveGState()
ctx.addPath(wave(phase: 0.9, cycles: 3.5, amplitude: 175))
ctx.setLineWidth(16)
ctx.setLineCap(.round)
ctx.setStrokeColor(color(0.55, 0.28))
ctx.strokePath()
ctx.restoreGState()

// Main wave: stroked into a shape, then filled with a top-lit gradient and a soft shadow.
let main = wave(phase: 0, cycles: 3.5, amplitude: 235)
let stroke = main.copy(strokingWithWidth: 30, lineCap: .round, lineJoin: .round, miterLimit: 10)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0, 0.6))
ctx.addPath(stroke)
ctx.setFillColor(color(0.7))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(stroke)
ctx.clip()
let metal = CGGradient(colorsSpace: space, colors: [color(1), color(0.86), color(0.58)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(metal, start: CGPoint(x: 512, y: 760), end: CGPoint(x: 512, y: 260), options: [])
ctx.restoreGState()

// Thin highlight along the top edge of the body.
ctx.saveGState()
ctx.addPath(shape)
ctx.setLineWidth(3)
ctx.setStrokeColor(color(1, 0.08))
ctx.strokePath()
ctx.restoreGState()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
