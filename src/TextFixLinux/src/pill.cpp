// SPDX-License-Identifier: GPL-3.0-only
#include "pill.h"
#include "desktop.h"
#include "layershell.h"
#include "pillscene.h"
#include <QCursor>
#include <QGuiApplication>
#include <QImage>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPainter>
#include <QRasterWindow>
#include <QScreen>
#include <QTimer>

// X11: a frameless, click-through window that never takes the focus. The window manager does
// not manage it, so it stays where TextFix puts it. Transparency needs a compositing manager.
class X11Pill : public QRasterWindow {
public:
    X11Pill() {
        setFlags(Qt::FramelessWindowHint | Qt::WindowStaysOnTopHint | Qt::WindowDoesNotAcceptFocus
                 | Qt::WindowTransparentForInput | Qt::X11BypassWindowManagerHint | Qt::Tool);
        QSurfaceFormat surfaceFormat = format();
        surfaceFormat.setAlphaBufferSize(8);
        setFormat(surfaceFormat);
        resize(PillScene::SurfaceWidth, PillScene::SurfaceHeight);
        m_timer.setTimerType(Qt::PreciseTimer);
        m_timer.setInterval(16);
        QObject::connect(&m_timer, &QTimer::timeout, this, [this] { step(); });
    }
    void start(double time, bool reduced) {
        if (isVisible() && !m_timeline.hidingAt) return;
        m_timeline = {};
        m_timeline.shownAt = time;
        m_timeline.reduced = reduced;
        if (!isVisible()) place();
        step();
        show();
    }
    void promote(double time) {
        if (!isVisible() || m_timeline.workingAt) return;
        m_timeline.workingAt = time;
        step();
    }
    void leave(double time) {
        if (!isVisible() || m_timeline.hidingAt) return;
        m_timeline.hidingAt = time;
        step();
    }
protected:
    void paintEvent(QPaintEvent *) override {
        QPainter painter(this);
        painter.setCompositionMode(QPainter::CompositionMode_Source);
        painter.drawImage(QPointF(0, 0), m_image);
    }
private:
    // The bottom centre of the usable part of the screen with the mouse pointer, above panels.
    void place() {
        QScreen *screen = QGuiApplication::screenAt(QCursor::pos());
        if (!screen) screen = QGuiApplication::primaryScreen();
        if (!screen) return;
        const QRect area = screen->availableGeometry();
        setScreen(screen);
        setPosition(area.center().x() - PillScene::SurfaceWidth / 2,
                    area.bottom() + 1 - int(PillScene::BottomGap - PillScene::Margin) - PillScene::SurfaceHeight);
    }
    void step() {
        const double now = PillScene::now();
        PillScene::frameAt(now, m_timeline, m_frame);
        if (m_frame.finished) {
            m_timer.stop();
            hide();
            return;
        }
        const qreal ratio = devicePixelRatio();
        const QSize size(qRound(PillScene::SurfaceWidth * ratio), qRound(PillScene::SurfaceHeight * ratio));
        if (m_image.size() != size) {
            m_image = QImage(size, QImage::Format_ARGB32_Premultiplied);
            m_image.setDevicePixelRatio(ratio);
        }
        double scale, opacity;
        PillScene::stage(now, m_timeline, scale, opacity);
        PillScene::render(m_frame, scale, opacity, reinterpret_cast<uint32_t *>(m_image.bits()), size.width(), size.height(), ratio);
        update();
        // A still pill needs no more frames. Promote and leave start them again.
        if (m_frame.settled) m_timer.stop();
        else if (!m_timer.isActive()) m_timer.start();
    }
    QTimer m_timer;
    QImage m_image;
    PillScene::Timeline m_timeline;
    PillScene::Frame m_frame;
};

#ifndef TEXTFIX_LAYER_SHELL
// A build without Wayland (the test build on macOS) has no layer shell.
struct LayerShellPill::State {};
LayerShellPill::LayerShellPill() = default;
LayerShellPill::~LayerShellPill() = default;
bool LayerShellPill::available() const { return false; }
void LayerShellPill::start(double, bool) {}
void LayerShellPill::promote(double) {}
void LayerShellPill::hide(double) {}
#endif

Pill::Pill(QObject *parent) : QObject(parent) {
    const bool wayland = !qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY");
    if (wayland) {
        m_wayland = std::make_unique<LayerShellPill>();
        if (!m_wayland->available()) m_wayland.reset();
    }
    if (!wayland && QGuiApplication::platformName() == "xcb") m_x11 = std::make_unique<X11Pill>();
    // Hyprland with its animations off is the reduce-motion setting of Omarchy.
    if (!qEnvironmentVariableIsEmpty("HYPRLAND_INSTANCE_SIGNATURE")) {
        const auto result = runTool("hyprctl", {"-j", "getoption", "animations:enabled"}, {}, 500);
        if (result.ok) m_reduced = QJsonDocument::fromJson(result.output).object().value("int").toInt(1) == 0;
    }
}

Pill::~Pill() = default;

bool Pill::available() const { return m_wayland ? m_wayland->available() : bool(m_x11); }

void Pill::show(bool working) {
    const double now = PillScene::now();
    if (!m_visible) {
        m_visible = true;
        m_working = false;
        if (m_wayland) m_wayland->start(now, m_reduced);
        if (m_x11) m_x11->start(now, m_reduced);
    }
    if (working && !m_working) {
        m_working = true;
        if (m_wayland) m_wayland->promote(now);
        if (m_x11) m_x11->promote(now);
    }
}

void Pill::hide() {
    if (!m_visible) return;
    m_visible = false;
    m_working = false;
    const double now = PillScene::now();
    if (m_wayland) m_wayland->hide(now);
    if (m_x11) m_x11->leave(now);
}
