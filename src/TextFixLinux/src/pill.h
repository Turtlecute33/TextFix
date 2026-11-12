// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <QObject>
#include <memory>

class LayerShellPill;
class X11Pill;

// The progress pill at the bottom centre of the screen, the same animation as on Windows and
// macOS (see pillscene.h). On Wayland it is a layer surface. On X11 it is a window that the
// window manager does not manage. GNOME on Wayland has no place for it: available() is false,
// and TextFix shows the notification instead.
class Pill : public QObject {
    Q_OBJECT
public:
    explicit Pill(QObject *parent = nullptr);
    ~Pill() override;
    bool available() const;
    // working: false for the quiet stage while TextFix reads the text, true once the request is
    // out. A second call only promotes the pill; it does not come in again.
    void show(bool working);
    void hide();
private:
    std::unique_ptr<LayerShellPill> m_wayland;
    std::unique_ptr<X11Pill> m_x11;
    bool m_visible = false, m_working = false, m_reduced = false;
};
