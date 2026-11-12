// SPDX-License-Identifier: GPL-3.0-only
#include "theme.h"
#include "desktop.h"
#include <QColor>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QLocale>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QStyleHints>

Theme::Theme(const QString &current, const QString &languageFile, QObject *parent)
    : QObject(parent),
      m_current(current.isEmpty() ? qEnvironmentVariable("XDG_STATE_HOME", QDir::homePath() + "/.local/state") + "/omarchy/current" : current),
      m_languageFile(languageFile.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/omarchy/language" : languageFile) {
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, &Theme::reload);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, &Theme::reload);
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, this, &Theme::reload);
#endif
    QGuiApplication::installTranslator(&m_catalog);
    reload();
}

Theme::~Theme() { QGuiApplication::removeTranslator(&m_catalog); }

void Theme::reload() {
    const auto old = m_watcher.files() + m_watcher.directories();
    if (!old.isEmpty()) m_watcher.removePaths(old);
    // Watch parents as well as targets: theme changes replace symlinks and files atomically.
    const QString colorsPath = m_current + "/theme/colors.toml";
    QStringList paths{m_current, QFileInfo(m_current).absolutePath(), m_current + "/theme", colorsPath,
                      QFileInfo(colorsPath).canonicalFilePath(), m_languageFile, QFileInfo(m_languageFile).absolutePath()};
    paths.removeDuplicates();
    for (const auto &path : paths) if (!path.isEmpty() && QFileInfo::exists(path)) m_watcher.addPath(path);
    QFile colors(colorsPath);
    QString data;
    if (colors.open(QIODevice::ReadOnly)) data = QString::fromUtf8(colors.readAll());
    auto color = [&data](const QString &key, const QString &fallback) {
        const auto match = QRegularExpression("^\\s*" + key + "\\s*=\\s*[\"'](#[0-9a-fA-F]{6})[\"']", QRegularExpression::MultilineOption).match(data);
        return match.hasMatch() ? match.captured(1) : fallback;
    };
    // An Omarchy theme names its mode. Without a theme file, follow the system (Qt 6.5 and
    // later can tell); the default is dark.
    const auto mode = QRegularExpression("^\\s*mode\\s*=\\s*[\"'](light|dark)[\"']", QRegularExpression::MultilineOption).match(data);
    const QString themeBackground = color("background", {});
    m_dark = true;
    if (mode.hasMatch()) m_dark = mode.captured(1) == "dark";
    else if (!themeBackground.isEmpty()) m_dark = QColor(themeBackground).lightness() < 128;
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
    else if (data.isEmpty()) m_dark = QGuiApplication::styleHints()->colorScheme() != Qt::ColorScheme::Light;
#endif
    // The light accent is darker than the dark one: the accent is also a text colour.
    m_accent = color("accent", m_dark ? "#FFD60A" : "#8A6A00");
    m_background = color("background", m_dark ? "#151519" : "#F7F7F5");
    m_foreground = color("foreground", m_dark ? "#eeeeee" : "#1B1B1F");
    if (!qEnvironmentVariableIsEmpty("HYPRLAND_INSTANCE_SIGNATURE")) {
        auto result = runTool("hyprctl", {"-j", "getoption", "decoration:rounding"}, {}, 500);
        if (result.ok) m_radius = qBound(0, QJsonDocument::fromJson(result.output).object().value("int").toInt(), 30);
    }
    QFile language(m_languageFile);
    // Without the Omarchy language file, use the language of the system.
    QString code = QLocale::system().bcp47Name();
    if (language.open(QIODevice::ReadOnly)) code = QString::fromUtf8(language.readAll()).trimmed();
    if (!QRegularExpression("^[a-z]{2,3}(-[A-Za-z]{2,4})?$").match(code).hasMatch()) code = "en";
    m_language = code;
    m_catalog.strings = {};
    QStringList codes{"en", code.section('-', 0, 0), code};
    codes.removeDuplicates();
    for (const auto &catalogCode : codes) {
        QFile catalog(":/i18n/" + catalogCode + ".json");
        if (!catalog.open(QIODevice::ReadOnly)) continue;
        auto entries = QJsonDocument::fromJson(catalog.readAll()).object();
        for (auto it = entries.begin(); it != entries.end(); ++it) m_catalog.strings.insert(it.key(), it.value());
    }
    QLocale locale(code);
    const QString omarchyPath = qEnvironmentVariable("OMARCHY_PATH", "/usr/share/omarchy");
    QFile locales(omarchyPath + "/default/i18n/locales.json");
    if (locales.open(QIODevice::ReadOnly)) {
        const QString format = QJsonDocument::fromJson(locales.readAll()).object().value(code).toObject().value("formatLocale").toString();
        if (!format.isEmpty()) locale = QLocale(format);
    }
    QLocale::setDefault(locale);
    QGuiApplication::setLayoutDirection(locale.textDirection());
    emit changed();
}
