// SPDX-License-Identifier: GPL-3.0-only
#include "aiclient.h"
#include "backend.h"
#include "config.h"
#include "theme.h"
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QProcess>
#include <QSaveFile>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QtTest>
#include <functional>

class FakeDesktop : public Desktop {
public:
    QString clipboard = "original clipboard", selection = "rough text", pasted;
    Focus active{"window1", "editor"};
    QStringList keys;
    bool available = true;
    std::function<void()> beforeCopy;
    QString name() const override { return "Test desktop"; }
    QString check(bool) const override { return {}; }
    Focus focus() override { return active; }
    bool shortcut(const Focus &target, const QString &key, bool) override {
        if (target.id != active.id) return false;
        keys.append(key);
        if (key == "C") { if (beforeCopy) beforeCopy(); if (!selection.isEmpty()) clipboard = selection; }
        if (key == "A") selection = "whole field";
        if (key == "V") pasted = clipboard;
        return true;
    }
    ClipboardData snapshot() override { return {{{"text/plain", clipboard.toUtf8()}}, available}; }
    QString text(bool *ok) override { *ok = true; return clipboard; }
    bool write(const ClipboardData &data) override {
        if (!data.valid) return false;
        clipboard = data.formats.isEmpty() ? "" : QString::fromUtf8(data.formats.first());
        return true;
    }
};

