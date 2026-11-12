// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <QByteArray>
#include <QMap>
#include <QStringList>

struct ToolResult { bool ok = false; QByteArray output, diagnostic; };
ToolResult runTool(const QString &program, const QStringList &arguments, const QByteArray &input = {}, int timeout = 1500);
struct ClipboardData {
    QMap<QString, QByteArray> formats;
    bool valid = false;
};
// terminal is true when the compositor tags the window as a terminal (Omarchy does).
struct Focus { QString id, app; bool terminal = false; };

// The interface lets pipeline tests simulate focus and clipboard races without sending keys.
class Desktop {
public:
    virtual ~Desktop() = default;
    virtual QString name() const = 0;
    virtual QString check(bool clipboardOnly) const = 0;
    virtual Focus focus() = 0;
    virtual bool shortcut(const Focus &target, const QString &key) = 0;
    virtual ClipboardData snapshot() = 0;
    virtual QString text(bool *ok) = 0;
    virtual bool write(const ClipboardData &data) = 0;
    virtual bool setText(const QString &text);
    static bool isTerminal(const Focus &focus);
};

class LinuxDesktop : public Desktop {
public:
    LinuxDesktop();
    QString name() const override;
    QString check(bool clipboardOnly) const override;
    Focus focus() override;
    bool shortcut(const Focus &target, const QString &key) override;
    ClipboardData snapshot() override;
    QString text(bool *ok) override;
    bool write(const ClipboardData &data) override;
private:
    bool m_wayland, m_hyprland, m_lua = false;
};
