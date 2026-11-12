// SPDX-License-Identifier: GPL-3.0-only
using System.Runtime.CompilerServices;

namespace TextFix.Ui;

/// <summary>
/// The size and the motion of the progress pill. The macOS agent (Ui/PillScene.swift) and the
/// Linux agent (src/pillscene.cpp) use the same numbers and the same functions, so the three
/// agents show the same animation. Change them together.
///
/// The pill is a glass capsule with three white dots. While TextFix reads the text, the dots are
/// still and dim. While the request runs, a liquid drop moves from dot to dot and stretches as it
/// moves. Shapes that come near each other melt together (a smooth minimum of their distances),
/// so the drop goes into each dot and comes out again like a liquid.
///
/// Windows has no system glass for a click-through layered window, so the capsule is drawn: dark
/// tinted glass with a soft shadow and a rim that is bright at the top. It is legible on a white
/// document, a black editor or a photo.
/// </summary>
internal static class PillScene
{
    // Sizes in DIPs.
    internal const double Width = 96;
    internal const double Height = 32;
    /// <summary>Room around the capsule for the shadow and for the spring, which goes past full size.</summary>
    internal const double Margin = 22;
    /// <summary>From the bottom of the work area (above the taskbar) to the capsule.</summary>
    internal const double BottomGap = 63;
    internal const double DotRadius = 4;
    internal const double DotSpacing = 12.75;

    internal const double ExitDuration = 0.36;
    internal const double ReducedFadeDuration = 0.15;

    private const double GlassAlpha = 0.68;

    private static readonly double[] Xs = [-DotSpacing, 0, DotSpacing];
    private static readonly int[] Path = [0, 1, 2, 1];

    /// <summary>Times in seconds from one monotonic clock.</summary>
    internal struct Timeline
    {
        public double ShownAt;
        public double? WorkingAt;
        public double? HidingAt;
        public bool Reduced;
    }

    /// <summary>A line from a to b with round ends of radius R. A dot when a and b are the same point.</summary>
    internal struct Shape
    {
        public double Ax, Ay, Bx, By, R, Alpha;
    }

    /// <summary>One frame. Made once and filled again for each frame, so drawing allocates nothing.</summary>
    internal sealed class Frame
    {
        public readonly Shape[] Shapes = new Shape[4];
        public int Count;
        /// <summary>How near two shapes must be to melt together. Zero: no melting.</summary>
        public double Goo;
        public double Alpha = 1;
        /// <summary>The exit is complete. Take the window off the screen.</summary>
        public bool Finished;
        /// <summary>Nothing changes until the next stage, so no more frames are necessary.</summary>
        public bool Settled;
    }

    internal static void FrameAt(double now, in Timeline t, Frame f)
    {
        double amp = t.WorkingAt is double w ? SmoothStep((now - w) / 0.35) : 0;
        double run = t.WorkingAt is double w2 ? now - w2 : 0;
        f.Alpha = Mix(0.55, 1, amp);
        f.Goo = 0;
        f.Finished = false;
        f.Settled = false;

        if (t.Reduced)
        {
            // Nothing moves. The dots fade one after the other.
            f.Count = 3;
            for (int i = 0; i < 3; i++)
            {
                double wave = 0.5 - 0.5 * Math.Cos(2 * Math.PI * (run / 1.5 - i / 3.0));
                f.Shapes[i] = Dot(Xs[i], DotRadius, Mix(1, 0.3 + 0.7 * wave, amp));
            }
            if (t.HidingAt is double h) f.Finished = now - h >= ReducedFadeDuration;
            f.Settled = t.WorkingAt is null && t.HidingAt is null && now - t.ShownAt > ReducedFadeDuration;
            return;
        }

        Chase(run, amp, f);
        // The dots come out of one drop at the start, and go back into it at the end.
        double gather = Spring(now - t.ShownAt - 0.10, 0.40, 0.72);
        if (t.HidingAt is double h2)
        {
            double x = (now - h2) / ExitDuration;
            if (x >= 1)
            {
                f.Finished = true;
                f.Count = 0;
                return;
            }
            gather *= 1 - EaseInOut(x * 1.6);
        }
        if (gather != 1)
        {
            double shrink = Math.Min(1, Math.Sqrt(Clamp01(gather * 1.4)));
            for (int i = 0; i < f.Count; i++)
            {
                ref Shape s = ref f.Shapes[i];
                s.Ax *= gather;
                s.Bx *= gather;
                s.Ay *= gather;
                s.By *= gather;
                s.R *= shrink;
            }
            f.Goo = Math.Max(f.Goo, DotRadius * 2.4 * (1 - Clamp01(gather)));
        }
        f.Settled = t.WorkingAt is null && t.HidingAt is null && now - t.ShownAt > 1.2;
    }

