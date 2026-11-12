// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The size and the motion of the progress pill, without a drawing system. The Windows agent
/// (Ui/ProgressPill.cs) and the Linux agent (src/pillscene.cpp) use the same numbers and the same
/// functions, so the three agents show the same animation. Change them together.
///
/// The pill is a glass capsule with three white dots. While TextFix reads the text, the dots are
/// still and dim. While the request runs, a liquid drop moves from dot to dot and stretches as it
/// moves. Shapes that come near each other melt together (a smooth minimum of their distances),
/// so the drop goes into each dot and comes out again like a liquid.
enum PillScene {
    // Sizes in points.
    static let width = 96.0
    static let height = 32.0
    /// Room around the capsule for the shadow and for the spring, which goes past full size.
    static let margin = 22.0
    /// From the bottom of the usable screen (above the Dock or the taskbar) to the capsule.
    static let bottomGap = 63.0
    static let dotRadius = 4.0
    static let dotSpacing = 12.75

    static let exitDuration = 0.36
    static let reducedFadeDuration = 0.15

    /// Times from `CACurrentMediaTime()`.
    struct Timeline {
        var shownAt: Double
        var workingAt: Double?
        var hidingAt: Double?
        var reduced: Bool
    }

    /// A line from a to b with round ends of radius r. A dot when a and b are the same point.
    struct Shape {
        var ax, ay, bx, by, r, alpha: Double
    }

    struct Frame {
        var shapes: [Shape] = []
        /// How near two shapes must be to melt together. Zero: no melting, each shape has its alpha.
        var goo = 0.0
        var alpha = 1.0
        /// The exit is complete. Take the window off the screen.
        var finished = false
        /// Nothing changes until the next stage, so no more frames are necessary.
        var settled = false
    }

    private static let xs = [-dotSpacing, 0, dotSpacing]

    static func frame(at now: Double, _ t: Timeline) -> Frame {
        var f = Frame()
        let amp = t.workingAt.map { smoothstep((now - $0) / 0.35) } ?? 0
        let run = t.workingAt.map { now - $0 } ?? 0
        f.alpha = mix(0.55, 1, amp)

        if t.reduced {
            // Nothing moves. The dots fade one after the other.
            f.shapes = (0..<3).map { i in
                let wave = 0.5 - 0.5 * cos(2 * .pi * (run / 1.5 - Double(i) / 3))
                return dot(xs[i], dotRadius, mix(1, 0.3 + 0.7 * wave, amp))
            }
            if let h = t.hidingAt { f.finished = now - h >= reducedFadeDuration }
            f.settled = t.workingAt == nil && t.hidingAt == nil && now - t.shownAt > reducedFadeDuration
            return f
        }

        (f.shapes, f.goo) = chase(run, amp)
        // The dots come out of one drop at the start, and go back into it at the end.
        var gather = spring(now - t.shownAt - 0.10, response: 0.40, damping: 0.72)
        if let h = t.hidingAt {
            let x = (now - h) / exitDuration
            if x >= 1 {
                f.finished = true
                f.shapes = []
                return f
            }
            gather *= 1 - easeInOut(x * 1.6)
        }
        if gather != 1 {
            let shrink = min(1, clamp01(gather * 1.4).squareRoot())
            for i in f.shapes.indices {
                f.shapes[i].ax *= gather
                f.shapes[i].bx *= gather
                f.shapes[i].ay *= gather
                f.shapes[i].by *= gather
                f.shapes[i].r *= shrink
            }
            f.goo = max(f.goo, dotRadius * 2.4 * (1 - clamp01(gather)))
        }
        f.settled = t.workingAt == nil && t.hidingAt == nil && now - t.shownAt > 1.2
        return f
    }

    /// The drop runs 0 → 1 → 2 → 1 → 0. Its front moves fast and its back follows, so it
    /// stretches on the way and becomes round again when it arrives. In the quiet stage the drop
    /// has no size, so the three dots are the same.
    private static func chase(_ run: Double, _ amp: Double) -> ([Shape], Double) {
        let path = [0, 1, 2, 1]
        let n = run / 0.40
        let k = Int(n.rounded(.down))
        let m = clamp01((n - n.rounded(.down)) * 1.3)
        let from = xs[path[k % 4]], to = xs[path[(k + 1) % 4]]
        let head = mix(from, to, easeOutCubic(m))
        let tail = mix(from, to, easeInCubic(m))
        let stretch = abs(head - tail) / dotSpacing
        var shapes = xs.map { dot($0, dotRadius * mix(1, 0.6, amp), 1) }
        shapes.append(Shape(ax: tail, ay: 0, bx: head, by: 0,
                            r: dotRadius * mix(0, 1.3, amp) * (1 - 0.15 * stretch), alpha: 1))
        return (shapes, dotRadius * 1.5)
    }

