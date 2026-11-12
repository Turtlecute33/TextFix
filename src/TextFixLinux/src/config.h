// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <QJsonObject>
#include <QString>
#include <QVariantList>

namespace Config {
QString directory();
QJsonObject defaults();
QJsonObject load(const QString &directory, QString *error);
bool save(const QString &directory, const QJsonObject &config, QString *error);
QString secret(const QString &provider, QString *error);
bool storeSecret(const QString &provider, const QString &key, QString *error);
QString defaultModel();
QString fixPrompt();
QString rewritePrompt();
// The Fix prompts of earlier releases. A saved prompt that is equal to one of them was not
// edited, so it moves to the current prompt.
QStringList legacyFixPrompts();
// The same model list as the Windows and macOS agents: slug, label.
QVariantList models(const QString &provider);
bool validModelSlug(const QString &slug);
}
