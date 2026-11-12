// SPDX-License-Identifier: GPL-3.0-only
#include "aiclient.h"
#include <QDateTime>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QUuid>
#include <initializer_list>

namespace {
const int maxAttempts = 3;
const int maxRetryAfterSeconds = 30;
const qsizetype maxResponseBytes = 1000000;

// Routing facts that cost a failed request to learn. They stay for 30 minutes only: a ZDR
// route that was down comes back, and a ~author/model-latest alias can point to a different
// endpoint tomorrow.
const qint64 routeFactLifeMs = 30 * 60 * 1000;
QHash<QString, qint64> zdrUnavailable, reasoningRejected;

bool known(QHash<QString, qint64> &facts, const QString &model) {
    const auto it = facts.constFind(model);
    if (it == facts.constEnd()) return false;
    if (QDateTime::currentMSecsSinceEpoch() - it.value() < routeFactLifeMs) return true;
    facts.remove(model);
    return false;
}

bool mentions(const QByteArray &lowerBody, std::initializer_list<const char *> words) {
    for (const char *word : words)
        if (lowerBody.contains(word)) return true;
    return false;
}
}

QString AiText::resolveModel(const QJsonObject &config) {
    QString model = config.value("model").toString().trimmed();
    if (model == "custom") model = config.value("customModel").toString().trimmed();
    return model;
}

QJsonObject AiText::body(const QString &text, const QString &prompt, const QJsonObject &config,
                         bool enforceZdr, bool disableReasoning) {
    QString expanded = prompt;
    // The nonce goes in before the text, so a text that contains "{nonce}" does not get the value.
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
    QJsonObject result{{"model", resolveModel(config)}, {"messages", messages}};
    const bool openRouter = config.value("provider").toString() == "openrouter";
    // Without the ZDR constraint the request still refuses each provider that keeps prompts
    // for training. It never goes below that.
    if (openRouter && config.value("zeroDataRetention").toBool(true))
        result.insert("provider", enforceZdr ? QJsonObject{{"zdr", true}} : QJsonObject{{"data_collection", "deny"}});
    if (openRouter && disableReasoning && !config.value("allowReasoning").toBool())
        result.insert("reasoning", QJsonObject{{"enabled", false}});
    return result;
}

QString AiText::errorMessage(int status) {
    switch (status) {
    case 401: return QObject::tr("API key refused. Check it in TextFix settings.");
    case 402: return QObject::tr("Your provider account is out of credit.");
    case 404: return QObject::tr("That model was not found on this provider.");
    case 429:
    case 503: return QObject::tr("Provider is rate limiting. Try again in a moment.");
    default: break;
    }
    return status > 0 ? QObject::tr("Provider error (HTTP %1).").arg(status)
                      : QObject::tr("The provider returned an unusable response.");
}

bool AiText::retryable(int status) {
    switch (status) {
    case 408: case 425: case 429: case 500: case 502: case 503: case 504: case Unusable: return true;
    // Errors of the Cloudflare edge in front of the provider. They clear in a moment.
    case 520: case 521: case 522: case 523: case 524: return true;
    default: return false;
    }
}

bool AiText::zdrRouteUnavailable(int status, const QByteArray &body) {
    if (status != 400 && status != 404 && status != 409 && status != 422) return false;
    return mentions(body.toLower(), {"zdr", "zero data", "data retention", "no endpoint"});
}

// "No endpoint" is also the answer when a provider is down for a moment. Only a body that
// names retention is specific enough to remember.
bool AiText::zdrVerdictCacheable(int status, const QByteArray &body) {
    return zdrRouteUnavailable(status, body)
        && mentions(body.toLower(), {"zdr", "zero data", "data retention", "data policy"});
}

// True when a route refuses reasoning:{enabled:false} instead of ignoring it. Narrow on
// purpose: a general 400 must not hide the real error.
bool AiText::reasoningControlRejected(int status, const QByteArray &body) {
    if (status != 400 && status != 422) return false;
    const QByteArray lower = body.toLower();
    return mentions(lower, {"reasoning", "thinking"})
        && mentions(lower, {"cannot be disabled", "can't be disabled", "must be enabled", "is mandatory",
                            "does not support", "not supported", "unsupported"});
}

