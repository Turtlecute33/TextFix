// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>
#include <optional>

// The size and the motion of the progress pill. The macOS agent (Ui/PillScene.swift) and the
// Windows agent (Ui/PillScene.cs) use the same numbers and the same functions, so the three
// agents show the same animation. Change them together.
//
// The pill is a glass capsule with three white dots. While TextFix reads the text, the dots are
// still and dim. While the request runs, a liquid drop moves from dot to dot and stretches as it
// moves. Shapes that come near each other melt together (a smooth minimum of their distances).
// Plain C++ without Qt, so the Wayland thread can use it.
namespace PillScene {
// Sizes in logical pixels.
constexpr double Width = 96;
constexpr double Height = 32;
// Room around the capsule for the shadow and for the spring, which goes past full size.
constexpr double Margin = 22;
// From the bottom of the usable screen (above a bottom bar) to the capsule.
constexpr double BottomGap = 63;
constexpr double DotRadius = 4;
constexpr double DotSpacing = 12.75;
constexpr int SurfaceWidth = int(Width + 2 * Margin);
constexpr int SurfaceHeight = int(Height + 2 * Margin);

constexpr double ExitDuration = 0.36;
constexpr double ReducedFadeDuration = 0.15;

// Times in seconds from now().
struct Timeline {
    double shownAt = 0;
    std::optional<double> workingAt, hidingAt;
    bool reduced = false;
};

// A line from a to b with round ends of radius r. A dot when a and b are the same point.
struct Shape {
    double ax = 0, ay = 0, bx = 0, by = 0, r = 0, alpha = 1;
};

struct Frame {
    Shape shapes[4];
    int count = 0;
    // How near two shapes must be to melt together. Zero: no melting.
    double goo = 0;
    double alpha = 1;
    // The exit is complete. Take the surface off the screen.
    bool finished = false;
    // Nothing changes until the next stage, so no more frames are necessary.
    bool settled = false;
};

// Seconds on the monotonic clock.
double now();
void frameAt(double now, const Timeline &t, Frame &f);
// The scale and the opacity of the whole capsule: a spring from 50 % on the way in, a shrink
// to 50 % and a fade on the way out.
void stage(double now, const Timeline &t, double &scale, double &opacity);
// Draws the whole pill - shadow, glass, rim and dots - into premultiplied ARGB32 pixels
// (the layout of QImage::Format_ARGB32_Premultiplied and WL_SHM_FORMAT_ARGB8888).
void render(const Frame &f, double scale, double opacity, uint32_t *pixels, int width, int height, double pixelsPerUnit);
}
