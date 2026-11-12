// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import QuartzCore

/// The indicator shown while a fix is in flight: a small glass capsule at the bottom centre of the
/// screen, with three white dots and a liquid drop that runs between them (see `PillScene`).
/// Every AI action has a network wait in the middle of it, and one moving thing is the difference
/// between "it is working" and "it is stuck".
///
/// It is always in the same place, so the eye finds it without a search, and it never covers the
/// text being fixed. The screen is the one with the caret, or with the mouse pointer when the app
/// publishes no caret.
///
/// It has two stages. The capsule comes up with still, dim dots the instant the hotkey is pressed,
/// and answers "did my key register?". The drop starts to move once the request is out, and
/// answers "is it stuck?".
///
/// The capsule is system glass: Liquid Glass on macOS 26 and later, the HUD material before.
/// Core Animation scales and fades it in the window server. The dots are drawn on a thread of
/// their own, because the capture can hold the main thread for most of a second while the capsule
/// is on screen, and the dots must not stop.
///
/// Under Reduce Motion nothing moves or scales: the capsule fades in and out, and the dots fade
/// one after the other in place.
///
/// The panel is borderless, click-through and non-activating, joins every Space, and stays out of
/// Cmd+Tab and out of Mission Control.
final class ProgressPill {
    static let shared = ProgressPill()

    private var panel: NSPanel?
    private var stage: NSView?
    private var animator: PillAnimator?
    private var visible = false
    private var working = false
    private var generation = 0

    private init() {}

    /// - Parameter working: false for the quiet stage shown during the capture, true once the
    ///   request is in flight. Calling `show` again only promotes; it never moves the pill or
    ///   restarts the entrance.
    func show(near caretRect: CGRect?, working: Bool) {
        let panel = ensurePanel()
        let now = CACurrentMediaTime()
        if !visible {
            visible = true
            self.working = false
            generation += 1
            let reduced = Motion.reduced
            panel.setFrameOrigin(origin(near: caretRect, size: panel.frame.size))
            enter(reduced: reduced)
            panel.orderFrontRegardless()
            animator?.start(
                PillScene.Timeline(shownAt: now, workingAt: nil, hidingAt: nil, reduced: reduced),
                generation: generation,
                scale: panel.screen?.backingScaleFactor ?? 2)
            // The capture that follows can hold the main thread. Send the entrance to the window
            // server now, so it plays while the user waits.
            CATransaction.flush()
        }
        if working, !self.working {
            self.working = true
            animator?.promote(at: now)
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        working = false
        exit(reduced: Motion.reduced)
        animator?.hide(at: CACurrentMediaTime())
        // The paste that follows can hold the main thread, as the capture does.
        CATransaction.flush()
    }

    /// Called at shutdown so the panel does not outlive the run loop it animates on.
    func shutdown() {
        animator?.stop()
        panel?.orderOut(nil)
        visible = false
        working = false
    }

    private func finished(_ generation: Int) {
        guard generation == self.generation, !visible else { return }
        panel?.orderOut(nil)
    }

    // ---- the panel ----

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let margin = PillScene.margin
        let size = NSSize(width: PillScene.width + margin * 2, height: PillScene.height + margin * 2)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true  // never intercept a click
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        // The pill is decoration for a state the menu bar item also reports, and it is in nobody's
        // focus order. Keeping it out of the accessibility tree stops VoiceOver announcing an
        // unlabelled window every time a fix starts.
        panel.setAccessibilityElement(false)

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        panel.contentView = content

        let stage = NSView(frame: content.bounds)
        stage.wantsLayer = true
        content.addSubview(stage)
        let capsule = NSRect(x: margin, y: margin, width: PillScene.width, height: PillScene.height)
        stage.addSubview(makeBackdrop(frame: capsule))

        // A layer-hosting view: the layer belongs to this code, not to AppKit, so the animation
        // thread can change its contents.
        let dots = CALayer()
        let dotsHost = NSView(frame: capsule)
        dotsHost.layer = dots
        dotsHost.wantsLayer = true
        stage.addSubview(dotsHost)

        animator = PillAnimator(layer: dots, view: content) { [weak self] generation in
            self?.finished(generation)
        }
        self.panel = panel
        self.stage = stage
        return panel
    }

