// SPDX-License-Identifier: GPL-3.0-only
#include "desktop.h"
#include <QClipboard>
#include <QElapsedTimer>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMimeData>
#include <QProcess>
#include <QRegularExpression>
#include <QStandardPaths>

ToolResult runTool(const QString &program, const QStringList &arguments, const QByteArray &input, int timeout) {
    QProcess process;
    process.start(program, arguments);
    if (!process.waitForStarted(timeout)) return {};
    if (!input.isEmpty()) process.write(input);
    process.closeWriteChannel();
    QElapsedTimer elapsed;
    elapsed.start();
    QByteArray output, diagnostic;
    while (process.state() != QProcess::NotRunning) {
        process.waitForFinished(qMin(50, timeout));
        output += process.readAllStandardOutput();
        diagnostic += process.readAllStandardError();
        // Clipboard owners and helpers are external processes. Never wait indefinitely or
        // allocate an unbounded clipboard image just to restore it after a tiny text edit.
        if (elapsed.elapsed() > timeout || output.size() > 16 * 1024 * 1024 || diagnostic.size() > 65536) {
            process.kill();
            process.waitForFinished(500);
            return {};
        }
    }
    output += process.readAllStandardOutput();
    diagnostic += process.readAllStandardError();
    return {process.exitStatus() == QProcess::NormalExit && process.exitCode() == 0, output, diagnostic};
}

bool Desktop::setText(const QString &text) {
    return write({{{"text/plain;charset=utf-8", text.toUtf8()}}, true});
}

bool Desktop::isTerminal(const QString &app) {
    static const QRegularExpression pattern("(kitty|alacritty|ghostty|foot|wezterm|gnome-terminal|konsole|xterm|tilix|terminator)",
                                            QRegularExpression::CaseInsensitiveOption);
    return pattern.match(app).hasMatch();
}

