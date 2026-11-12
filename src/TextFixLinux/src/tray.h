// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <QDBusObjectPath>
#include <QObject>

// StatusNotifierItem works with Omarchy, KDE and other tray hosts without a Qt Widgets runtime.
class Tray : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.kde.StatusNotifierItem")
    Q_PROPERTY(QString Category READ category CONSTANT)
    Q_PROPERTY(QString Id READ id CONSTANT)
    Q_PROPERTY(QString Title READ title CONSTANT)
    Q_PROPERTY(QString Status READ status CONSTANT)
    Q_PROPERTY(QString IconName READ icon CONSTANT)
    Q_PROPERTY(bool ItemIsMenu READ itemIsMenu CONSTANT)
    Q_PROPERTY(QDBusObjectPath Menu READ menu CONSTANT)
public:
    explicit Tray(QObject *parent = nullptr);
    QString category() const { return "ApplicationStatus"; }
    QString id() const { return "textfix"; }
    QString title() const { return "TextFix"; }
    QString status() const { return "Active"; }
    QString icon() const { return "textfix"; }
    bool itemIsMenu() const { return false; }
    QDBusObjectPath menu() const { return QDBusObjectPath("/NO_DBUSMENU"); }
    // TextFix shows one notification at a time. A new message replaces the one on screen, so
    // the progress message and the result do not make a stack. These two are not slots on
    // purpose: only slots go on the bus, and no other program must show text as TextFix.
    void notify(const QString &message, int timeout);
    void clearNotification();
public slots:
    void Activate(int, int) { emit openSettings(); }
    void ContextMenu(int, int) { emit openSettings(); }
    void SecondaryActivate(int, int) { emit cancel(); }
signals:
    void openSettings();
    void cancel();
private:
    void registerItem();
    void close(uint id);
    uint m_notification = 0;
    quint64 m_serial = 0;
    int m_waiting = 0;
    bool m_clearWhenKnown = false;
};
