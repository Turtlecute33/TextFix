// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import QuartzCore

/// The indicator shown next to the caret while a fix is in flight: a small dark capsule with a
/// light sweeping through it. Every AI action has a network wait in the middle of it, and one
/// moving thing is the difference between "it is working" and "it is stuck".
///
/// It is drawn rather than composed of controls because it has to be legible on an unknown
/// background - a white document, a black editor, a photo - so it brings its own contrast: a dark
/// capsule with a soft drop shadow and a hairline rim, and a bright indeterminate sweep inside it.
/// It sits *below* the caret rather than beside it, so it never covers the text being fixed.
///
/// The panel is borderless, click-through and non-activating, joins every Space, and stays out of
/// Cmd+Tab and out of Mission Control. The sweep is a Core Animation animation on a masked gradient
/// layer, so it runs on the window server: unlike the Windows agent's 60 fps repaint timer, the
/// app's own process does no work at all for the whole time the pill is on screen.
final class CaretPulse {
    static let shared = CaretPulse()

    private let pillSize = NSSize(width: 58, height: 16)
    /// Headroom for the drop shadow, which has to live inside the window's own bounds.
    private let margin: CGFloat = 12
    private let gapBelowCaret: CGFloat = 7
    private let sweepPeriod: CFTimeInterval = 1.15
    private let fadeIn = 0.15
    private let fadeOut = 0.13

    private var panel: NSPanel?
    private var sweepLayer: CAGradientLayer?
    private var visible = false

    private init() {}

    func show(caretRect: CGRect?) {
        let panel = ensurePanel()
        let origin = position(for: caretRect, windowSize: panel.frame.size)
        panel.setFrameOrigin(origin)

        if !visible {
            visible = true
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            startSweep()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeIn
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard visible, let panel else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.visible else { return }
            panel.orderOut(nil)
            self.stopSweep()
        })
    }

    /// Called at shutdown so the panel does not outlive the run loop it animates on.
    func shutdown() {
        stopSweep()
        panel?.orderOut(nil)
        panel = nil
        sweepLayer = nil
        visible = false
    }

    // ---- the panel ----

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let size = NSSize(width: pillSize.width + margin * 2, height: pillSize.height + margin * 2)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // we draw a softer one ourselves
        panel.ignoresMouseEvents = true  // never intercept a click
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        panel.contentView = content
        buildLayers(in: content)

        self.panel = panel
        return panel
    }

    private func buildLayers(in view: NSView) {
        guard let root = view.layer else { return }
        let pillFrame = CGRect(x: margin, y: margin, width: pillSize.width, height: pillSize.height)
        let radius = pillSize.height / 2

        let capsule = CALayer()
        capsule.frame = pillFrame
        capsule.cornerRadius = radius
        capsule.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.93).cgColor
        capsule.borderWidth = 1
        // A hairline rim is what keeps the capsule from dissolving into a dark editor background.
        capsule.borderColor = NSColor(calibratedWhite: 1, alpha: 0.22).cgColor
        capsule.shadowColor = NSColor.black.cgColor
        capsule.shadowOpacity = 0.35
        capsule.shadowRadius = 5
        capsule.shadowOffset = CGSize(width: 0, height: -1)
        capsule.masksToBounds = false
        root.addSublayer(capsule)

        // The sweep lives in its own clipped layer so the gradient can travel past both ends of the
        // capsule without painting outside it.
        let clip = CALayer()
        clip.frame = pillFrame
        clip.cornerRadius = radius
        clip.masksToBounds = true
        root.addSublayer(clip)

        let sweepWidth = pillSize.width * 0.5
        let sweep = CAGradientLayer()
        sweep.frame = CGRect(x: -sweepWidth, y: 0, width: sweepWidth, height: pillSize.height)
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.colors = [
            NSColor(calibratedWhite: 1, alpha: 0).cgColor,
            NSColor(calibratedWhite: 1, alpha: 0.85).cgColor,
            NSColor(calibratedWhite: 1, alpha: 0).cgColor,
        ]
        sweep.locations = [0, 0.5, 1]
        clip.addSublayer(sweep)
        sweepLayer = sweep
    }

    private func startSweep() {
        guard let sweep = sweepLayer else { return }
        let travel = pillSize.width + sweep.bounds.width
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = -sweep.bounds.width / 2
        animation.toValue = travel - sweep.bounds.width / 2
        animation.duration = sweepPeriod
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        sweep.add(animation, forKey: "sweep")
    }

    private func stopSweep() {
        sweepLayer?.removeAnimation(forKey: "sweep")
    }

    // ---- placement ----

    /// Converts a Quartz screen rectangle (origin top-left, y down - what the Accessibility API
    /// reports) into the AppKit screen space the window server positions windows in (origin
    /// bottom-left of the display that carries the menu bar, y up).
    private func appKitRect(fromQuartz rect: CGRect) -> NSRect {
        let reference = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        let height = reference?.frame.height ?? 0
        return NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func position(for caretRect: CGRect?, windowSize: NSSize) -> NSPoint {
        var x: CGFloat
        var y: CGFloat

        if let caretRect, caretRect.height > 0 {
            let caret = appKitRect(fromQuartz: caretRect)
            x = caret.midX - windowSize.width / 2
            y = caret.minY - gapBelowCaret - windowSize.height + margin
        } else {
            // Apps that publish no caret position get the pill next to the mouse pointer, which is
            // the only other place the user is certainly looking.
            let mouse = NSEvent.mouseLocation
            x = mouse.x - windowSize.width / 2
            y = mouse.y - gapBelowCaret - windowSize.height
        }

        let anchor = NSPoint(x: x + windowSize.width / 2, y: y + windowSize.height / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            x = min(max(x, frame.minX), max(frame.minX, frame.maxX - windowSize.width))
            y = min(max(y, frame.minY), max(frame.minY, frame.maxY - windowSize.height))
        }
        return NSPoint(x: x.rounded(), y: y.rounded())
    }
}
