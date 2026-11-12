// SPDX-License-Identifier: GPL-3.0-only
#include "pillscene.h"
#include <algorithm>
#include <chrono>
#include <cmath>

namespace PillScene {
namespace {
constexpr double GlassAlpha = 0.68;
constexpr double Pi = 3.14159265358979323846;
constexpr double Xs[3] = {-DotSpacing, 0, DotSpacing};
constexpr int Path[4] = {0, 1, 2, 1};

inline double clamp01(double x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
inline double mix(double a, double b, double t) { return a + (b - a) * t; }
double smoothStep(double x) { const double t = clamp01(x); return t * t * (3 - 2 * t); }
double easeOutCubic(double x) { const double t = 1 - clamp01(x); return 1 - t * t * t; }
double easeInCubic(double x) { const double t = clamp01(x); return t * t * t; }
double easeInOut(double x) {
    const double t = clamp01(x);
    return t < 0.5 ? 4 * t * t * t : 1 - std::pow(-2 * t + 2, 3) / 2;
}

// A damped spring from 0 to 1. response is the period, damping the damping ratio.
double spring(double t, double response, double damping) {
    if (t <= 0) return 0;
    const double w0 = 2 * Pi / response;
    const double wd = w0 * std::sqrt(1 - damping * damping);
    return 1 - std::exp(-damping * w0 * t) * (std::cos(wd * t) + damping * w0 / wd * std::sin(wd * t));
}

Shape dot(double x, double r, double alpha) { return {x, 0, x, 0, r, alpha}; }

inline double distance(double px, double py, const Shape &s) {
    const double bax = s.bx - s.ax, bay = s.by - s.ay;
    const double pax = px - s.ax, pay = py - s.ay;
    const double len2 = bax * bax + bay * bay;
    const double h = len2 > 0 ? clamp01((pax * bax + pay * bay) / len2) : 0;
    const double dx = pax - bax * h, dy = pay - bay * h;
    return std::sqrt(dx * dx + dy * dy) - s.r;
}

inline double capsuleDistance(double px, double py) {
    constexpr double r = Height / 2;
    const double dx = std::max(std::abs(px) - (Width / 2 - r), 0.0);
    return std::sqrt(dx * dx + py * py) - r;
}

// Smooth minimum: two shapes nearer than k melt into one.
inline double smoothMin(double a, double b, double k) {
    const double h = std::max(k - std::abs(a - b), 0.0) / k;
    return std::min(a, b) - h * h * k * 0.25;
}

// The drop runs 0 → 1 → 2 → 1 → 0. Its front moves fast and its back follows, so it
// stretches on the way and becomes round again when it arrives. In the quiet stage the drop
// has no size, so the three dots are the same.
void chase(double run, double amp, Frame &f) {
    const double n = run / 0.40;
    const double floor = std::floor(n);
    const int k = int(floor);
    const double m = clamp01((n - floor) * 1.3);
    const double from = Xs[Path[k % 4]], to = Xs[Path[(k + 1) % 4]];
    const double head = mix(from, to, easeOutCubic(m));
    const double tail = mix(from, to, easeInCubic(m));
    const double stretch = std::abs(head - tail) / DotSpacing;
    for (int i = 0; i < 3; ++i) f.shapes[i] = dot(Xs[i], DotRadius * mix(1, 0.6, amp), 1);
    f.shapes[3] = {tail, 0, head, 0, DotRadius * mix(0, 1.3, amp) * (1 - 0.15 * stretch), 1};
    f.count = 4;
    f.goo = DotRadius * 1.5;
}

// One premultiplied pixel, composited in place.
struct Pixel {
    double r = 0, g = 0, b = 0, a = 0;
    void over(double cr, double cg, double cb, double ca) {
        if (ca <= 0.001) return;
        r = cr * ca + r * (1 - ca);
        g = cg * ca + g * (1 - ca);
        b = cb * ca + b * (1 - ca);
        a = ca + a * (1 - ca);
    }
    // A white dot over a soft dark edge, which keeps it visible on light glass.
    void dotAt(double d, double alpha, double aa) {
        over(0, 0, 0, 0.22 * alpha * clamp01(1 - std::max(d, 0.0) / 1.8));
        over(1, 1, 1, clamp01(0.5 - d / aa) * alpha);
    }
    uint32_t pack(double opacity) const {
        auto byte = [opacity](double v) { return uint32_t(clamp01(v * opacity) * 255 + 0.5); };
        return byte(a) << 24 | byte(r) << 16 | byte(g) << 8 | byte(b);
    }
};
}

double now() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

void frameAt(double now, const Timeline &t, Frame &f) {
    const double amp = t.workingAt ? smoothStep((now - *t.workingAt) / 0.35) : 0;
    const double run = t.workingAt ? now - *t.workingAt : 0;
    f.alpha = mix(0.55, 1, amp);
    f.goo = 0;
    f.finished = false;
    f.settled = false;

    if (t.reduced) {
        // Nothing moves. The dots fade one after the other.
        f.count = 3;
        for (int i = 0; i < 3; ++i) {
            const double wave = 0.5 - 0.5 * std::cos(2 * Pi * (run / 1.5 - i / 3.0));
            f.shapes[i] = dot(Xs[i], DotRadius, mix(1, 0.3 + 0.7 * wave, amp));
        }
        if (t.hidingAt) f.finished = now - *t.hidingAt >= ReducedFadeDuration;
        f.settled = !t.workingAt && !t.hidingAt && now - t.shownAt > ReducedFadeDuration;
        return;
    }

    chase(run, amp, f);
    // The dots come out of one drop at the start, and go back into it at the end.
    double gather = spring(now - t.shownAt - 0.10, 0.40, 0.72);
    if (t.hidingAt) {
        const double x = (now - *t.hidingAt) / ExitDuration;
        if (x >= 1) {
            f.finished = true;
            f.count = 0;
            return;
        }
        gather *= 1 - easeInOut(x * 1.6);
    }
    if (gather != 1) {
        const double shrink = std::min(1.0, std::sqrt(clamp01(gather * 1.4)));
        for (int i = 0; i < f.count; ++i) {
            Shape &s = f.shapes[i];
            s.ax *= gather;
            s.bx *= gather;
            s.ay *= gather;
            s.by *= gather;
            s.r *= shrink;
        }
        f.goo = std::max(f.goo, DotRadius * 2.4 * (1 - clamp01(gather)));
    }
    f.settled = !t.workingAt && !t.hidingAt && now - t.shownAt > 1.2;
}

void stage(double now, const Timeline &t, double &scale, double &opacity) {
    const double e = now - t.shownAt;
    if (t.reduced) {
        scale = 1;
        opacity = clamp01(e / ReducedFadeDuration);
        if (t.hidingAt) {
            const double from = clamp01((*t.hidingAt - t.shownAt) / ReducedFadeDuration);
            opacity = from * (1 - clamp01((now - *t.hidingAt) / ReducedFadeDuration));
        }
        return;
    }
    scale = mix(0.5, 1, spring(e, 0.42, 0.62));
    opacity = clamp01(e / 0.10);
    if (t.hidingAt) {
        // Start from where the entrance is now, in case the pill leaves before it has arrived.
        const double e0 = *t.hidingAt - t.shownAt;
        const double scaleFrom = mix(0.5, 1, spring(e0, 0.42, 0.62));
        const double opacityFrom = clamp01(e0 / 0.10);
        const double x = clamp01((now - *t.hidingAt) / ExitDuration);
        scale = mix(scaleFrom, 0.5, x * x * x);
        const double fade = clamp01((x - 0.2) / 0.8);
        opacity = opacityFrom * (1 - fade * fade);
    }
}

void render(const Frame &f, double scale, double opacity, uint32_t *pixels, int width, int height, double pixelsPerUnit) {
    const double unit = pixelsPerUnit * std::max(scale, 0.01);
    const double aa = 1 / unit;
    const double cx = width / 2.0, cy = height / 2.0;
    constexpr double straight = Width / 2 - Height / 2;

    for (int y = 0; y < height; ++y) {
        const double py = (cy - (y + 0.5)) / unit;
        uint32_t *row = pixels + size_t(y) * size_t(width);
        for (int x = 0; x < width; ++x) {
            const double qx = (x + 0.5 - cx) / unit;
            const double dc = capsuleDistance(qx, py);
            if (dc > 12) {
                row[x] = 0;
                continue;
            }
            Pixel p;

            // Shadow, under a capsule moved down a little.
            const double ds = capsuleDistance(qx, py + 1.6);
            if (ds < 10) {
                const double k = 1 - clamp01(ds / 10);
                p.over(0, 0, 0, k * k * 0.30);
            }

            const double cover = clamp01(0.5 - dc / aa);
            if (cover > 0) {
                // Tinted glass, a little lighter at the top.
                const double top = clamp01(0.5 + py / Height);
                const double v = 0.06 + 0.06 * top;
                p.over(v, v + 0.005, v + 0.02, cover * GlassAlpha);
                // The rim: bright at the top, a weak reflection at the bottom.
                const double nx = qx - std::clamp(qx, -straight, straight);
                const double ny = py / std::max(std::sqrt(nx * nx + py * py), 1e-4);
                const double band = clamp01(1 - std::abs(dc + 0.8) / 0.9);
                p.over(1, 1, 1, band * cover * (0.10 + 0.42 * std::max(0.0, ny) + 0.14 * std::max(0.0, -ny)));
            }

            const double clip = clamp01(0.5 - (dc + 1.6) / aa);
            if (clip > 0 && f.count > 0) {
                if (f.goo > 0) {
                    double d = 1e9, alpha = 0;
                    for (int i = 0; i < f.count; ++i) {
                        d = smoothMin(d, distance(qx, py, f.shapes[i]), f.goo);
                        alpha = std::max(alpha, f.shapes[i].alpha);
                    }
                    p.dotAt(d, alpha * f.alpha * clip, aa);
                } else {
                    for (int i = 0; i < f.count; ++i)
                        p.dotAt(distance(qx, py, f.shapes[i]), f.shapes[i].alpha * f.alpha * clip, aa);
                }
            }
            row[x] = p.pack(opacity);
        }
    }
}
}