QString AiText::parse(const QByteArray &data, QString *error, int *status) {
    int unused = 0;
    if (!status) status = &unused;
    *status = 0;
    auto unusable = [&] {
        *status = Unusable;
        *error = errorMessage(Unusable);
        return QString();
    };
    QJsonParseError parse;
    const auto root = QJsonDocument::fromJson(data, &parse).object();
    if (parse.error != QJsonParseError::NoError) return unusable();
    // An error envelope with HTTP 200. Its code is the real status, so a 401 or a 402 reads as
    // what it is and is not tried again.
    const int code = root.value("error").toObject().value("code").toInt();
    if (code >= 400 && code <= 599) {
        *status = code;
        *error = errorMessage(code);
        return {};
    }
    const auto choices = root.value("choices").toArray();
    if (choices.isEmpty()) return unusable();
    const auto choice = choices.first().toObject();
    const auto finish = choice.value("finish_reason").toString();
    if (finish == "length" || finish == "content_filter") {
        *status = CutShort;
        *error = finish == "length"
            ? QObject::tr("The answer was cut short, so nothing was changed. Try a shorter text.")
            : QObject::tr("The provider's content filter stopped the answer, so nothing was changed.");
        return {};
    }
    // The upstream failed in the middle of the answer. What came back is only a part.
    if (finish == "error") return unusable();
    const auto content = choice.value("message").toObject().value("content");
    QString text;
    if (content.isString()) text = content.toString();
    else {
        for (const auto &part : content.toArray())
            if (part.toObject().value("type").toString() == "text") text += part.toObject().value("text").toString();
    }
    // A reasoning model can answer with no content. The reasoning field is not a substitute:
    // it is the scratchpad of the model as often as it is the answer.
    if (text.trimmed().isEmpty()) return unusable();
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

void AiClient::forgetRouteFacts() {
    zdrUnavailable.clear();
    reasoningRejected.clear();
}

void AiClient::start(const QString &text, const QString &prompt, const QJsonObject &config, const QString &key) {
    cancel();
    m_active = true;
    m_config = config;
    m_key = key;
    m_text = text;
    m_prompt = prompt;
    m_model = AiText::resolveModel(config);
    m_openRouter = config.value("provider").toString() == "openrouter";
    m_zdrWanted = m_openRouter && config.value("zeroDataRetention").toBool(true);
    // A model that has no ZDR route would fail one attempt on each fix to learn the same thing.
    m_fellBack = m_zdrWanted && known(zdrUnavailable, m_model);
    m_zdr = m_zdrWanted && !m_fellBack;
    m_reasoningOff = m_openRouter && !config.value("allowReasoning").toBool() && !known(reasoningRejected, m_model);
    m_attempt = 0;
    // One deadline for the full request. The retries and the ZDR downgrade do not start it again.
    m_deadline.start(qBound(5000, config.value("requestBudgetMs").toInt(90000), 300000));
    attempt();
}

void AiClient::attempt() {
    if (!m_active) return;
    ++m_attempt;
    const QUrl endpoint = !m_testEndpoint.isEmpty() ? m_testEndpoint : QUrl(m_openRouter
        ? "https://openrouter.ai/api/v1/chat/completions" : "https://api.ppq.ai/chat/completions");
    QNetworkRequest request(endpoint);
    // A redirect that Qt follows sends the user's text to the host that the answer names.
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    request.setAttribute(QNetworkRequest::CookieLoadControlAttribute, QNetworkRequest::Manual);
    request.setAttribute(QNetworkRequest::CookieSaveControlAttribute, QNetworkRequest::Manual);
    request.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);
    request.setAttribute(QNetworkRequest::CacheSaveControlAttribute, false);
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    request.setRawHeader("Authorization", "Bearer " + m_key.toUtf8());
    if (m_openRouter) {
        request.setRawHeader("HTTP-Referer", "https://github.com/Turtlecute33/TextFix");
        request.setRawHeader("X-OpenRouter-Title", "TextFix");
        request.setRawHeader("X-OpenRouter-Categories", "writing-assistant");
    }
    const auto body = AiText::body(m_text, m_prompt, m_config, m_zdr, m_reasoningOff);
    auto *reply = m_network.post(request, QJsonDocument(body).toJson(QJsonDocument::Compact));
    reply->setReadBufferSize(maxResponseBytes + 1);
    m_reply = reply;
    m_response.clear();
    connect(reply, &QNetworkReply::readyRead, this, [this, reply] {
        if (m_reply != reply) return;
        m_response += reply->readAll();
        if (m_response.size() > maxResponseBytes) complete({}, tr("The provider response was too large."));
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        if (m_active && m_reply == reply) handle(reply);
    });
}

