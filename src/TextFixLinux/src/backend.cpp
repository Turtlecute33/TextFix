// SPDX-License-Identifier: GPL-3.0-only
#include "backend.h"
#include "config.h"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUuid>

Backend::Backend(Desktop *desktop, const QString &directory, QObject *parent)
    : QObject(parent), m_desktop(desktop), m_directory(directory.isEmpty() ? Config::directory() : directory) {
    m_config = Config::load(m_directory, &m_loadError);
    m_readyStatus = tr("Ready");
    m_status = m_loadError.isEmpty() ? m_readyStatus : m_loadError;
    m_probe.setInterval(60);
    m_restore.setSingleShot(true);
    connect(&m_probe, &QTimer::timeout, this, [this] { probe(m_whole); });
    connect(&m_restore, &QTimer::timeout, this, &Backend::flushRestore);
    connect(&m_ai, &AiClient::finished, this, &Backend::completed);
}

Backend::~Backend() { cancel(); flushRestore(); }

void Backend::retranslate() {
    const QString ready = tr("Ready");
    if (m_status == m_readyStatus) setStatus(ready);
    m_readyStatus = ready;
}

void Backend::setStatus(const QString &message) { m_status = message; emit changed(); }

bool Backend::autostart() const {
    return QFile::exists(QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/autostart/textfix.desktop");
}

bool Backend::save(const QVariantMap &values, const QString &key, bool startAtLogin) {
    if (m_busy) { setStatus(tr("Cancel the current request before saving.")); return false; }
    QString error;
    // Refuse to overwrite a malformed or unreadable configuration, including one changed
    // outside the app since launch. The user's prompts must remain recoverable.
    Config::load(m_directory, &error);
    if (!error.isEmpty()) { setStatus(error); return false; }
    auto next = QJsonObject::fromVariantMap(values);
    const auto provider = next.value("provider").toString();
    if (provider != "openrouter" && provider != "payperq") { setStatus(tr("Choose a supported provider.")); return false; }
    if (!key.trimmed().isEmpty() && !Config::storeSecret(provider, key.trimmed(), &error)) { setStatus(error); return false; }
    if (!Config::save(m_directory, next, &error)) { setStatus(error); return false; }
    const QString autostartDirectory = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/autostart";
    const QString path = autostartDirectory + "/textfix.desktop";
    if (startAtLogin) {
        QDir().mkpath(autostartDirectory);
        QSaveFile file(path);
        QString executable = QCoreApplication::applicationFilePath();
        executable.replace('\\', "\\\\").replace('"', "\\\"").replace('`', "\\`").replace('$', "\\$").replace('%', "%%");
        const QByteArray entry = QString("[Desktop Entry]\nType=Application\nName=TextFix\nExec=\"%1\" --background\nIcon=textfix\nTerminal=false\n").arg(executable).toUtf8();
        if (!file.open(QIODevice::WriteOnly) || file.write(entry) != entry.size() || !file.commit()) {
            setStatus(tr("Settings saved, but the login entry could not be written.")); return false;
        }
    } else if (QFile::exists(path) && !QFile::remove(path)) {
        setStatus(tr("Settings saved, but the login entry could not be removed.")); return false;
    }
    m_config = next;
    emit settingsChanged();
    setStatus(tr("Saved"));
    return true;
}

void Backend::start(int action, bool clipboardOnly) {
    if (m_busy) { cancel(); return; }
    flushRestore();
    QString error;
    m_config = Config::load(m_directory, &error);
    if (!error.isEmpty()) { fail(error); return; }
    error = m_desktop->check(clipboardOnly);
    if (!error.isEmpty()) { fail(error); return; }
    if (action < 0 || action > 1) { fail(tr("Unknown action.")); return; }
    m_action = m_config.value("actions").toArray().at(action).toObject();
    if (!m_action.value("enabled").toBool()) { fail(tr("This action is disabled in config.json.")); return; }
    m_key.clear();
    if (!m_config.value("dryRun").toBool()) {
        const QString provider = m_config.value("provider").toString();
        if (provider != "openrouter" && provider != "payperq") { fail(tr("Choose a supported provider.")); return; }
        m_key = Config::secret(provider, &error);
        if (m_key.isEmpty()) { fail(error.isEmpty() ? tr("Add your API key in Settings.") : error); return; }
    }
    m_clipboardOnly = clipboardOnly;
    ++m_generation;
    m_busy = true;
    m_saved = {};
    m_clipboardToken.clear();
    setStatus(tr("Reading text…"));
    if (clipboardOnly) {
        bool ok;
        const QString text = m_desktop->text(&ok);
        if (!ok) { fail(tr("Could not read clipboard text.")); return; }
        m_clipboardToken = text;
        captured(text);
        return;
    }
    m_focus = m_desktop->focus();
    if (m_focus.id.isEmpty()) { fail(tr("No focused window. Nothing was changed.")); return; }
    m_terminal = Desktop::isTerminal(m_focus.app);
    m_saved = m_desktop->snapshot();
    if (!m_saved.valid) { fail(tr("Could not preserve the clipboard. Copy some text first, then try again.")); return; }
    m_marker = "textfix-probe-" + QUuid::createUuid().toString();
    if (!m_desktop->setText(m_marker)) { fail(tr("Could not write to the clipboard.")); return; }
    m_clipboardToken = m_marker;
    if (!m_desktop->shortcut(m_focus, "C", m_terminal)) { fail(tr("Could not copy from the focused window.")); return; }
    // Many hosts complete the copy before the helper returns. Record it immediately so
    // cancellation before the first polling tick can still restore the borrowed clipboard.
    bool copied;
    const QString immediate = m_desktop->text(&copied);
    if (copied && immediate != m_marker) m_clipboardToken = immediate;
    m_whole = false;
    m_copyWait.start();
    m_probe.start();
}

void Backend::probe(bool whole) {
    if (!m_busy) return;
    if (m_desktop->focus().id != m_focus.id) { fail(tr("Focus changed while reading. Nothing was replaced.")); return; }
    bool ok;
    const QString text = m_desktop->text(&ok);
    if (ok && text != m_marker) {
        m_probe.stop();
        m_clipboardToken = text;
        captured(text);
        return;
    }
    const int wait = qBound(100, m_config.value(whole ? "copyTimeoutMs" : "selectionProbeMs").toInt(whole ? 900 : 400), 5000);
    if (m_copyWait.elapsed() < wait) return;
    if (whole || m_terminal || !m_action.value("wholeTextWhenNoSelection").toBool(true)) {
        fail(tr("No selected text. Select editable text and try again.")); return;
    }
    if (!m_desktop->shortcut(m_focus, "A", false) || !m_desktop->shortcut(m_focus, "C", false)) {
        fail(tr("Could not select and copy this field.")); return;
    }
    m_whole = true;
    m_copyWait.restart();
}

void Backend::captured(const QString &text) {
    if (text.trimmed().isEmpty() || text.size() > qBound(1, m_config.value("maxInputLength").toInt(10000), 100000)) {
        fail(tr("The input was empty or too long. Nothing was sent.")); return;
    }
    m_input = text;
    m_prompt = m_action.value("prompt").toString();
    if (m_prompt.trimmed().isEmpty()) m_prompt = Config::fixPrompt();
    setStatus(tr("Fixing text… Press the shortcut again to cancel."));
    emit notice(m_status);
    if (m_config.value("dryRun").toBool()) {
        const quint64 generation = m_generation;
        QTimer::singleShot(0, this, [this, generation] { if (m_busy && m_generation == generation) completed(m_input.toUpper(), {}); });
        return;
    }
    auto requestConfig = m_config;
    const QString overrideModel = m_action.value("model").toString().trimmed();
    if (!overrideModel.isEmpty()) requestConfig.insert("model", overrideModel);
    const auto body = AiText::body(text, m_prompt, requestConfig);
    if (body.value("model").toString().trimmed().isEmpty()) { fail(tr("Choose a model in Settings.")); return; }
    m_ai.start(text, m_prompt, requestConfig, m_key);
    m_key.clear();
}

void Backend::completed(const QString &answer, const QString &error) {
    if (!m_busy) return;
    if (!error.isEmpty()) { fail(error); return; }
    QString cleanError;
    const QString output = AiText::clean(answer, m_input, m_prompt, &cleanError);
    if (!cleanError.isEmpty()) { fail(cleanError); return; }
    if (output == m_input) { fail(tr("No changes needed.")); return; }
    bool ok;
    const auto currentText = m_desktop->text(&ok);
    if (m_clipboardOnly && (!ok || currentText != m_clipboardToken)) {
        fail(tr("The clipboard changed during the request. Nothing was overwritten.")); return;
    }
    if (!m_clipboardOnly && m_desktop->focus().id != m_focus.id) {
        // Keep both the original clipboard and the new text safe. A focus change should never
        // overwrite a clipboard the user copied while the request was in flight.
        fail(tr("Focus changed during the request. Nothing was replaced; try again in the original field.")); return;
    }
    ClipboardData restoreTo = m_saved;
    if (!m_clipboardOnly && (!ok || currentText != m_clipboardToken)) {
        restoreTo = m_desktop->snapshot();
        if (!restoreTo.valid) { fail(tr("The clipboard changed and could not be preserved. Nothing was replaced.")); return; }
    }
    if (!m_desktop->setText(output)) { fail(tr("Could not write the result to the clipboard.")); return; }
    m_clipboardToken = output;
    if (!m_clipboardOnly && !m_desktop->shortcut(m_focus, "V", m_terminal)) {
        m_saved = restoreTo;
        fail(tr("Could not paste into the original window. Nothing was replaced.")); return;
    }
    m_busy = false;
    m_input.clear();
    if (!m_clipboardOnly && m_config.value("restoreClipboard").toBool(true)) {
        m_pending = restoreTo;
        m_restore.start(qBound(100, m_config.value("clipboardRestoreDelayMs").toInt(300), 5000));
    }
    m_saved = {};
    setStatus(m_clipboardOnly ? tr("Fixed text is on the clipboard. Paste it when ready.") : tr("Text replaced. Undo in the original app to restore it."));
    emit notice(m_status);
}

void Backend::restoreCapture() {
    if (!m_saved.valid || m_clipboardOnly) return;
    bool ok;
    if (m_desktop->text(&ok) == m_clipboardToken && ok) m_desktop->write(m_saved);
    m_saved = {};
}

void Backend::flushRestore() {
    m_restore.stop();
    if (!m_pending.valid) return;
    bool ok;
    if (m_desktop->text(&ok) == m_clipboardToken && ok && !m_desktop->write(m_pending))
        emit notice(tr("The clipboard could not be restored."));
    m_pending = {};
}

void Backend::cancel() {
    ++m_generation;
    m_ai.cancel();
    m_probe.stop();
    m_key.clear();
    if (m_busy) { restoreCapture(); m_busy = false; m_input.clear(); setStatus(tr("Cancelled")); }
    flushRestore();
}

void Backend::fail(const QString &message) {
    m_probe.stop();
    m_ai.cancel();
    restoreCapture();
    m_key.clear();
    m_input.clear();
    m_busy = false;
    setStatus(message);
    emit notice(message);
}
