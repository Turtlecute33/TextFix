// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPointer>
#include <QTimer>

namespace AiText {
QJsonObject body(const QString &text, const QString &prompt, const QJsonObject &config);
QString parse(const QByteArray &data, QString *error);
QString clean(const QString &answer, const QString &original, const QString &prompt, QString *error);
}

class AiClient : public QObject {
    Q_OBJECT
public:
    explicit AiClient(QObject *parent = nullptr, const QUrl &testEndpoint = {});
    void start(const QString &text, const QString &prompt, const QJsonObject &config, const QString &key);
    void cancel();
signals:
    void finished(const QString &text, const QString &error);
private:
    void attempt();
    void complete(const QString &text, const QString &error);
    QNetworkAccessManager m_network;
    QPointer<QNetworkReply> m_reply;
    QTimer m_deadline, m_retry;
    QJsonObject m_config, m_body;
    QString m_key;
    QUrl m_testEndpoint;
    QByteArray m_response;
    int m_attempt = 0;
    bool m_active = false;
};