void AiClient::handle(QNetworkReply *reply) {
    const QByteArray response = m_response + reply->readAll();
    int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const auto networkError = reply->error();
    const QByteArray retryAfter = reply->rawHeader("Retry-After").trimmed();
    m_reply.clear();
    m_response.clear();
    if (response.size() > maxResponseBytes) { complete({}, tr("The provider response was too large.")); return; }

    const int backoff = qMin(500 << (m_attempt - 1), 4000);
    if (status == 0) {
        // No HTTP answer. A host that cannot be found or refuses the connection gives the same
        // result on the next attempt, so the user gets the error immediately.
        const bool unreachable = networkError == QNetworkReply::HostNotFoundError
            || networkError == QNetworkReply::ConnectionRefusedError
            || networkError == QNetworkReply::ProxyNotFoundError
            || networkError == QNetworkReply::ProxyConnectionRefusedError;
        if (!unreachable && m_attempt < maxAttempts && retryLater(backoff)) return;
        complete({}, tr("Could not reach the provider. Check your connection."));
        return;
    }

    QString error;
    if (status >= 200 && status < 300) {
        const QString text = AiText::parse(response, &error, &status);
        if (error.isEmpty()) { complete(text, {}); return; }
    } else {
        // OpenRouter answers a slug that it does not know with 400, not with 404.
        error = AiText::errorMessage(status == 400 && response.toLower().contains("not a valid model") ? 404 : status);
    }

    const bool noZdrRoute = m_zdrWanted && AiText::zdrRouteUnavailable(status, response);
    if (noZdrRoute && m_zdr) {
        // No zero-retention route. Ask one time more without it. That request still refuses
        // each provider that keeps the text for training (see AiText::body).
        if (AiText::zdrVerdictCacheable(status, response))
            zdrUnavailable.insert(m_model, QDateTime::currentMSecsSinceEpoch());
        m_zdr = false;
        m_fellBack = true;
        m_attempt = 0;
        attempt();
        return;
    }
    if (noZdrRoute) {
        // No status code in this message: the 404 behind it reads as "model not found", which
        // sends the user to the wrong place.
        complete({}, tr("No provider of this model meets your privacy setting. Pick another model, or turn off zero data retention in settings."));
        return;
    }
    if (m_reasoningOff && AiText::reasoningControlRejected(status, response)) {
        reasoningRejected.insert(m_model, QDateTime::currentMSecsSinceEpoch());
        m_reasoningOff = false;
        m_attempt = 0;
        attempt();
        return;
    }
    if (AiText::retryable(status) && m_attempt < maxAttempts) {
        // An unusable 200 is not congestion, so the next attempt starts immediately.
        int delay = status == AiText::Unusable ? 0 : backoff;
        bool secondsOk = false;
        const int seconds = retryAfter.toInt(&secondsOk);
        if ((status == 429 || status == 503) && secondsOk && seconds > 0)
            delay = qMin(seconds, maxRetryAfterSeconds) * 1000;
        if (retryLater(delay)) return;
    }
    complete({}, error);
}

// False when the delay is longer than the time that remains: that attempt can never complete.
bool AiClient::retryLater(int delay) {
    if (delay >= m_deadline.remainingTime()) return false;
    m_retry.start(delay);
    return true;
}

void AiClient::cancel() {
    m_active = false;
    m_deadline.stop();
    m_retry.stop();
    auto reply = m_reply;
    m_reply.clear();
    if (reply) { reply->abort(); reply->deleteLater(); }
    m_key.clear();
    m_text.clear();
    m_prompt.clear();
    m_response.clear();
}

void AiClient::complete(const QString &text, const QString &error) {
    cancel();
    emit finished(text, error);
}
