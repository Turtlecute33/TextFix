// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <QJsonObject>
#include <QString>

namespace Config {
QString directory();
QJsonObject defaults();
QJsonObject load(const QString &directory, QString *error);
bool save(const QString &directory, const QJsonObject &config, QString *error);
QString secret(const QString &provider, QString *error);
bool storeSecret(const QString &provider, const QString &key, QString *error);
QString fixPrompt();
QString rewritePrompt();
}
