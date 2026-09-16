// SPDX-License-Identifier: GPL-3.0-only
//
// Generates the .iconset that build-mac.sh feeds to iconutil.
//
//     swift Tools/makeicon.swift <output.iconset directory>
//
// Kept in the repo so the icon is reproducible rather than a binary someone has to trust, and
// drawn with the same geometry as tools/make-icon.py on the Windows side so the two platforms ship
// one identity. AppKit does the rasterising, so unlike the Python generator this needs nothing
// installed beyond the Swift toolchain that already built the app.
import AppKit
import Foundation

let background = NSColor(calibratedRed: 58 / 255, green: 54 / 255, blue: 196 / 255, alpha: 1)
let backgroundEdge = NSColor(calibratedRed: 40 / 255, green: 37 / 255, blue: 150 / 255, alpha: 1)
let glyph = NSColor.white

/// One icon at an exact pixel size. `withTextLines` adds the two faint lines that read as text
/// behind the check; below 48 px they turn into grey mush and hurt legibility, so they are dropped.
func drawIcon(pixels: Int, withTextLines: Bool) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(pixels)

    // Rounded tile, inset slightly so the corners are not clipped by the icon bounds.
    let inset = s * 0.03
    let tile = NSBezierPath(
        roundedRect: NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2),
        xRadius: s * 0.22,
        yRadius: s * 0.22)
    background.setFill()
    tile.fill()
    backgroundEdge.setStroke()
    tile.lineWidth = max(1, s * 0.02)
    tile.stroke()

    // AppKit's origin is bottom-left, so every y below is 1 - the value the Python generator uses.
    if withTextLines {
        NSColor(calibratedWhite: 1, alpha: 110 / 255).setStroke()
        for (xEnd, y) in [(0.62, 0.70), (0.50, 0.54)] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: s * 0.22, y: s * CGFloat(y)))
            line.line(to: NSPoint(x: s * CGFloat(xEnd), y: s * CGFloat(y)))
            line.lineWidth = s * 0.075
            line.lineCapStyle = .butt
            line.stroke()
        }
    }

    let check = NSBezierPath()
    check.move(to: NSPoint(x: s * 0.26, y: s * 0.40))
    check.line(to: NSPoint(x: s * 0.44, y: s * 0.23))
    check.line(to: NSPoint(x: s * 0.76, y: s * 0.69))
    check.lineWidth = s * (pixels >= 32 ? 0.115 : 0.135)
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    glyph.setStroke()
    check.stroke()

    return rep.representation(using: .png, properties: [:])
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: makeicon.swift <output.iconset>\n".utf8))
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// The names iconutil expects. Each entry is (logical point size, scale).
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

for variant in variants {
    let pixels = variant.points * variant.scale
    guard let data = drawIcon(pixels: pixels, withTextLines: pixels >= 48) else {
        FileHandle.standardError.write(Data("could not render \(pixels) px\n".utf8))
        exit(1)
    }
    let suffix = variant.scale == 2 ? "@2x" : ""
    let name = "icon_\(variant.points)x\(variant.points)\(suffix).png"
    try data.write(to: outputDirectory.appendingPathComponent(name))
}

print("wrote \(variants.count) sizes to \(outputDirectory.path)")
