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
    QString clipboard = "original clipboard", selection = "rough text", whole = "whole field", pasted;
    Focus active{"window1", "editor"};
    QStringList keys;
    bool available = true;
    std::function<void()> beforeCopy;
    QString name() const override { return "Test desktop"; }
    QString check(bool) const override { return {}; }
    Focus focus() override { return active; }
    bool shortcut(const Focus &target, const QString &key) override {
        if (target.id != active.id) return false;
        keys.append(key);
        if (key == "C") { if (beforeCopy) beforeCopy(); if (!selection.isEmpty()) clipboard = selection; }
        if (key == "A") selection = whole;
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

// A local HTTP server that plays the provider. The script gets the number of the request and
// its JSON body, and returns the status line and the body of the answer.
class FakeProvider : public QObject {
public:
    struct Answer { QByteArray status = "200 OK", body, headers; };
    std::function<Answer(int, const QJsonObject &)> script;
    QList<QJsonObject> requests;
    QTcpServer server;
    FakeProvider() {
        server.listen(QHostAddress::LocalHost);
        connect(&server, &QTcpServer::newConnection, this, [this] {
            auto *socket = server.nextPendingConnection();
            auto *request = new QByteArray;
            connect(socket, &QTcpSocket::readyRead, socket, [this, socket, request] {
                request->append(socket->readAll());
                const int headerEnd = request->indexOf("\r\n\r\n");
                if (headerEnd < 0) return;
                const auto match = QRegularExpression("Content-Length: ([0-9]+)", QRegularExpression::CaseInsensitiveOption).match(QString::fromUtf8(request->left(headerEnd)));
                if (request->size() < headerEnd + 4 + match.captured(1).toInt()) return;
                requests.append(QJsonDocument::fromJson(request->mid(headerEnd + 4)).object());
                const Answer answer = script(requests.size(), requests.last());
                socket->write("HTTP/1.1 " + answer.status + "\r\n" + answer.headers + "Content-Type: application/json\r\nContent-Length: "
                              + QByteArray::number(answer.body.size()) + "\r\nConnection: close\r\n\r\n" + answer.body);
                socket->disconnectFromHost();
            });
            connect(socket, &QTcpSocket::disconnected, socket, [socket, request] { delete request; socket->deleteLater(); });
        });
    }
    QUrl url() const { return QUrl(QString("http://127.0.0.1:%1/").arg(server.serverPort())); }
    static QByteArray fixed() { return R"({"choices":[{"finish_reason":"stop","message":{"content":"fixed"}}]})"; }
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
    void init() { AiClient::forgetRouteFacts(); }
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
    void malformedConfigIsKeptAsBad() {
        QTemporaryDir dir;
        write(dir.filePath("config.json"), "{bad json");
        FakeDesktop desktop;
        Backend backend(&desktop, dir.path());
        QVERIFY(backend.save(Config::defaults().toVariantMap(), {}, false));
        QFile kept(dir.filePath("config.json.bad"));
        QVERIFY(kept.open(QIODevice::ReadOnly));
        QCOMPARE(kept.readAll(), QByteArray("{bad json"));
        QString error;
        Config::load(dir.path(), &error);
        QVERIFY(error.isEmpty());
    }
    void malformedConfigStillFixesWithDefaults() {
        QTemporaryDir dir;
        write(dir.filePath("config.json"), "{bad json");
        qputenv("TEXTFIX_API_KEY", "test-key");
        FakeDesktop desktop;
        Backend backend(&desktop, dir.path());
        QStringList errors;
        connect(&backend, &Backend::notice, this, [&](const QString &message, int kind) { if (kind == Backend::Error) errors.append(message); });
        backend.start(0);
        QVERIFY(backend.busy());
        backend.cancel();
        qunsetenv("TEXTFIX_API_KEY");
        QCOMPARE(desktop.clipboard, "original clipboard");
    }
    void untouchedOldPromptMovesToTheNewOne() {
        QTemporaryDir dir;
        QJsonObject old{{"actions", QJsonArray{QJsonObject{{"prompt", QString(Config::legacyFixPrompts().first()).replace("\n", "\r\n")}},
                                                 QJsonObject{{"prompt", "mine"}}}}};
        write(dir.filePath("config.json"), QJsonDocument(old).toJson());
        QString error;
        const auto actions = Config::load(dir.path(), &error).value("actions").toArray();
        QCOMPARE(actions[0].toObject().value("prompt").toString(), Config::fixPrompt());
        QCOMPARE(actions[1].toObject().value("prompt").toString(), "mine");
        QVERIFY(Config::fixPrompt().contains(QString::fromUtf8("\xF0\x9F\x8E\x89")));
        QVERIFY(Config::fixPrompt().endsWith("<text-{nonce}>\n{text}\n</text-{nonce}>"));
    }
    void modelListStartsWithTheDefaultAndChecksCustomSlugs() {
        for (const QString provider : {"openrouter", "payperq"})
            QCOMPARE(Config::models(provider).first().toMap().value("slug").toString(), Config::defaultModel());
        QVERIFY(Config::validModelSlug("~openai/gpt-luna-latest"));
        QVERIFY(Config::validModelSlug("author/model.v2:free"));
        QVERIFY(!Config::validModelSlug("gpt-4o"));
        QVERIFY(!Config::validModelSlug("author/has space"));
        QTemporaryDir dir;
        FakeDesktop desktop;
        Backend backend(&desktop, dir.path());
        auto values = Config::defaults().toVariantMap();
        values.insert("model", "custom");
        values.insert("customModel", "not a slug");
        QVERIFY(!backend.save(values, {}, false));
        values.insert("customModel", " author/model ");
        QVERIFY(backend.save(values, {}, false));
        QCOMPARE(AiText::resolveModel(QJsonObject::fromVariantMap(backend.settings())), "author/model");
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
        int status = 0;
        QVERIFY(AiText::parse(R"({"error":{"code":401}})", &error, &status).isEmpty());
        QCOMPARE(status, 401);
        QCOMPARE(error, AiText::errorMessage(401));
        error.clear();
        // content:null must not come back as an answer. A second request usually has one.
        QVERIFY(AiText::parse(R"({"choices":[{"finish_reason":"stop","message":{"content":null,"reasoning":"scratch"}}]})", &error, &status).isEmpty());
        QCOMPARE(status, int(AiText::Unusable));
        QVERIFY(AiText::retryable(status));
        QVERIFY(!AiText::retryable(401));
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
    void wholeFieldIsNotLeftSelectedWhenNothingIsPasted() {
        QTemporaryDir dir;
        configure(dir.path());
        FakeDesktop desktop;
        desktop.selection.clear();
        // Upper case already, so the dry run finds nothing to change and nothing is pasted.
        desktop.whole = "WHOLE FIELD";
        Backend backend(&desktop, dir.path());
        backend.start(0);
        QTRY_VERIFY(!backend.busy());
        QVERIFY(desktop.pasted.isEmpty());
        QCOMPARE(desktop.keys, QStringList({"C", "A", "C", "Right"}));
        QCOMPARE(desktop.clipboard, "original clipboard");
        // A selection of the user is not touched.
        FakeDesktop selected;
        selected.selection = "SELECTED";
        Backend second(&selected, dir.path());
        second.start(0);
        QTRY_VERIFY(!second.busy());
        QCOMPARE(selected.keys, QStringList({"C"}));
    }
    void terminalIsRefusedBeforeAnyKey() {
        QTemporaryDir dir;
        configure(dir.path());
        for (const Focus &terminal : {Focus{"w", "com.mitchellh.ghostty"}, Focus{"w", "org.omarchy.btop"},
                                      Focus{"w", "WM_CLASS(STRING) = \"xterm\", \"XTerm\""}, Focus{"w", "custom-class", true}}) {
            FakeDesktop desktop;
            desktop.active = terminal;
            Backend backend(&desktop, dir.path());
            backend.start(0);
            QVERIFY(!backend.busy());
            QVERIFY(backend.status().contains("terminal"));
            QVERIFY(desktop.keys.isEmpty());
            QCOMPARE(desktop.clipboard, "original clipboard");
        }
        QVERIFY(!Desktop::isTerminal(Focus{"w", "org.mozilla.firefox"}));
        QVERIFY(!Desktop::isTerminal(Focus{"w", "footage-editor"}));
    }
    void notificationsFollowTheSettings() {
        QTemporaryDir dir;
        auto config = Config::defaults();
        config.insert("dryRun", true);
        config.insert("selectionProbeMs", 100);
        config.insert("indicator", "none");
        config.insert("notifyOnError", false);
        QString error;
        QVERIFY(Config::save(dir.path(), config, &error));
        FakeDesktop desktop;
        Backend backend(&desktop, dir.path());
        QSignalSpy shown(&backend, &Backend::notify);
        QSignalSpy cleared(&backend, &Backend::clearNotification);
        backend.start(0);
        QTRY_VERIFY(!backend.busy());
        QCOMPARE(desktop.pasted, "ROUGH TEXT");
        desktop.active = Focus{"w", "kitty"};
        backend.start(0);
        QCOMPARE(shown.size(), 0);
        QVERIFY(cleared.size() >= 2);
        config.insert("indicator", "notification");
        config.insert("notifyOnError", true);
        QVERIFY(Config::save(dir.path(), config, &error));
        backend.start(0);
        QCOMPARE(shown.size(), 1);
        QVERIFY(shown[0][0].toString().contains("terminal"));
    }
    void focusChangePreventsPaste() {
        QTemporaryDir dir;
        configure(dir.path());
        FakeDesktop desktop;
        Backend backend(&desktop, dir.path());
        connect(&backend, &Backend::changed, this, [&] { if (backend.status().startsWith("Waiting")) desktop.active.id = "other"; });
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
        connect(&backend, &Backend::changed, this, [&] { if (backend.status().startsWith("Waiting")) desktop.clipboard = "new user copy"; });
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
        FakeProvider provider;
        bool redirect = false;
        provider.script = [&](int request, const QJsonObject &) -> FakeProvider::Answer {
            if (redirect) return {"307 Temporary Redirect", {}, "Location: /elsewhere\r\n"};
            if (request == 1) return {"503 Unavailable", {}, "Retry-After: 0\r\n"};
            // An HTTP 200 with no answer in it is tried again immediately.
            if (request == 2) return {"200 OK", R"({"choices":[{"finish_reason":"stop","message":{"content":null}}]})", {}};
            return {"200 OK", FakeProvider::fixed(), {}};
        };
        AiClient ai(nullptr, provider.url());
        QSignalSpy results(&ai, &AiClient::finished);
        ai.start("rough", "prompt", Config::defaults(), "test-key");
        QTRY_COMPARE(results.size(), 1);
        QCOMPARE(provider.requests.size(), 3);
        QCOMPARE(results[0][0].toString(), "fixed");
        QVERIFY(results[0][1].toString().isEmpty());
        QVERIFY(!ai.fellBackFromZdr());
        redirect = true;
        ai.start("rough", "prompt", Config::defaults(), "test-key");
        QTRY_COMPARE(results.size(), 2);
        QCOMPARE(provider.requests.size(), 4);
        QVERIFY(!results[1][1].toString().isEmpty());
    }
    void statusErrorsAreNotRetriedAndSayWhatToDo() {
        FakeProvider provider;
        QByteArray status = "401 Unauthorized";
        provider.script = [&](int, const QJsonObject &) -> FakeProvider::Answer { return {status, R"({"error":{"message":"account acct_123"}})", {}}; };
        AiClient ai(nullptr, provider.url());
        QSignalSpy results(&ai, &AiClient::finished);
        int expected = 0;
        for (const int code : {401, 402, 404}) {
            status = QByteArray::number(code) + " Error";
            ai.start("rough", "prompt", Config::defaults(), "test-key");
            ++expected;
            QTRY_COMPARE(results.size(), expected);
            QCOMPARE(provider.requests.size(), expected);
            QCOMPARE(results.last()[1].toString(), AiText::errorMessage(code));
            // The body of the provider can name the account. It must not reach the user or a log.
            QVERIFY(!results.last()[1].toString().contains("acct_123"));
        }
    }
    void zdrFallsBackOnlyToProvidersThatDoNotTrain() {
        FakeProvider provider;
        const QByteArray noRoute = R"json({"error":{"code":404,"message":"No endpoints found matching your data policy (ZDR)"}})json";
        provider.script = [&](int, const QJsonObject &body) -> FakeProvider::Answer {
            if (body.value("provider").toObject().value("zdr").toBool()) return {"404 Not Found", noRoute, {}};
            return {"200 OK", FakeProvider::fixed(), {}};
        };
        AiClient ai(nullptr, provider.url());
        QSignalSpy results(&ai, &AiClient::finished);
        ai.start("rough", "prompt", Config::defaults(), "test-key");
        QTRY_COMPARE(results.size(), 1);
        QCOMPARE(results[0][0].toString(), "fixed");
        QVERIFY(ai.fellBackFromZdr());
        QCOMPARE(provider.requests.size(), 2);
        QCOMPARE(provider.requests[1].value("provider").toObject().value("data_collection").toString(), "deny");
        QVERIFY(!provider.requests[1].value("provider").toObject().contains("zdr"));
        // The verdict is remembered, so the next fix does not pay for the attempt that fails.
        ai.start("rough", "prompt", Config::defaults(), "test-key");
        QTRY_COMPARE(results.size(), 2);
        QCOMPARE(provider.requests.size(), 3);
        QVERIFY(ai.fellBackFromZdr());
        // When no provider meets the weaker rule, the fix fails. It never goes below it.
        AiClient::forgetRouteFacts();
        provider.script = [&](int, const QJsonObject &) -> FakeProvider::Answer { return {"404 Not Found", noRoute, {}}; };
        ai.start("rough", "prompt", Config::defaults(), "test-key");
        QTRY_COMPARE(results.size(), 3);
        QCOMPARE(provider.requests.size(), 5);
        QVERIFY(results[2][1].toString().contains("privacy setting"));
        for (const auto &request : provider.requests) QVERIFY(request.contains("provider"));
    }
    void reasoningSwitchIsDroppedWhenARouteRefusesIt() {
        FakeProvider provider;
        provider.script = [&](int, const QJsonObject &body) -> FakeProvider::Answer {
            if (body.contains("reasoning")) return {"400 Bad Request", R"({"error":{"message":"Reasoning is mandatory for this endpoint and cannot be disabled."}})", {}};
            return {"200 OK", FakeProvider::fixed(), {}};
        };
        AiClient ai(nullptr, provider.url());
        QSignalSpy results(&ai, &AiClient::finished);
        ai.start("rough", "prompt", Config::defaults(), "test-key");
        QTRY_COMPARE(results.size(), 1);
        QCOMPARE(results[0][0].toString(), "fixed");
        QCOMPARE(provider.requests.size(), 2);
        QVERIFY(provider.requests[1].value("provider").toObject().value("zdr").toBool());
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
        // For the README picture: the colours of a theme, and the tab to show.
        const auto colors = qEnvironmentVariable("TEXTFIX_TEST_COLORS");
        if (!colors.isEmpty()) { QDir().mkpath(dir.filePath("theme")); write(dir.filePath("theme/colors.toml"), colors.toUtf8()); }
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
        auto *tabs = window->findChild<QObject *>("tabs");
        QVERIFY(tabs);
        QCOMPARE(tabs->property("count").toInt(), 3);
        // Each tab must load with no warning, not only the first one.
        for (int tab = 2; tab >= 0; --tab) {
            tabs->setProperty("currentIndex", tab);
            QTest::qWait(60);
        }
        tabs->setProperty("currentIndex", qEnvironmentVariableIntValue("TEXTFIX_TEST_TAB"));
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
