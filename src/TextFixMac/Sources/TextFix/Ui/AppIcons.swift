// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// The app's artwork, drawn in code rather than shipped as assets.
///
/// A menu bar icon has to be a template image - a black-and-alpha glyph that macOS tints itself -
/// or it will be wrong in half the situations it appears in: light menu bar, dark menu bar,
/// highlighted while the menu is open, and reduced-contrast mode. Drawing it means it is a vector
/// at every scale factor and there is no asset catalog to keep in step with the Windows .ico.
enum AppIcons {
    /// The menu bar glyph: the same rounded tile and check mark as the Windows tray icon, reduced
    /// to a line drawing so it reads at 18 points on both a light and a dark menu bar.
    static let statusBar: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            drawGlyph(in: size, strokeColor: .black)
            return true
        }
        // The one thing that makes a menu bar icon behave: macOS owns the colour, not us.
        image.isTemplate = true
        image.accessibilityDescription = "TextFix"
        return image
    }()

    private static func drawGlyph(in size: NSSize, strokeColor: NSColor) {
        let w = size.width
        let h = size.height
        strokeColor.setStroke()

        // Rounded tile, inset so the stroke sits inside the image bounds rather than being clipped.
        let tileInset = w * 0.055
        let tile = NSBezierPath(
            roundedRect: NSRect(x: tileInset, y: tileInset, width: w - tileInset * 2, height: h - tileInset * 2),
            xRadius: w * 0.26,
            yRadius: h * 0.26)
        tile.lineWidth = max(1, w * 0.085)
        tile.stroke()

        // The check mark. AppKit's origin is bottom-left, so the y values run the other way round
        // from the Python generator that draws the Windows icon.
        let check = NSBezierPath()
        check.move(to: NSPoint(x: w * 0.29, y: h * 0.50))
        check.line(to: NSPoint(x: w * 0.44, y: h * 0.34))
        check.line(to: NSPoint(x: w * 0.73, y: h * 0.67))
        check.lineWidth = max(1, w * 0.115)
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.stroke()
    }
}
