// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "pillscene.h"
#include <memory>

// The progress pill as a Wayland layer surface (wlr-layer-shell): bottom centre of the output
// that has the focus, above all windows, with no keyboard focus and an empty input region, so
// it never takes the focus from the text being fixed and never catches a click. Hyprland,
// KDE Plasma, Sway and other wlroots desktops have the protocol. GNOME does not.
//
// It has its own Wayland connection and its own thread, so the animation does not stop while
// the main thread waits for a clipboard helper.
class LayerShellPill {
public:
    LayerShellPill();
    ~LayerShellPill();
    LayerShellPill(const LayerShellPill &) = delete;
    LayerShellPill &operator=(const LayerShellPill &) = delete;
    // False when there is no Wayland compositor or it has no layer shell.
    bool available() const;
    // Times from PillScene::now().
    void start(double time, bool reduced);
    void promote(double time);
    void hide(double time);
private:
    struct State;
    std::unique_ptr<State> d;
};
