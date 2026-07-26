#!/usr/bin/env swift
//
// make-icon.swift — draws the app icon and writes the asset catalog.
//
// The icon is generated rather than drawn by hand so it stays reproducible and
// reviewable: the shape is the same blue waveform the dictation panel shows
// while recording, so the thing in your Dock, in Finder, and in the System
// Settings permission lists is recognisably the thing that appears above your
// cursor.
//
// Usage: swift scripts/make-icon.swift
//
import AppKit

let outputDir = "DogballWhisper/Assets.xcassets/AppIcon.appiconset"

/// Bar heights as a fraction of the glyph height, mirrored around the centre.
/// Deliberately few and chunky: at 16pt a detailed waveform turns to mush, and
/// this silhouette still reads as "sound" at that size.
let barScale: [CGFloat] = [0.34, 0.62, 1.0, 0.72, 0.44]

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS icons sit inside their canvas rather than filling it; roughly a
    // 10% inset with a continuous-corner radius matches the system look.
    let inset = size * 0.098
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237

    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Blue gradient, lighter at the top, matching the panel's systemBlue bars.
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.24, green: 0.55, blue: 1.00, alpha: 1),
        ending: NSColor(srgbRed: 0.04, green: 0.31, blue: 0.86, alpha: 1))
    gradient?.draw(in: squircle, angle: -90)

    // A hairline inner edge keeps the shape defined against a dark wallpaper.
    NSColor.white.withAlphaComponent(0.16).setStroke()
    squircle.lineWidth = max(1, size * 0.004)
    squircle.stroke()

    // The waveform.
    let barWidth = rect.width * 0.082
    let gap = barWidth * 0.72
    let totalWidth = barWidth * CGFloat(barScale.count) + gap * CGFloat(barScale.count - 1)
    let maxBarHeight = rect.height * 0.46
    var x = rect.midX - totalWidth / 2

    NSColor.white.setFill()
    for scale in barScale {
        let height = maxBarHeight * scale
        let bar = CGRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }

    return image
}

func writePNG(_ image: NSImage, pixels: Int, to path: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// (point size, scale) pairs macOS expects in an AppIcon set.
let variants: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

try! FileManager.default.createDirectory(
    atPath: outputDir, withIntermediateDirectories: true)

var entries: [String] = []
for (point, scale) in variants {
    let pixels = point * scale
    let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
    // Redraw at the target size rather than downscaling one big render: the
    // small sizes need the strokes and radii recomputed to stay crisp.
    writePNG(drawIcon(size: CGFloat(pixels)), pixels: pixels, to: "\(outputDir)/\(name)")
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(point)x\(point)"
        }
    """)
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try! contents.write(toFile: "\(outputDir)/Contents.json", atomically: true, encoding: .utf8)
print("wrote \(variants.count) images to \(outputDir)")
