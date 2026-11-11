// SPDX-License-Identifier: GPL-3.0-only
#include "tray.h"
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCall>
#include <QDBusServiceWatcher>
#include <QVariantMap>

Tray::Tray(QObject *parent) : QObject(parent) {
    auto bus = QDBusConnection::sessionBus();
    bus.registerObject("/StatusNotifierItem", this, QDBusConnection::ExportAllProperties | QDBusConnection::ExportAllSlots);
    auto *watcher = new QDBusServiceWatcher("org.kde.StatusNotifierWatcher", bus, QDBusServiceWatcher::WatchForRegistration, this);
    connect(watcher, &QDBusServiceWatcher::serviceRegistered, this, [this] { registerItem(); });
    registerItem();
}

void Tray::registerItem() {
    auto message = QDBusMessage::createMethodCall("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem");
    message << QString("/StatusNotifierItem");
    QDBusConnection::sessionBus().asyncCall(message);
}

void Tray::notify(const QString &text) {
    auto message = QDBusMessage::createMethodCall("org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify");
    message << QString("TextFix") << uint(0) << QString("textfix") << QString("TextFix") << text.toHtmlEscaped()
            << QStringList{} << QVariantMap{{"transient", true}} << 5000;
    QDBusConnection::sessionBus().asyncCall(message);
}
