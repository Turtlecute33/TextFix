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

QVariantList Backend::models(const QString &provider) const { return Config::models(provider); }

QString Backend::defaultPrompt(int action) const { return action == 1 ? Config::rewritePrompt() : Config::fixPrompt(); }

// Where the desktop has no place for the pill (GNOME on Wayland), "animation" shows the
// notification instead.
bool Backend::animate() const { return m_animation && m_config.value("indicator").toString() == "animation"; }

void Backend::announce(const QString &message, Notice kind) {
    emit notice(message, kind);
    if (kind != Progress) emit pillHidden();
    switch (kind) {
    case Progress:
        if (animate()) emit pillShown(false);
        // The notification stays for the time of the request, then the result replaces it.
        else if (m_config.value("indicator").toString() != "none")
            emit notify(message, qBound(5000, m_config.value("requestBudgetMs").toInt(90000), 300000) + 2000);
        break;
    case Done: emit clearNotification(); break;
    case Info: emit notify(message, 5000); break;
    case Error:
        if (m_config.value("notifyOnError").toBool(true)) emit notify(message, 8000);
        else emit clearNotification();
        break;
    }
}

bool Backend::save(const QVariantMap &values, const QString &key, bool startAtLogin) {
    if (m_busy) { setStatus(tr("Cancel the current request before saving.")); return false; }
    auto next = QJsonObject::fromVariantMap(values);
    const auto provider = next.value("provider").toString();
    if (provider != "openrouter" && provider != "payperq") { setStatus(tr("Choose a supported provider.")); return false; }
    if (next.value("model").toString() == "custom") {
        const QString custom = next.value("customModel").toString().trimmed();
        if (custom.isEmpty()) { setStatus(tr("Enter a custom model slug, or pick one from the list.")); return false; }
        if (!Config::validModelSlug(custom)) {
            setStatus(tr("That does not look like a model slug. Use author/model, for example openai/gpt-4o-mini.")); return false;
        }
        next.insert("customModel", custom);
    } else if (next.value("model").toString().trimmed().isEmpty()) {
        next.insert("model", Config::defaultModel());
    }
    QString error;
    Config::load(m_directory, &error);
    if (!error.isEmpty()) {
        // The file that TextFix could not read is the work of the user. Keep it adjacent to
        // the new file, as the other agents do. Do not write over it.
        const QString path = m_directory + "/config.json";
        QFile::remove(path + ".bad");
        if (!QFile::copy(path, path + ".bad")) {
            setStatus(tr("Could not keep the old config.json as config.json.bad. Nothing was saved.")); return false;
        }
        error.clear();
    }
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
    m_loadError.clear();
    emit settingsChanged();
    setStatus(tr("Saved"));
    return true;
}

void Backend::start(int action, bool clipboardOnly) {
    if (m_busy) { cancel(); return; }
    flushRestore();
    QString error;
    // A config.json with an error does not stop the fix. This request uses the default
    // settings, as on Windows and macOS, and the user gets the message after it.
    m_config = Config::load(m_directory, &error);
    if (error != m_loadError) m_loadWarned = false;
    m_loadError = error;
    error = m_desktop->check(clipboardOnly);
    if (!error.isEmpty()) { fail(error); return; }
    if (action < 0 || action > 1) { fail(tr("Unknown action.")); return; }
    m_action = m_config.value("actions").toArray().at(action).toObject();
    if (!m_action.value("enabled").toBool()) { fail(tr("This action is disabled in config.json.")); return; }
    m_clipboardOnly = clipboardOnly;
    // Read the focus before the key: a keyring that asks for its password takes the focus.
    Focus focus;
    if (!clipboardOnly) {
        focus = m_desktop->focus();
        if (focus.id.isEmpty()) { fail(tr("No focused window. Nothing was changed.")); return; }
        if (Desktop::isTerminal(focus)) {
            fail(tr("TextFix does not work in terminal windows. Copy the text, then run textfix clipboard.")); return;
        }
    }
    m_key.clear();
    if (!m_config.value("dryRun").toBool()) {
        const QString provider = m_config.value("provider").toString();
        if (provider != "openrouter" && provider != "payperq") { fail(tr("Choose a supported provider.")); return; }
        m_key = Config::secret(provider, &error);
        if (m_key.isEmpty()) { fail(error.isEmpty() ? tr("Add your API key in Settings.") : error); return; }
    }
    ++m_generation;
    m_busy = true;
    m_saved = {};
    m_clipboardToken.clear();
    setStatus(tr("Fixing text… Press the shortcut again to cancel."));
    // Shown before the text is read, so the user knows that the key was received.
    announce(m_status, Progress);
    if (clipboardOnly) {
        bool ok;
        const QString text = m_desktop->text(&ok);
        if (!ok) { fail(tr("Could not read clipboard text.")); return; }
        m_clipboardToken = text;
        captured(text);
        return;
    }
    m_focus = focus;
    m_saved = m_desktop->snapshot();
    if (!m_saved.valid) { fail(tr("Could not preserve the clipboard. Copy some text first, then try again.")); return; }
    m_marker = "textfix-probe-" + QUuid::createUuid().toString();
    if (!m_desktop->setText(m_marker)) { fail(tr("Could not write to the clipboard.")); return; }
    m_clipboardToken = m_marker;
    if (!m_desktop->shortcut(m_focus, "C")) { fail(tr("Could not copy from the focused window.")); return; }
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
        m_clipboardToken = text;
        // After Select All, an app that was slow can still answer the first copy with only
        // the selection. Wait one more tick and use what the clipboard has then, or the fixed
        // selection would replace the whole field.
        if (whole && !m_settled) { m_settled = true; return; }
        m_probe.stop();
        captured(text);
        return;
    }
    const int wait = qBound(100, m_config.value(whole ? "copyTimeoutMs" : "selectionProbeMs").toInt(whole ? 900 : 400), 5000);
    if (m_copyWait.elapsed() < wait) return;
    if (whole || !m_action.value("wholeTextWhenNoSelection").toBool(true)) {
        fail(tr("No selected text. Select editable text and try again.")); return;
    }
    if (!m_desktop->shortcut(m_focus, "A") || !m_desktop->shortcut(m_focus, "C")) {
        fail(tr("Could not select and copy this field.")); return;
    }
    m_whole = true;
    m_settled = false;
    m_copyWait.restart();
}

