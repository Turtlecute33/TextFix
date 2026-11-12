// SPDX-License-Identifier: GPL-3.0-only
#include "tray.h"
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusServiceWatcher>
#include <QVariantMap>

namespace {
QDBusMessage notificationCall(const QString &method) {
    return QDBusMessage::createMethodCall("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                                          "org.freedesktop.Notifications", method);
}
}

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

void Tray::notify(const QString &text, int timeout) {
    auto message = notificationCall("Notify");
    message << QString("TextFix") << m_notification << QString("textfix") << QString("TextFix") << text.toHtmlEscaped()
            << QStringList{} << QVariantMap{{"transient", true}, {"desktop-entry", QString("textfix")}} << timeout;
    const quint64 serial = ++m_serial;
    m_clearWhenKnown = false;
    ++m_waiting;
    auto *watcher = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(message, 3000), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, serial](QDBusPendingCallWatcher *call) {
        call->deleteLater();
        --m_waiting;
        const QDBusPendingReply<uint> reply = *call;
        if (reply.isError()) return;
        const uint id = reply.value();
        // The answer of an older call: a newer message is already on its way with a different
        // number, so the old one must not stay on screen.
        if (serial != m_serial) { if (id != m_notification) close(id); return; }
        m_notification = id;
        if (m_clearWhenKnown) clearNotification();
    });
}

void Tray::clearNotification() {
    // The number of the notification comes back later than the call. Wait for it.
    if (m_waiting > 0) { m_clearWhenKnown = true; return; }
    m_clearWhenKnown = false;
    if (m_notification) close(m_notification);
    m_notification = 0;
}

void Tray::close(uint id) {
    auto message = notificationCall("CloseNotification");
    message << id;
    QDBusConnection::sessionBus().asyncCall(message);
}
