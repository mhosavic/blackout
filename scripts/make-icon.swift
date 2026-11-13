// Draws the Blackout app icon — a total eclipse — and builds the .icns.
//
//   swift scripts/make-icon.swift Resources/AppIcon.icns [docs/logo.png]
//
// Drawn in code so the package needs no design tool or asset catalog (it
// builds with Command Line Tools alone). The generated .icns is committed;
// run this again only to change the artwork.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
}

func radialGradient(_ context: CGContext, at center: CGPoint, from inner: CGFloat, to outer: CGFloat, stops: [(CGFloat, CGColor)]) {
    let gradient = CGGradient(colorsSpace: colorSpace, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
    context.drawRadialGradient(gradient, startCenter: center, startRadius: inner, endCenter: center, endRadius: outer, options: [])
}

/// The icon at `size` pixels square. Every length is in units of a 1024
/// grid, following Apple's template: an 824 plate with 100 of margin.
func drawIcon(size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let unit = CGFloat(size) / 1024

    let plate = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let plateShape = CGPath(roundedRect: plate, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil)
    context.saveGState()
    context.addPath(plateShape)
    context.clip()

    // Night sky
    let sky = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0.075, 0.082, 0.118), color(0.012, 0.012, 0.022)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(sky, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])

    let center = CGPoint(x: 512 * unit, y: 512 * unit)
    let moon: CGFloat = 196 * unit

    // The corona: a wide warm glow, then a tight bright rim
    context.setBlendMode(.screen)
    radialGradient(context, at: center, from: moon * 0.9, to: moon * 2.05, stops: [
        (0, color(1, 0.80, 0.50, 0.55)), (0.35, color(1, 0.62, 0.30, 0.20)), (1, color(1, 0.5, 0.2, 0))
    ])
    radialGradient(context, at: center, from: moon * 0.96, to: moon * 1.32, stops: [
        (0, color(1, 0.97, 0.90, 1)), (0.3, color(1, 0.90, 0.72, 0.75)), (1, color(1, 0.8, 0.5, 0))
    ])
    // The "diamond ring": the last bead of sunlight on the upper-right limb
    let angle = CGFloat.pi * 0.25
    let bead = CGPoint(x: center.x + cos(angle) * moon, y: center.y + sin(angle) * moon)
    radialGradient(context, at: bead, from: 0, to: moon * 0.46, stops: [
        (0, color(1, 1, 1, 1)), (0.22, color(1, 0.98, 0.92, 0.9)), (0.55, color(1, 0.9, 0.7, 0.25)), (1, color(1, 0.9, 0.7, 0))
    ])
    context.setBlendMode(.normal)

    // The moon, with a trace of earthshine so it reads as a body, not a hole
    let moonRect = CGRect(x: center.x - moon, y: center.y - moon, width: moon * 2, height: moon * 2)
    context.saveGState()
    context.addEllipse(in: moonRect)
    context.clip()
    // Black first: the gradient below stops short of the far limb
    context.setFillColor(color(0, 0, 0))
    context.fill(moonRect)
    radialGradient(context, at: CGPoint(x: center.x + moon * 0.45, y: center.y + moon * 0.45), from: 0, to: moon * 1.5, stops: [
        (0, color(0.10, 0.105, 0.14)), (1, color(0, 0, 0))
    ])
    context.restoreGState()
    context.restoreGState()

    // Hairline edge so the plate holds its shape on a dark background
    context.addPath(plateShape)
    context.setStrokeColor(color(1, 1, 1, 0.07))
    context.setLineWidth(2 * unit)
    context.strokePath()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not write \(url.path)")
    }
}

guard CommandLine.arguments.count >= 2 else {
    print("usage: swift scripts/make-icon.swift <out.icns> [<logo.png>]")
    exit(2)
}
let icnsURL = URL(fileURLWithPath: CommandLine.arguments[1])

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("blackout-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

// The sizes iconutil expects: each point size at 1x and 2x
for points in [16, 32, 128, 256, 512] {
    writePNG(drawIcon(size: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(drawIcon(size: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", icnsURL.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed")
}
print("Wrote \(icnsURL.path)")

if CommandLine.arguments.count >= 3 {
    let logoURL = URL(fileURLWithPath: CommandLine.arguments[2])
    writePNG(drawIcon(size: 512), to: logoURL)
    print("Wrote \(logoURL.path)")
}