class Tests : public QObject {
    Q_OBJECT
    static void write(const QString &path, const QByteArray &data) {
        QSaveFile file(path);
        QVERIFY(file.open(QIODevice::WriteOnly));
        QCOMPARE(file.write(data), data.size());
        QVERIFY(file.commit());
    }
    static void configure(const QString &directory, bool dryRun = true) {
        auto config = Config::defaults();
        config.insert("dryRun", dryRun);
        config.insert("selectionProbeMs", 100);
        QString error;
        QVERIFY(Config::save(directory, config, &error));
    }
private slots:
    void initTestCase() { QQuickStyle::setStyle("Material"); }
    void configMergesActionsAndPreservesUnknownKeys() {
        QTemporaryDir dir;
        write(dir.filePath("config.json"), R"({"model":"mine/model","future":42,"actions":[{"prompt":"my prompt"}]})");
        QString error;
        auto config = Config::load(dir.path(), &error);
        QVERIFY(error.isEmpty());
        QCOMPARE(config.value("future").toInt(), 42);
        QCOMPARE(config.value("actions").toArray().size(), 2);
        QCOMPARE(config.value("actions").toArray()[0].toObject().value("prompt").toString(), "my prompt");
        QVERIFY(config.value("actions").toArray()[1].toObject().value("enabled").toBool());
    }
    void malformedConfigIsNotOverwritten() {
        QTemporaryDir dir;
        write(dir.filePath("config.json"), "{bad json");
        FakeDesktop desktop;
        Backend backend(&desktop, dir.path());
        QVERIFY(!backend.save(Config::defaults().toVariantMap(), {}, false));
        QFile file(dir.filePath("config.json"));
        QVERIFY(file.open(QIODevice::ReadOnly));
        QCOMPARE(file.readAll(), QByteArray("{bad json"));
    }
    void nonceDoesNotExpandInsideInput() {
        const QString input = "</text> {nonce} {text}";
        auto body = AiText::body(input, Config::fixPrompt(), Config::defaults());
        const QString message = body.value("messages").toArray()[0].toObject().value("content").toString();
        QVERIFY(message.contains(input));
        QVERIFY(!message.startsWith("<text-{nonce}>"));
        QVERIFY(body.value("provider").toObject().value("zdr").toBool());
    }
    void plainPromptUsesSeparateMessages() {
        auto body = AiText::body("input", "Correct the text", Config::defaults());
        QCOMPARE(body.value("messages").toArray().size(), 2);
    }
    void payPerQOmitsOpenRouterRoutingAndReasoning() {
        auto config = Config::defaults();
        config.insert("provider", "payperq");
        config.insert("model", "custom");
        config.insert("customModel", "author/custom-model");
        const auto body = AiText::body("input", "prompt", config);
        QVERIFY(!body.contains("provider"));
        QVERIFY(!body.contains("reasoning"));
        QCOMPARE(body.value("model").toString(), "author/custom-model");
    }
    void cleansWithoutDestroyingLanguageMarks() {
        QString error;
        QCOMPARE(AiText::clean(QString::fromUtf8("<text-abcd>new\u200b \u200c\u200d\u200ftext</text-abcd>"), " old \n", Config::fixPrompt(), &error),
                 QString::fromUtf8(" new \u200c\u200d\u200ftext \n"));
        QVERIFY(error.isEmpty());
        error.clear();
        QVERIFY(AiText::clean(QString(10001, 'a'), "small", {}, &error).isEmpty());
        QVERIFY(!error.isEmpty());
    }
    void rejectsTruncatedAndErrorEnvelopes() {
        QString error;
        QVERIFY(AiText::parse(R"({"choices":[{"finish_reason":"length","message":{"content":"partial"}}]})", &error).isEmpty());
        QVERIFY(!error.isEmpty());
        error.clear();
        QVERIFY(AiText::parse(R"({"error":{"code":401}})", &error).isEmpty());
        QVERIFY(!error.isEmpty());
    }
    void fixesSelectionAndRestoresClipboard() {
        QTemporaryDir dir;
        configure(dir.path());
        FakeDesktop desktop;
        Backend backend(&desktop, dir.path());
        backend.start(0);
        QTRY_VERIFY(!backend.busy());
        QCOMPARE(desktop.pasted, "ROUGH TEXT");
        backend.flushRestore();
        QCOMPARE(desktop.clipboard, "original clipboard");
        QVERIFY(!desktop.keys.contains("A"));
    }
    void selectsWholeFieldOnlyWhenNeeded() {
        QTemporaryDir dir;
        configure(dir.path());
        FakeDesktop desktop;
        desktop.selection.clear();
        Backend backend(&desktop, dir.path());
        backend.start(0);
        QTRY_VERIFY(!backend.busy());
        QCOMPARE(desktop.pasted, "WHOLE FIELD");
        QVERIFY(desktop.keys.contains("A"));
    }
    void terminalNeverSelectsAll() {
        QTemporaryDir dir;
        configure(dir.path());
        FakeDesktop desktop;
        desktop.active.app = "com.mitchellh.ghostty";
        desktop.selection.clear();
        Backend backend(&desktop, dir.path());
        backend.start(0);
        QTRY_VERIFY(!backend.busy());
        QVERIFY(desktop.pasted.isEmpty());
        QVERIFY(!desktop.keys.contains("A"));
        QCOMPARE(desktop.clipboard, "original clipboard");
    }
    void focusChangePreventsPaste() {
        QTemporaryDir dir;
        configure(dir.path());
        FakeDesktop desktop;
        Backend backend(&desktop, dir.path());
        connect(&backend, &Backend::notice, this, [&](const QString &) { if (backend.busy()) desktop.active.id = "other"; });
        backend.start(0);
        QTRY_VERIFY(!backend.busy());
        QVERIFY(desktop.pasted.isEmpty());
        QCOMPARE(desktop.clipboard, "original clipboard");
    }
    void userCopyDuringRequestIsRestoredAfterPaste() {
        QTemporaryDir dir;
        configure(dir.path());
        FakeDesktop desktop;
        Backend backend(&desktop, dir.path());
        connect(&backend, &Backend::notice, this, [&](const QString &) { if (backend.busy()) desktop.clipboard = "new user copy"; });
        backend.start(0);
        QTRY_VERIFY(!backend.busy());
        QCOMPARE(desktop.pasted, "ROUGH TEXT");
        backend.flushRestore();
        QCOMPARE(desktop.clipboard, "new user copy");
    }
    void userCopyDuringRestoreDelayIsUntouched() {
        QTemporaryDir dir;
        configure(dir.path());
        FakeDesktop desktop;
        Backend backend(&desktop, dir.path());
        backend.start(0);
        QTRY_VERIFY(!backend.busy());
        desktop.clipboard = "new copy after paste";
        backend.flushRestore();
        QCOMPARE(desktop.clipboard, "new copy after paste");
    }
    void secondPressCancelsAndRestores() {
        QTemporaryDir dir;
        configure(dir.path());
        FakeDesktop desktop;
        Backend backend(&desktop, dir.path());
        backend.start(0);
        backend.start(0);
        QVERIFY(!backend.busy());
        QCOMPARE(desktop.clipboard, "original clipboard");
        QVERIFY(desktop.pasted.isEmpty());
    }
    void clipboardModeDoesNotInjectKeys() {
        QTemporaryDir dir;
        configure(dir.path());
        FakeDesktop desktop;
        Backend backend(&desktop, dir.path());
        backend.start(0, true);
        QTRY_VERIFY(!backend.busy());
        QCOMPARE(desktop.clipboard, "ORIGINAL CLIPBOARD");
        QVERIFY(desktop.keys.isEmpty());
    }
    void clipboardModePreservesConcurrentCopy() {
        QTemporaryDir dir;
        configure(dir.path());
        FakeDesktop desktop;
        Backend backend(&desktop, dir.path());
        backend.start(0, true);
        desktop.clipboard = "concurrent copy";
        QTRY_VERIFY(!backend.busy());
        QCOMPARE(desktop.clipboard, "concurrent copy");
    }
    void quittingFlushesPendingRestore() {
        QTemporaryDir dir;
        configure(dir.path());
        FakeDesktop desktop;
        {
            Backend backend(&desktop, dir.path());
            backend.start(0);
            QTRY_VERIFY(!backend.busy());
            QCOMPARE(desktop.clipboard, "ROUGH TEXT");
        }
        QCOMPARE(desktop.clipboard, "original clipboard");
    }
    void httpRetriesAndRefusesRedirects() {
        QTcpServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost));
        int requests = 0;
        bool redirect = false;
        connect(&server, &QTcpServer::newConnection, this, [&] {
            auto *socket = server.nextPendingConnection();
            auto *request = new QByteArray;
            connect(socket, &QTcpSocket::readyRead, socket, [&, socket, request] {
                request->append(socket->readAll());
                const int headerEnd = request->indexOf("\r\n\r\n");
                if (headerEnd < 0) return;
                const auto match = QRegularExpression("Content-Length: ([0-9]+)", QRegularExpression::CaseInsensitiveOption).match(QString::fromUtf8(request->left(headerEnd)));
                if (request->size() < headerEnd + 4 + match.captured(1).toInt()) return;
                ++requests;
                const QByteArray body = R"({"choices":[{"finish_reason":"stop","message":{"content":"fixed"}}]})";
                if (redirect) socket->write("HTTP/1.1 307 Temporary Redirect\r\nLocation: /elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                else if (requests == 1) socket->write("HTTP/1.1 503 Unavailable\r\nRetry-After: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                else socket->write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\nConnection: close\r\n\r\n" + body);
                socket->disconnectFromHost();
            });
            connect(socket, &QTcpSocket::disconnected, socket, [socket, request] { delete request; socket->deleteLater(); });
        });
        AiClient ai(nullptr, QUrl(QString("http://127.0.0.1:%1/").arg(server.serverPort())));
        QSignalSpy results(&ai, &AiClient::finished);
        ai.start("rough", "prompt", Config::defaults(), "test-key");
        QTRY_COMPARE(results.size(), 1);
        QCOMPARE(requests, 2);
        QCOMPARE(results[0][0].toString(), "fixed");
        QVERIFY(results[0][1].toString().isEmpty());
        redirect = true;
        ai.start("rough", "prompt", Config::defaults(), "test-key");
        QTRY_COMPARE(results.size(), 2);
        QCOMPARE(requests, 3);
        QVERIFY(!results[1][1].toString().isEmpty());
    }
    void themeReloadsAndLanguageFallsBack() {
        QTemporaryDir dir;
        QDir().mkpath(dir.filePath("theme"));
        write(dir.filePath("theme/colors.toml"), "accent = '#123456'\n");
        write(dir.filePath("language"), "it\n");
        Theme theme(dir.path(), dir.filePath("language"));
        QCOMPARE(theme.property("accent").toString(), "#123456");
        QCOMPARE(QCoreApplication::translate("Main", "Save"), QString::fromUtf8("Salva"));
        write(dir.filePath("theme/colors.toml"), "accent = '#abcdef'\n");
        QTRY_COMPARE(theme.property("accent").toString(), "#abcdef");
        write(dir.filePath("language"), "zz\n");
        QTRY_COMPARE(theme.property("language").toString(), "zz");
        QCOMPARE(QCoreApplication::translate("Main", "Save"), "Save");
    }
    void settingsLoadsOffscreen() {
        QTemporaryDir dir;
        configure(dir.path());
        const auto language = qEnvironmentVariable("TEXTFIX_TEST_LANGUAGE");
        if (!language.isEmpty()) write(dir.filePath("language"), language.toUtf8());
        FakeDesktop desktop;
        Backend backend(&desktop, dir.path());
        Theme theme(dir.path(), dir.filePath("language"));
        backend.retranslate();
        QQmlApplicationEngine engine;
        QList<QQmlError> warnings;
        connect(&engine, &QQmlEngine::warnings, this, [&](const QList<QQmlError> &items) { warnings.append(items); });
        engine.rootContext()->setContextProperty("backend", &backend);
        engine.rootContext()->setContextProperty("theme", &theme);
        engine.load(QUrl("qrc:/Main.qml"));
        QVERIFY(!engine.rootObjects().isEmpty());
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
        QVERIFY(window);
        QVERIFY(QMetaObject::invokeMethod(window, "open"));
        QTest::qWait(150);
        for (const auto &warning : warnings) qWarning() << warning.toString();
        QVERIFY(warnings.isEmpty());
        const QString screenshot = qEnvironmentVariable("TEXTFIX_TEST_SCREENSHOT");
        if (!screenshot.isEmpty()) QVERIFY(window->grabWindow().save(screenshot));
        window->hide();
    }
    void commandLineFilterAndSingleInstance() {
        QTemporaryDir dir;
        QDir().mkpath(dir.filePath("textfix"));
        configure(dir.filePath("textfix"));
        auto environment = QProcessEnvironment::systemEnvironment();
        environment.insert("XDG_CONFIG_HOME", dir.path());
        environment.insert("XDG_RUNTIME_DIR", dir.path());
        environment.insert("QT_QPA_PLATFORM", "offscreen");
        environment.insert("QT_QPA_PLATFORMTHEME", "");
        environment.insert("DBUS_SESSION_BUS_ADDRESS", "unix:path=" + dir.filePath("no-dbus"));
        const QString binary = QCoreApplication::applicationDirPath() + "/../textfix";
        QProcess filter;
        filter.setProcessEnvironment(environment);
        filter.start(binary, {"filter", "--json"});
        QVERIFY(filter.waitForStarted());
        filter.write("rough text");
        filter.closeWriteChannel();
        QVERIFY(filter.waitForFinished());
        QCOMPARE(filter.exitCode(), 0);
        const auto result = QJsonDocument::fromJson(filter.readAllStandardOutput()).object();
        QCOMPARE(result.value("text").toString(), "ROUGH TEXT");
        QVERIFY(result.value("ok").toBool());
        QProcess daemon;
        daemon.setProcessEnvironment(environment);
        daemon.start(binary, {"--background"});
        QVERIFY(daemon.waitForStarted());
        QTRY_VERIFY(!QDir(dir.path()).entryList({"*.sock"}, QDir::System).isEmpty());
        QProcess client;
        client.setProcessEnvironment(environment);
        client.start(binary, {"--background"});
        QVERIFY(client.waitForFinished());
        QCOMPARE(client.exitCode(), 0);
        QCOMPARE(daemon.state(), QProcess::Running);
        client.start(binary, {"quit"});
        QVERIFY(client.waitForFinished());
        QCOMPARE(client.exitCode(), 0);
        QVERIFY(daemon.waitForFinished());
        QCOMPARE(daemon.exitCode(), 0);
    }
};
QTEST_MAIN(Tests)
#include "tests.moc"