    private func makeBackdrop(frame: NSRect) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = frame.height / 2
            return glass
        }
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active  // the panel is never key, and an inactive material is flat grey
        let side = frame.height
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: side / 2, left: side / 2, bottom: side / 2, right: side / 2)
        mask.resizingMode = .stretch
        effect.maskImage = mask
        return effect
    }

    // ---- entrance and exit, in the window server ----

    private func enter(reduced: Bool) {
        guard let stage, let layer = stage.layer else { return }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = reduced ? PillScene.reducedFadeDuration : 0.10
        layer.add(fade, forKey: "fade")
        guard !reduced else { return }

        // The same spring as the other agents: a period of 0.42 s, a damping ratio of 0.62.
        let pop = CASpringAnimation(keyPath: "transform")
        pop.fromValue = NSValue(caTransform3D: scaled(layer, 0.5))
        pop.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        pop.mass = 1
        pop.stiffness = 224
        pop.damping = 18.5
        pop.duration = pop.settlingDuration
        layer.add(pop, forKey: "scale")
    }

    private func exit(reduced: Bool) {
        guard let stage, let layer = stage.layer else { return }
        // Start from where the entrance is now, in case the pill leaves before it has arrived.
        let opacity = layer.presentation()?.opacity ?? 1
        let transform = layer.presentation()?.transform ?? CATransform3DIdentity
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        CATransaction.commit()

        if reduced {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity
            fade.toValue = 0
            fade.duration = PillScene.reducedFadeDuration
            layer.add(fade, forKey: "fade")
            return
        }
        // The dots melt back into one drop first, then the capsule shrinks and goes.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [opacity, opacity, 0]
        fade.keyTimes = [0, 0.2, 1]
        fade.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeIn)]
        fade.duration = PillScene.exitDuration
        layer.add(fade, forKey: "fade")

        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: transform)
        shrink.toValue = NSValue(caTransform3D: scaled(layer, 0.5))
        shrink.duration = PillScene.exitDuration
        shrink.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 1, 0.45)
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        layer.add(shrink, forKey: "scale")
    }

    /// A scale about the centre of the layer, whatever anchor point AppKit gave it.
    private func scaled(_ layer: CALayer, _ s: CGFloat) -> CATransform3D {
        let px = layer.bounds.width * (0.5 - layer.anchorPoint.x)
        let py = layer.bounds.height * (0.5 - layer.anchorPoint.y)
        var t = CATransform3DMakeTranslation(px, py, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -px, -py, 0)
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

    /// The bottom centre of the usable part of the screen the user works on, above the Dock.
    private func origin(near caretRect: CGRect?, size: NSSize) -> NSPoint {
        var point = NSEvent.mouseLocation
        if let caretRect, caretRect.height > 0 {
            let caret = appKitRect(fromQuartz: caretRect)
            point = NSPoint(x: caret.midX, y: caret.midY)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? .zero
        return NSPoint(
            x: (frame.midX - size.width / 2).rounded(),
            y: (frame.minY + PillScene.bottomGap - PillScene.margin).rounded())
    }
}

/// Draws the dots on a thread of its own, at the refresh rate of the display (60 frames a second
/// at most). It sleeps when nothing moves: in the quiet stage after the entrance, and when the
/// pill is off the screen.
///
/// All state is owned by the thread. The main thread sends it blocks through its run loop.
private final class PillAnimator: NSObject {
    private let layer: CALayer
    private let finished: (Int) -> Void
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    /// A CADisplayLink on macOS 14 and later, a Timer before.
    private var driver: AnyObject?

    // Owned by the animation thread.
    private var timeline: PillScene.Timeline?
    private var generation = 0
    private var scale: CGFloat = 2
    private var context: CGContext?
    private var running = false

    init(layer: CALayer, view: NSView, finished: @escaping (Int) -> Void) {
        self.layer = layer
        self.finished = finished
        super.init()
        let thread = Thread { [unowned self] in self.run() }
        thread.name = "TextFix.Indicator"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        if #available(macOS 14.0, *) {
            let link = view.displayLink(target: self, selector: #selector(step))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.isPaused = true
            driver = link
            perform { link.add(to: .current, forMode: .common) }
        }
    }

    func start(_ timeline: PillScene.Timeline, generation: Int, scale: CGFloat) {
        perform {
            self.timeline = timeline
            self.generation = generation
            self.scale = scale
            self.resume()
        }
    }

    func promote(at time: Double) {
        perform {
            self.timeline?.workingAt = time
            self.resume()
        }
    }

    func hide(at time: Double) {
        perform {
            self.timeline?.hidingAt = time
            self.resume()
        }
    }

    func stop() {
        perform {
            self.timeline = nil
            self.pause()
            self.show(nil)
        }
    }

    // ---- the animation thread ----

    private func run() {
        runLoop = CFRunLoopGetCurrent()
        // A run loop with no source returns at once. The port keeps this one alive.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while true {
            _ = autoreleasepool { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
    }

    private func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func resume() {
        step()
        guard timeline != nil, !running else { return }
        running = true
        if #available(macOS 14.0, *), let link = driver as? CADisplayLink {
            link.isPaused = false
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
            RunLoop.current.add(timer, forMode: .common)
            driver = timer
        }
    }

    private func pause() {
        guard running else { return }
        running = false
        if #available(macOS 14.0, *), let link = driver as? CADisplayLink {
            link.isPaused = true
        } else {
            (driver as? Timer)?.invalidate()
            driver = nil
        }
    }

    @objc private func step() {
        guard let timeline else {
            pause()
            return
        }
        let frame = PillScene.frame(at: CACurrentMediaTime(), timeline)
        if frame.finished {
            self.timeline = nil
            pause()
            show(nil)
            let generation = self.generation
            DispatchQueue.main.async { self.finished(generation) }
            return
        }
        show(draw(frame))
        if frame.settled { pause() }
    }

    private func draw(_ frame: PillScene.Frame) -> CGImage? {
        let width = Int((PillScene.width * scale).rounded())
        let height = Int((PillScene.height * scale).rounded())
        if context?.width != width || context?.height != height {
            context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        }
        guard let context, let data = context.data else { return nil }
        PillScene.render(frame, into: data.bindMemory(to: UInt32.self, capacity: width * height),
                         width: width, height: height, scale: Double(scale))
        return context.makeImage()
    }

    /// An explicit transaction, so the change reaches the screen from this thread without the
    /// main run loop.
    private func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = scale
        layer.contents = image
        CATransaction.commit()
    }
}