void Backend::captured(const QString &text) {
    const int limit = qBound(100, m_config.value("maxInputLength").toInt(10000), 100000);
    if (text.trimmed().isEmpty()) { fail(tr("There is no text to fix.")); return; }
    if (text.size() > limit) {
        fail(tr("The text is longer than %1 characters. Nothing was sent. Select a smaller part.").arg(limit)); return;
    }
    m_input = text;
    m_prompt = m_action.value("prompt").toString();
    if (m_prompt.trimmed().isEmpty()) m_prompt = Config::fixPrompt();
    setStatus(tr("Waiting for the answer… Press the shortcut again to cancel."));
    if (animate()) emit pillShown(true);
    if (m_config.value("dryRun").toBool()) {
        const quint64 generation = m_generation;
        QTimer::singleShot(0, this, [this, generation] { if (m_busy && m_generation == generation) completed(m_input.toUpper(), {}); });
        return;
    }
    auto requestConfig = m_config;
    const QString overrideModel = m_action.value("model").toString().trimmed();
    if (!overrideModel.isEmpty()) requestConfig.insert("model", overrideModel);
    if (AiText::resolveModel(requestConfig).isEmpty()) { fail(tr("Choose a model in Settings.")); return; }
    m_ai.start(text, m_prompt, requestConfig, m_key);
    m_key.clear();
}

void Backend::completed(const QString &answer, const QString &error) {
    if (!m_busy) return;
    if (!error.isEmpty()) { fail(error); return; }
    QString cleanError;
    const QString output = AiText::clean(answer, m_input, m_prompt, &cleanError);
    if (!cleanError.isEmpty()) { fail(cleanError); return; }
    if (output == m_input) { fail(tr("No changes needed. The text is already fine."), Info); return; }
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
    if (!m_clipboardOnly && !m_desktop->shortcut(m_focus, "V")) {
        m_saved = restoreTo;
        fail(tr("Could not paste into the original window. Nothing was replaced.")); return;
    }
    m_busy = false;
    m_whole = false;
    m_input.clear();
    if (!m_clipboardOnly && m_config.value("restoreClipboard").toBool(true)) {
        m_pending = restoreTo;
        m_restore.start(qBound(100, m_config.value("clipboardRestoreDelayMs").toInt(300), 5000));
    }
    m_saved = {};
    setStatus(m_clipboardOnly ? tr("Fixed text is on the clipboard. Paste it when ready.") : tr("Text replaced. Undo in the original app to restore it."));
    // In direct mode the changed text is the feedback, so the progress notification only closes.
    announce(m_status, m_clipboardOnly ? Info : Done);
    const QString model = m_action.value("model").toString().trimmed().isEmpty()
        ? AiText::resolveModel(m_config) : m_action.value("model").toString().trimmed();
    if (m_ai.fellBackFromZdr() && !m_config.value("dryRun").toBool() && !m_zdrWarned.contains(model)) {
        m_zdrWarned.insert(model);
        announce(tr("No zero-retention route for %1. TextFix used a provider that does not keep your text for training.").arg(model), Info);
    }
    if (!m_loadError.isEmpty() && !m_loadWarned) {
        m_loadWarned = true;
        announce(m_loadError, Error);
    }
}

// Select All left the whole field selected and nothing was pasted over it. With the text still
// selected, the next key that the user types would replace all of it.
void Backend::collapseSelection() {
    if (m_whole && !m_clipboardOnly) m_desktop->shortcut(m_focus, "Right");
    m_whole = false;
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
        announce(tr("The clipboard could not be restored."), Error);
    m_pending = {};
}

void Backend::cancel() {
    ++m_generation;
    m_ai.cancel();
    m_probe.stop();
    m_key.clear();
    if (m_busy) {
        collapseSelection();
        restoreCapture();
        m_busy = false;
        m_input.clear();
        setStatus(tr("Cancelled"));
        announce(m_status, Done);
    }
    flushRestore();
}

void Backend::fail(const QString &message, Notice kind) {
    m_probe.stop();
    m_ai.cancel();
    if (m_busy) collapseSelection();
    restoreCapture();
    m_key.clear();
    m_input.clear();
    m_busy = false;
    setStatus(message);
    announce(message, kind);
}
