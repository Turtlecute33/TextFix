// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <QFileSystemWatcher>
#include <QJsonObject>
#include <QTranslator>

class Catalog : public QTranslator {
public:
    QJsonObject strings;
    QString translate(const char *, const char *text, const char * = nullptr, int = -1) const override {
        return strings.value(QString::fromUtf8(text)).toString();
    }
    bool isEmpty() const override { return false; }
};

class Theme : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString accent MEMBER m_accent NOTIFY changed)
    Q_PROPERTY(QString background MEMBER m_background NOTIFY changed)
    Q_PROPERTY(QString foreground MEMBER m_foreground NOTIFY changed)
    Q_PROPERTY(int radius MEMBER m_radius NOTIFY changed)
    Q_PROPERTY(QString language MEMBER m_language NOTIFY changed)
public:
    explicit Theme(const QString &current = {}, const QString &languageFile = {}, QObject *parent = nullptr);
    ~Theme() override;
    Q_INVOKABLE void reload();
signals:
    void changed();
private:
    QString m_current, m_languageFile;
    QString m_accent = "#FFD60A", m_background = "#151519", m_foreground = "#eeeeee", m_language;
    int m_radius = 0;
    QFileSystemWatcher m_watcher;
    Catalog m_catalog;
};