    /// Draws the dots of one frame into a premultiplied BGRA bitmap that covers the capsule.
    /// The glass under them comes from the system. A soft dark edge keeps the white dots
    /// visible on light glass.
    static func render(_ f: Frame, into px: UnsafeMutablePointer<UInt32>, width: Int, height: Int, scale: Double) {
        let aa = 1 / scale
        let cx = Double(width) / 2, cy = Double(height) / 2
        for y in 0..<height {
            let py = (cy - (Double(y) + 0.5)) / scale
            for x in 0..<width {
                let pxl = (Double(x) + 0.5 - cx) / scale
                let clip = clamp01(0.5 - (capsuleDistance(pxl, py) + 1.6) / aa)
                var a = 0.0, c = 0.0
                if clip > 0, !f.shapes.isEmpty {
                    if f.goo > 0 {
                        var d = 1e9, alpha = 0.0
                        for s in f.shapes {
                            d = smin(d, distance(pxl, py, s), f.goo)
                            alpha = max(alpha, s.alpha)
                        }
                        (c, a) = blend(d, alpha * f.alpha * clip, aa, c, a)
                    } else {
                        for s in f.shapes {
                            (c, a) = blend(distance(pxl, py, s), s.alpha * f.alpha * clip, aa, c, a)
                        }
                    }
                }
                px[y * width + x] = UInt32(a * 255) << 24 | UInt32(c * 255) * 0x010101
            }
        }
    }

    /// A white dot over a soft dark edge, composited over (c, a) in premultiplied grey.
    @inline(__always)
    private static func blend(_ d: Double, _ alpha: Double, _ aa: Double, _ c: Double, _ a: Double) -> (Double, Double) {
        let edge = 0.22 * alpha * clamp01(1 - max(d, 0) / 1.8)
        var c = c * (1 - edge), a = edge + a * (1 - edge)
        let cover = clamp01(0.5 - d / aa) * alpha
        c = cover + c * (1 - cover)
        a = cover + a * (1 - cover)
        return (c, a)
    }

    // ---- shared math: the same in C# and C++ ----

    private static func dot(_ x: Double, _ r: Double, _ alpha: Double) -> Shape {
        Shape(ax: x, ay: 0, bx: x, by: 0, r: r, alpha: alpha)
    }

    @inline(__always)
    private static func distance(_ px: Double, _ py: Double, _ s: Shape) -> Double {
        let bax = s.bx - s.ax, bay = s.by - s.ay
        let pax = px - s.ax, pay = py - s.ay
        let len2 = bax * bax + bay * bay
        let h = len2 > 0 ? clamp01((pax * bax + pay * bay) / len2) : 0
        let dx = pax - bax * h, dy = pay - bay * h
        return (dx * dx + dy * dy).squareRoot() - s.r
    }

    @inline(__always)
    private static func capsuleDistance(_ px: Double, _ py: Double) -> Double {
        let r = height / 2
        let dx = max(abs(px) - (width / 2 - r), 0)
        return (dx * dx + py * py).squareRoot() - r
    }

    /// Smooth minimum: two shapes nearer than k melt into one.
    @inline(__always)
    private static func smin(_ a: Double, _ b: Double, _ k: Double) -> Double {
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k * 0.25
    }

    /// A damped spring from 0 to 1. `response` is the period, `damping` the damping ratio.
    static func spring(_ t: Double, response: Double, damping: Double) -> Double {
        guard t > 0 else { return 0 }
        let w0 = 2 * Double.pi / response
        let wd = w0 * (1 - damping * damping).squareRoot()
        return 1 - exp(-damping * w0 * t) * (cos(wd * t) + damping * w0 / wd * sin(wd * t))
    }

    @inline(__always) private static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
    @inline(__always) private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func smoothstep(_ x: Double) -> Double { let t = clamp01(x); return t * t * (3 - 2 * t) }
    private static func easeOutCubic(_ x: Double) -> Double { let t = clamp01(x); return 1 - pow(1 - t, 3) }
    private static func easeInCubic(_ x: Double) -> Double { let t = clamp01(x); return t * t * t }
    private static func easeInOut(_ x: Double) -> Double {
        let t = clamp01(x)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