    /// <summary>
    /// The scale and the opacity of the whole capsule. On macOS, Core Animation plays the same
    /// curves: a spring from 50 % on the way in, a shrink to 50 % and a fade on the way out.
    /// </summary>
    internal static void Stage(double now, in Timeline t, out double scale, out double opacity)
    {
        double e = now - t.ShownAt;
        if (t.Reduced)
        {
            scale = 1;
            opacity = Clamp01(e / ReducedFadeDuration);
            if (t.HidingAt is double h)
            {
                double from = Clamp01((h - t.ShownAt) / ReducedFadeDuration);
                opacity = from * (1 - Clamp01((now - h) / ReducedFadeDuration));
            }
            return;
        }
        scale = Mix(0.5, 1, Spring(e, 0.42, 0.62));
        opacity = Clamp01(e / 0.10);
        if (t.HidingAt is double h2)
        {
            // Start from where the entrance is now, in case the pill leaves before it has arrived.
            double e0 = h2 - t.ShownAt;
            double scaleFrom = Mix(0.5, 1, Spring(e0, 0.42, 0.62));
            double opacityFrom = Clamp01(e0 / 0.10);
            double x = Clamp01((now - h2) / ExitDuration);
            scale = Mix(scaleFrom, 0.5, x * x * x);
            double fade = Clamp01((x - 0.2) / 0.8);
            opacity = opacityFrom * (1 - fade * fade);
        }
    }

    /// <summary>
    /// The drop runs 0 → 1 → 2 → 1 → 0. Its front moves fast and its back follows, so it
    /// stretches on the way and becomes round again when it arrives. In the quiet stage the drop
    /// has no size, so the three dots are the same.
    /// </summary>
    private static void Chase(double run, double amp, Frame f)
    {
        double n = run / 0.40;
        double floor = Math.Floor(n);
        int k = (int)floor;
        double m = Clamp01((n - floor) * 1.3);
        double from = Xs[Path[k % 4]], to = Xs[Path[(k + 1) % 4]];
        double head = Mix(from, to, EaseOutCubic(m));
        double tail = Mix(from, to, EaseInCubic(m));
        double stretch = Math.Abs(head - tail) / DotSpacing;
        for (int i = 0; i < 3; i++) f.Shapes[i] = Dot(Xs[i], DotRadius * Mix(1, 0.6, amp), 1);
        f.Shapes[3] = new Shape
        {
            Ax = tail, Ay = 0, Bx = head, By = 0,
            R = DotRadius * Mix(0, 1.3, amp) * (1 - 0.15 * stretch),
            Alpha = 1,
        };
        f.Count = 4;
        f.Goo = DotRadius * 1.5;
    }

    /// <summary>
    /// Draws the whole pill - shadow, glass, rim and dots - into a premultiplied BGRA surface, in
    /// one pass. Everything is a signed distance, which gives antialiased edges without clipping
    /// regions or extra bitmaps.
    /// </summary>
    internal static unsafe void Render(Frame f, double scale, double opacity, uint* pixels, int width, int height, double pixelsPerDip)
    {
        double unit = pixelsPerDip * Math.Max(scale, 0.01);
        double aa = 1 / unit;
        double cx = width / 2.0, cy = height / 2.0;
        double straight = Width / 2 - Height / 2;

        for (int y = 0; y < height; y++)
        {
            double py = (cy - (y + 0.5)) / unit;
            uint* row = pixels + y * width;
            for (int x = 0; x < width; x++)
            {
                double qx = (x + 0.5 - cx) / unit;
                double dc = CapsuleDistance(qx, py);
                if (dc > 12)
                {
                    row[x] = 0;
                    continue;
                }
                var p = new Pixel();

                // Shadow, under a capsule moved down a little.
                double ds = CapsuleDistance(qx, py + 1.6);
                if (ds < 10)
                {
                    double k = 1 - Clamp01(ds / 10);
                    p.Over(0, 0, 0, k * k * 0.30);
                }

                double cover = Clamp01(0.5 - dc / aa);
                if (cover > 0)
                {
                    // Tinted glass, a little lighter at the top.
                    double top = Clamp01(0.5 + py / Height);
                    double v = 0.06 + 0.06 * top;
                    p.Over(v, v + 0.005, v + 0.02, cover * GlassAlpha);
                    // The rim: bright at the top, a weak reflection at the bottom.
                    double nx = qx - Math.Clamp(qx, -straight, straight);
                    double ny = py / Math.Max(Math.Sqrt(nx * nx + py * py), 1e-4);
                    double band = Clamp01(1 - Math.Abs(dc + 0.8) / 0.9);
                    p.Over(1, 1, 1, band * cover * (0.10 + 0.42 * Math.Max(0, ny) + 0.14 * Math.Max(0, -ny)));
                }

                double clip = Clamp01(0.5 - (dc + 1.6) / aa);
                if (clip > 0 && f.Count > 0)
                {
                    if (f.Goo > 0)
                    {
                        double d = 1e9, alpha = 0;
                        for (int i = 0; i < f.Count; i++)
                        {
                            d = SmoothMin(d, Distance(qx, py, f.Shapes[i]), f.Goo);
                            alpha = Math.Max(alpha, f.Shapes[i].Alpha);
                        }
                        p.Dot(d, alpha * f.Alpha * clip, aa);
                    }
                    else
                    {
                        for (int i = 0; i < f.Count; i++)
                            p.Dot(Distance(qx, py, f.Shapes[i]), f.Shapes[i].Alpha * f.Alpha * clip, aa);
                    }
                }

                row[x] = p.Pack(opacity);
            }
        }
    }

