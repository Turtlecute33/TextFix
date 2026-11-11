// SPDX-License-Identifier: GPL-3.0-only
#include "aiclient.h"
#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QUuid>

QJsonObject AiText::body(const QString &text, const QString &prompt, const QJsonObject &config) {
    QString expanded = prompt;
    expanded.replace("{nonce}", QUuid::createUuid().toString(QUuid::Id128).left(8), Qt::CaseInsensitive);
    QJsonArray messages;
    bool inlined = false;
    for (const QString &token : {QString("{text}"), QString("{paste here}"), QString("{paste}")}) {
        if (!expanded.contains(token, Qt::CaseInsensitive)) continue;
        expanded.replace(token, text, Qt::CaseInsensitive);
        inlined = true;
        break;
    }
    if (inlined) messages.append(QJsonObject{{"role", "user"}, {"content", expanded}});
    else {
        messages.append(QJsonObject{{"role", "system"}, {"content", prompt}});
        messages.append(QJsonObject{{"role", "user"}, {"content", text}});
    }
    QString model = config.value("model").toString();
    if (model == "custom") model = config.value("customModel").toString();
    QJsonObject result{{"model", model}, {"messages", messages}};
    if (config.value("provider").toString() == "openrouter" && config.value("zeroDataRetention").toBool(true))
        result.insert("provider", QJsonObject{{"zdr", true}});
    if (config.value("provider").toString() == "openrouter" && !config.value("allowReasoning").toBool())
        result.insert("reasoning", QJsonObject{{"enabled", false}});
    return result;
}

QString AiText::parse(const QByteArray &data, QString *error) {
    QJsonParseError parse;
    const auto doc = QJsonDocument::fromJson(data, &parse);
    const auto root = doc.object();
    const auto choices = root.value("choices").toArray();
    if (parse.error != QJsonParseError::NoError || root.contains("error") || choices.isEmpty()) {
        *error = QObject::tr("The provider returned an unusable response."); return {};
    }
    const auto choice = choices.first().toObject();
    const auto finish = choice.value("finish_reason").toString();
    if (finish == "length" || finish == "content_filter") {
        *error = QObject::tr("The answer was cut short. Nothing was replaced."); return {};
    }
    const auto content = choice.value("message").toObject().value("content");
    if (content.isString()) return content.toString();
    QString text;
    for (const auto &part : content.toArray()) {
        if (part.toObject().value("type").toString() == "text") text += part.toObject().value("text").toString();
    }
    if (text.isEmpty()) *error = QObject::tr("The model returned no text.");
    return text;
}

QString AiText::clean(const QString &answer, const QString &original, const QString &prompt, QString *error) {
    QString result = answer.trimmed();
    const auto match = QRegularExpression("^<([A-Za-z][A-Za-z0-9-]*)>([\\s\\S]*)</\\1>$").match(result);
    if (match.hasMatch()) {
        QString tag = match.captured(1);
        const QString templated = tag.section('-', 0, -2) + "-{nonce}";
        if (prompt.contains("<" + tag + ">", Qt::CaseInsensitive) || prompt.contains("<" + templated + ">", Qt::CaseInsensitive))
            result = match.captured(2).trimmed();
    }
    QString safe;
    for (QChar c : result) {
        const auto u = c.unicode();
        if (u == 9 || u == 10 || u == 13 || (u >= 32 && !(u >= 0x7f && u <= 0x9f) && u != 0x200b &&
            !(u >= 0x202a && u <= 0x202e) && !(u >= 0x2066 && u <= 0x2069) && u != 0xfeff)) safe += c;
    }
    safe = safe.trimmed();
    if (safe.isEmpty() || safe.size() > qMax(qsizetype(10000), original.size() * 2)) {
        *error = QObject::tr("The answer was empty or too long. Nothing was replaced."); return {};
    }
    int first = 0, last = original.size();
    while (first < last && original[first].isSpace()) ++first;
    while (last > first && original[last - 1].isSpace()) --last;
    return original.left(first) + safe + original.mid(last);
}

AiClient::AiClient(QObject *parent, const QUrl &testEndpoint) : QObject(parent), m_testEndpoint(testEndpoint) {
    m_deadline.setSingleShot(true);
    m_retry.setSingleShot(true);
    connect(&m_deadline, &QTimer::timeout, this, [this] { complete({}, tr("Request timed out. Nothing was replaced.")); });
    connect(&m_retry, &QTimer::timeout, this, &AiClient::attempt);
}

void AiClient::start(const QString &text, const QString &prompt, const QJsonObject &config, const QString &key) {
    cancel();
    m_active = true;
    m_config = config;
    m_key = key;
    m_body = AiText::body(text, prompt, config);
    m_attempt = 0;
    m_deadline.start(qBound(1000, config.value("requestBudgetMs").toInt(90000), 300000));
    attempt();
}

void AiClient::attempt() {
    if (!m_active) return;
    ++m_attempt;
    const bool openRouter = m_config.value("provider").toString() == "openrouter";
    const QUrl endpoint = !m_testEndpoint.isEmpty() ? m_testEndpoint : QUrl(openRouter
        ? "https://openrouter.ai/api/v1/chat/completions" : "https://api.ppq.ai/chat/completions");
    QNetworkRequest request(endpoint);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    request.setAttribute(QNetworkRequest::CookieLoadControlAttribute, QNetworkRequest::Manual);
    request.setAttribute(QNetworkRequest::CookieSaveControlAttribute, QNetworkRequest::Manual);
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    request.setRawHeader("Authorization", "Bearer " + m_key.toUtf8());
    if (openRouter) {
        request.setRawHeader("HTTP-Referer", "https://github.com/Turtlecute33/TextFix");
        request.setRawHeader("X-OpenRouter-Title", "TextFix");
    }
    auto *reply = m_network.post(request, QJsonDocument(m_body).toJson(QJsonDocument::Compact));
    reply->setReadBufferSize(1000001);
    m_reply = reply;
    m_response.clear();
    connect(reply, &QNetworkReply::readyRead, this, [this, reply] {
        if (m_reply != reply) return;
        m_response += reply->readAll();
        if (m_response.size() > 1000000) complete({}, tr("The provider response was too large."));
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        if (!m_active || m_reply != reply) return;
        m_response += reply->readAll();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        m_reply.clear();
        if (m_response.size() > 1000000) { complete({}, tr("The provider response was too large.")); return; }
        if ((status == 429 || status == 503 || status == 502 || status == 504) && m_attempt < 3) {
            bool secondsOk = false;
            const int seconds = reply->rawHeader("Retry-After").toInt(&secondsOk);
            const int delay = secondsOk ? qBound(0, seconds, 30) * 1000 : 500 * m_attempt;
            if (delay < m_deadline.remainingTime()) { m_retry.start(delay); return; }
        }
        if (status < 200 || status >= 300 || reply->error() != QNetworkReply::NoError) {
            complete({}, status ? tr("Provider error (HTTP %1). Check your key, balance, model and retention settings.").arg(status)
                               : tr("Could not reach the provider. Check your connection."));
            return;
        }
        QString error;
        const QString text = AiText::parse(m_response, &error);
        complete(text, error);
    });
}

void AiClient::cancel() {
    m_active = false;
    m_deadline.stop();
    m_retry.stop();
    auto reply = m_reply;
    m_reply.clear();
    if (reply) { reply->abort(); reply->deleteLater(); }
    m_key.clear();
    m_body = {};
    m_response.clear();
}

void AiClient::complete(const QString &text, const QString &error) {
    cancel();
    emit finished(text, error);
}
