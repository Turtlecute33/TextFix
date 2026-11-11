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
    static void notify(const QString &message);
public slots:
    void Activate(int, int) { emit openSettings(); }
    void ContextMenu(int, int) { emit openSettings(); }
    void SecondaryActivate(int, int) { emit cancel(); }
signals:
    void openSettings();
    void cancel();
private:
    void registerItem();
};