LinuxDesktop::LinuxDesktop()
    : m_wayland(!qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY") || qEnvironmentVariable("XDG_SESSION_TYPE") == "wayland"),
      m_hyprland(m_wayland && !qEnvironmentVariableIsEmpty("HYPRLAND_INSTANCE_SIGNATURE")) {
    if (m_hyprland) m_lua = runTool("hyprctl", {"--help"}).output.contains("eval");
}

QString LinuxDesktop::name() const {
    return m_hyprland ? "Hyprland" : m_wayland ? "Wayland (clipboard mode)" : "X11";
}

QString LinuxDesktop::check(bool clipboardOnly) const {
    const QStringList tools = m_wayland ? QStringList{"wl-copy", "wl-paste"} : clipboardOnly ? QStringList{} : QStringList{"xdotool", "xprop"};
    for (const auto &tool : tools)
        if (QStandardPaths::findExecutable(tool).isEmpty()) return QObject::tr("Missing required tool: %1").arg(tool);
    if (m_hyprland && !clipboardOnly && QStandardPaths::findExecutable("hyprctl").isEmpty())
        return QObject::tr("Missing required tool: hyprctl");
    if (m_wayland && !m_hyprland && !clipboardOnly)
        return QObject::tr("This Wayland desktop requires clipboard mode. Copy your text, run textfix clipboard, then paste the result.");
    return {};
}

Focus LinuxDesktop::focus() {
    if (m_hyprland) {
        auto result = runTool("hyprctl", {"-j", "activewindow"});
        if (!result.ok) return {};
        auto object = QJsonDocument::fromJson(result.output).object();
        const QString id = object.value("address").toString();
        if (!QRegularExpression("^0x[0-9a-fA-F]+$").match(id).hasMatch() || id == "0x0") return {};
        return {id, object.value("class").toString()};
    }
    if (!m_wayland) {
        auto result = runTool("xdotool", {"getwindowfocus"});
        const QString id = QString::fromUtf8(result.output).trimmed();
        if (!result.ok || !QRegularExpression("^[0-9]+$").match(id).hasMatch()) return {};
        const auto app = runTool("xprop", {"-id", id, "WM_CLASS"});
        if (!app.ok) return {};
        return {id, QString::fromUtf8(app.output)};
    }
    return {};
}

bool LinuxDesktop::shortcut(const Focus &target, const QString &key, bool terminal) {
    if (target.id.isEmpty() || focus().id != target.id) return false;
    const QString mods = terminal && key != "A" ? "CTRL SHIFT" : "CTRL";
    if (m_hyprland) {
        // IDs and keys are validated; no input text or secrets ever become shell/Lua code.
        if (!QStringList{"A", "C", "V"}.contains(key)) return false;
        const auto result = m_lua
            ? runTool("hyprctl", {"eval", "hl.dispatch(hl.dsp.send_shortcut({mods=\"" + mods + "\",key=\"" + key + "\",window=\"address:" + target.id + "\"}))"})
            : runTool("hyprctl", {"dispatch", "sendshortcut", mods + "," + key + ",address:" + target.id});
        const QByteArray lower = result.output.toLower();
        return result.ok && !lower.contains("error") && !lower.contains("unknown") && !lower.contains("invalid");
    }
    return !m_wayland && runTool("xdotool", {"key", "--clearmodifiers", terminal && key != "A" ? "ctrl+shift+" + key.toLower() : "ctrl+" + key.toLower()}).ok;
}

ClipboardData LinuxDesktop::snapshot() {
    ClipboardData saved;
    if (m_wayland) {
        const auto types = runTool("wl-paste", {"--list-types"});
        if (!types.ok) {
            // wl-paste exits nonzero both for an empty clipboard and a dead compositor. Only
            // accept the former when its diagnostic explicitly says there is no selection.
            // A separate text read cannot distinguish those cases, so fail without borrowing it.
            if (types.diagnostic.contains("Nothing is copied")) return {{}, true};
            return saved;
        }
        const auto formats = QString::fromUtf8(types.output).split('\n', Qt::SkipEmptyParts);
        if (formats.isEmpty()) return {{}, true};
        QString mime;
        for (const auto &preferred : {QString("text/plain;charset=utf-8"), QString("text/plain"), QString("image/png")})
            if (formats.contains(preferred)) { mime = preferred; break; }
        if (mime.isEmpty()) mime = formats.first();
        const auto data = runTool("wl-paste", {"--no-newline", "--type", mime});
        if (!data.ok) return saved;
        saved.formats.insert(mime, data.output);
    } else {
        const auto *mime = QGuiApplication::clipboard()->mimeData();
        if (mime) for (const auto &format : mime->formats()) saved.formats.insert(format, mime->data(format));
    }
    saved.valid = true;
    return saved;
}

QString LinuxDesktop::text(bool *ok) {
    if (m_wayland) {
        const auto result = runTool("wl-paste", {"--no-newline", "--type", "text"});
        *ok = result.ok;
        return QString::fromUtf8(result.output);
    }
    *ok = true;
    return QGuiApplication::clipboard()->text();
}

bool LinuxDesktop::write(const ClipboardData &data) {
    if (!data.valid) return false;
    if (m_wayland) {
        if (data.formats.isEmpty()) return runTool("wl-copy", {"--clear"}).ok;
        const auto it = data.formats.constBegin();
        // Sensitive hints are supported by newer wl-clipboard. Older versions still work,
        // with their normal clipboard history behavior, which is documented in the README.
        static const bool sensitive = runTool("wl-copy", {"--help"}).output.contains("--sensitive");
        QStringList args{"--type", it.key()};
        if (sensitive) args.append("--sensitive");
        return runTool("wl-copy", args, it.value()).ok;
    }
    auto *mime = new QMimeData;
    for (auto it = data.formats.begin(); it != data.formats.end(); ++it) mime->setData(it.key(), it.value());
    QGuiApplication::clipboard()->setMimeData(mime);
    return true;
}
