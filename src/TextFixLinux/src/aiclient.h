// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPointer>
#include <QTimer>

namespace AiText {
// Results that are not an HTTP status. The values are the same as in the other agents.
enum Status {
    Unusable = -2,  // HTTP 200 with a body that has no answer. A second request usually works.
    CutShort = -3,  // The answer stopped early. A second request gives the same result.
};
QString resolveModel(const QJsonObject &config);
QJsonObject body(const QString &text, const QString &prompt, const QJsonObject &config,
                 bool enforceZdr = true, bool disableReasoning = true);
QString parse(const QByteArray &data, QString *error, int *status = nullptr);
QString clean(const QString &answer, const QString &original, const QString &prompt, QString *error);
QString errorMessage(int status);
bool retryable(int status);
bool zdrRouteUnavailable(int status, const QByteArray &body);
bool zdrVerdictCacheable(int status, const QByteArray &body);
bool reasoningControlRejected(int status, const QByteArray &body);
}

// One chat completion with the policy of the Windows and macOS agents: three attempts with
// backoff, zero data retention first with one downgrade, and a retry when a route refuses
// reasoning:{enabled:false}.
class AiClient : public QObject {
    Q_OBJECT
public:
    explicit AiClient(QObject *parent = nullptr, const QUrl &testEndpoint = {});
    void start(const QString &text, const QString &prompt, const QJsonObject &config, const QString &key);
    void cancel();
    // True when the last answer came from a route without zero data retention.
    bool fellBackFromZdr() const { return m_fellBack; }
    static void forgetRouteFacts();
signals:
    void finished(const QString &text, const QString &error);
private:
    void attempt();
    void handle(QNetworkReply *reply);
    bool retryLater(int delay);
    void complete(const QString &text, const QString &error);
    QNetworkAccessManager m_network;
    QPointer<QNetworkReply> m_reply;
    QTimer m_deadline, m_retry;
    QJsonObject m_config;
    QString m_key, m_text, m_prompt, m_model;
    QUrl m_testEndpoint;
    QByteArray m_response;
    int m_attempt = 0;
    bool m_active = false, m_openRouter = false, m_zdrWanted = false, m_zdr = false,
         m_reasoningOff = false, m_fellBack = false;
};
