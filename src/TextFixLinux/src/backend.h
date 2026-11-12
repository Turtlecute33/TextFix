// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "aiclient.h"
#include "desktop.h"
#include <QElapsedTimer>
#include <QSet>
#include <QVariantMap>

class Backend : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap settings READ settings NOTIFY settingsChanged)
    Q_PROPERTY(QString status READ status NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(QString platform READ platform CONSTANT)
public:
    // Progress: a request is active. Done: it ended and there is nothing to tell.
    // Info and Error: it ended with a message.
    enum Notice { Progress, Done, Info, Error };
    explicit Backend(Desktop *desktop, const QString &directory = {}, QObject *parent = nullptr);
    ~Backend() override;
    QVariantMap settings() const { return m_config.toVariantMap(); }
    QString status() const { return m_status; }
    QString platform() const { return m_desktop->name(); }
    bool busy() const { return m_busy; }
    Q_INVOKABLE bool save(const QVariantMap &values, const QString &key, bool autostart);
    Q_INVOKABLE bool autostart() const;
    Q_INVOKABLE void cancel();
    Q_INVOKABLE QVariantList models(const QString &provider) const;
    Q_INVOKABLE QString defaultPrompt(int action) const;
    void retranslate();
    void start(int action, bool clipboardOnly = false);
    void flushRestore();
signals:
    void changed();
    void settingsChanged();
    // Each event of a request. Not filtered by the settings.
    void notice(const QString &message, int kind);
    // What the desktop shows, after the indicator and notifyOnError settings.
    void notify(const QString &message, int timeout);
    void clearNotification();
private:
    void probe(bool whole);
    void captured(const QString &text);
    void completed(const QString &answer, const QString &error);
    void fail(const QString &message, Notice kind = Error);
    void announce(const QString &message, Notice kind);
    void restoreCapture();
    void collapseSelection();
    void setStatus(const QString &message);
    Desktop *m_desktop;
    QString m_directory, m_status, m_loadError, m_readyStatus;
    QJsonObject m_config, m_action;
    AiClient m_ai;
    QTimer m_probe, m_restore;
    QElapsedTimer m_copyWait;
    Focus m_focus;
    ClipboardData m_saved, m_pending;
    QString m_marker, m_clipboardToken, m_input, m_prompt, m_key;
    QSet<QString> m_zdrWarned;
    bool m_busy = false, m_clipboardOnly = false, m_whole = false, m_settled = false, m_loadWarned = false;
    quint64 m_generation = 0;
};