    /// <summary>One premultiplied pixel, composited in place.</summary>
    private struct Pixel
    {
        private double _r, _g, _b, _a;

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void Over(double r, double g, double b, double a)
        {
            if (a <= 0.001) return;
            _r = r * a + _r * (1 - a);
            _g = g * a + _g * (1 - a);
            _b = b * a + _b * (1 - a);
            _a = a + _a * (1 - a);
        }

        /// <summary>A white dot over a soft dark edge, which keeps it visible on light glass.</summary>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void Dot(double d, double alpha, double aa)
        {
            Over(0, 0, 0, 0.22 * alpha * Clamp01(1 - Math.Max(d, 0) / 1.8));
            Over(1, 1, 1, Clamp01(0.5 - d / aa) * alpha);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public readonly uint Pack(double opacity) =>
            (uint)(Clamp01(_a * opacity) * 255 + 0.5) << 24
            | (uint)(Clamp01(_r * opacity) * 255 + 0.5) << 16
            | (uint)(Clamp01(_g * opacity) * 255 + 0.5) << 8
            | (uint)(Clamp01(_b * opacity) * 255 + 0.5);
    }

    // ---- shared math: the same in Swift and C++ ----

    private static Shape Dot(double x, double r, double alpha) =>
        new() { Ax = x, Ay = 0, Bx = x, By = 0, R = r, Alpha = alpha };

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static double Distance(double px, double py, in Shape s)
    {
        double bax = s.Bx - s.Ax, bay = s.By - s.Ay;
        double pax = px - s.Ax, pay = py - s.Ay;
        double len2 = bax * bax + bay * bay;
        double h = len2 > 0 ? Clamp01((pax * bax + pay * bay) / len2) : 0;
        double dx = pax - bax * h, dy = pay - bay * h;
        return Math.Sqrt(dx * dx + dy * dy) - s.R;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static double CapsuleDistance(double px, double py)
    {
        const double r = Height / 2;
        double dx = Math.Max(Math.Abs(px) - (Width / 2 - r), 0);
        return Math.Sqrt(dx * dx + py * py) - r;
    }

    /// <summary>Smooth minimum: two shapes nearer than k melt into one.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static double SmoothMin(double a, double b, double k)
    {
        double h = Math.Max(k - Math.Abs(a - b), 0) / k;
        return Math.Min(a, b) - h * h * k * 0.25;
    }

    /// <summary>A damped spring from 0 to 1. <paramref name="response"/> is the period.</summary>
    private static double Spring(double t, double response, double damping)
    {
        if (t <= 0) return 0;
        double w0 = 2 * Math.PI / response;
        double wd = w0 * Math.Sqrt(1 - damping * damping);
        return 1 - Math.Exp(-damping * w0 * t) * (Math.Cos(wd * t) + damping * w0 / wd * Math.Sin(wd * t));
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static double Clamp01(double x) => x < 0 ? 0 : x > 1 ? 1 : x;

    private static double Mix(double a, double b, double t) => a + (b - a) * t;
    private static double SmoothStep(double x) { double t = Clamp01(x); return t * t * (3 - 2 * t); }
    private static double EaseOutCubic(double x) { double t = 1 - Clamp01(x); return 1 - t * t * t; }
    private static double EaseInCubic(double x) { double t = Clamp01(x); return t * t * t; }

    private static double EaseInOut(double x)
    {
        double t = Clamp01(x);
        return t < 0.5 ? 4 * t * t * t : 1 - Math.Pow(-2 * t + 2, 3) / 2;
    }
}
