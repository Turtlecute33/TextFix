// SPDX-License-Identifier: GPL-3.0-only
#include "aiclient.h"
#include "backend.h"
#include "config.h"
#include "desktop.h"
#include "theme.h"
#include "tray.h"
#include <QCryptographicHash>
#include <QFile>
#include <QGuiApplication>
#include <QIcon>
#include <QJsonDocument>
#include <QJsonArray>
#include <QLocalServer>
#include <QLocalSocket>
#include <QLockFile>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QStandardPaths>
#include <QTextStream>
#include <memory>

static const char help[] =
    "TextFix - fix text in place on Linux\n"
    "Usage: textfix [settings|fix|rewrite|clipboard|cancel|quit|filter|doctor|--background]\n"
    "  settings       Open settings (the default)\n"
    "  fix / rewrite  Fix the selection or whole editable field on Hyprland/X11\n"
    "  clipboard      Fix copied text; paste the result yourself (--rewrite supported)\n"
    "  filter         Read stdin, write corrected text to stdout (--rewrite, --json)\n"
    "  doctor         Print desktop/tool diagnostics (--json supported)\n"
    "  --background   Run without opening settings\n"
    "  cancel / quit  Cancel the current request / stop the background agent\n"
    "  --version      Print the build version\n"
    "  --help         Show this help\n"
    "Bind commands in desktop shortcuts; invoke again while busy to cancel.\n";

int main(int argc, char *argv[]) {
    QStringList arguments;
    for (int i = 1; i < argc; ++i) arguments.append(QString::fromLocal8Bit(argv[i]));
    const QString command = arguments.isEmpty() ? "settings" : arguments.first();
    if (command == "--help" || command == "-h") { QTextStream(stdout) << help; return 0; }
    if (command == "--version") { QTextStream(stdout) << "TextFix " << TEXTFIX_VERSION << '\n'; return 0; }
    const QStringList commands{"settings", "fix", "rewrite", "clipboard", "cancel", "quit", "filter", "doctor", "--background"};
    if (!commands.contains(command)) { QTextStream(stderr) << help; return 2; }
    for (int i = 1; i < arguments.size(); ++i) {
        const auto &option = arguments[i];
        if ((option == "--json" && (command == "filter" || command == "doctor")) ||
            (option == "--rewrite" && (command == "filter" || command == "clipboard"))) continue;
        QTextStream(stderr) << "Unknown option: " << option << '\n'; return 2;
    }
    if (command == "doctor" || command == "filter") {
        qputenv("QT_QPA_PLATFORM", "offscreen");
        qputenv("QT_QPA_PLATFORMTHEME", "");
    }
    const auto session = QCryptographicHash::hash((qEnvironmentVariable("WAYLAND_DISPLAY") + ":" + qEnvironmentVariable("DISPLAY")).toUtf8(), QCryptographicHash::Sha256).toHex().left(12);
    const QString socketName = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation) + "/textfix-" + session + ".sock";
    const QByteArray request = (command + (arguments.contains("--rewrite") ? " --rewrite" : "") + "\n").toUtf8();
    auto forward = [&] {
        QLocalSocket socket;
        socket.connectToServer(socketName);
        if (!socket.waitForConnected(500)) return false;
        socket.write(request);
        socket.waitForBytesWritten(500);
        return socket.waitForReadyRead(2000) && socket.readLine().trimmed() == "ok";
    };
    if (command != "doctor" && command != "filter") {
        // The usual case: a shortcut starts this program while the agent runs. Pass the command
        // on without a display connection, which is most of the start time of a Qt GUI program.
        QCoreApplication client(argc, argv);
        if (forward()) return 0;
        if (command == "cancel" || command == "quit") return 0;
    }
    QGuiApplication app(argc, argv);
    app.setApplicationName("textfix");
    app.setApplicationVersion(TEXTFIX_VERSION);
    app.setDesktopFileName("textfix");
    app.setWindowIcon(QIcon(":/textfix.svg"));
    app.setQuitOnLastWindowClosed(false);

    if (command == "doctor") {
        LinuxDesktop desktop;
        QJsonObject tools;
        for (const auto &tool : {"hyprctl", "wl-copy", "wl-paste", "xdotool", "xprop", "secret-tool"})
            tools.insert(tool, !QStandardPaths::findExecutable(tool).isEmpty());
        const QString issue = desktop.check(false);
        QJsonObject report{{"version", TEXTFIX_VERSION}, {"desktop", desktop.name()}, {"tools", tools},
                           {"directReplacement", issue.isEmpty()}, {"issue", issue}, {"configDirectory", Config::directory()}};
        QTextStream(stdout) << QJsonDocument(report).toJson(arguments.contains("--json") ? QJsonDocument::Compact : QJsonDocument::Indented) << '\n';
        return issue.isEmpty() ? 0 : 1;
    }

    if (command == "filter") {
        const bool json = arguments.contains("--json");
        auto finish = [json](const QString &text, const QString &error) {
            if (json) QTextStream(stdout) << QJsonDocument(QJsonObject{{"ok", error.isEmpty()}, {"text", text}, {"error", error}}).toJson(QJsonDocument::Compact) << '\n';
            else if (error.isEmpty()) QTextStream(stdout) << text;
            if (!error.isEmpty()) QTextStream(stderr) << error << '\n';
            return error.isEmpty() ? 0 : 1;
        };
        QString error;
        auto config = Config::load(Config::directory(), &error);
        if (!error.isEmpty()) return finish({}, error);
        QFile input;
        if (!input.open(stdin, QIODevice::ReadOnly)) return finish({}, QObject::tr("Could not read stdin."));
        const QByteArray bytes = input.read(400001);
        const QString text = QString::fromUtf8(bytes);
        if (bytes.size() > 400000 || text.trimmed().isEmpty() || text.size() > qBound(1, config.value("maxInputLength").toInt(10000), 100000))
            return finish({}, QObject::tr("The input was empty or too long."));
        const auto action = config.value("actions").toArray().at(arguments.contains("--rewrite") ? 1 : 0).toObject();
        const QString prompt = action.value("prompt").toString();
        if (config.value("dryRun").toBool()) return finish(text.toUpper(), {});
        const QString provider = config.value("provider").toString();
        if (provider != "openrouter" && provider != "payperq") return finish({}, QObject::tr("Choose a supported provider."));
        const QString key = Config::secret(provider, &error);
        if (key.isEmpty()) return finish({}, error.isEmpty() ? QObject::tr("No API key available.") : error);
        if (!action.value("model").toString().trimmed().isEmpty()) config.insert("model", action.value("model"));
        if (AiText::body(text, prompt, config).value("model").toString().trimmed().isEmpty()) return finish({}, QObject::tr("Choose a model in Settings."));
        AiClient ai;
        QObject::connect(&ai, &AiClient::finished, &app, [&](const QString &answer, const QString &failure) {
            QString error = failure;
            QString output;
            if (error.isEmpty()) output = AiText::clean(answer, text, prompt, &error);
            app.exit(finish(output, error));
        });
        ai.start(text, prompt, config, key);
        return app.exec();
    }

    QLockFile lock(socketName + ".lock");
    if (!lock.tryLock(0)) {
        if (forward()) return 0;
        QTextStream(stderr) << "TextFix is starting or its session socket is unavailable. Try again.\n";
        return 1;
    }
    QLocalServer::removeServer(socketName);
    QLocalServer server;
    server.setSocketOptions(QLocalServer::UserAccessOption);
    if (!server.listen(socketName)) { QTextStream(stderr) << "Could not create the session socket.\n"; return 1; }

    LinuxDesktop desktop;
    Backend backend(&desktop);
    Tray tray;
    QObject::connect(&backend, &Backend::notify, &tray, &Tray::notify);
    QObject::connect(&backend, &Backend::clearNotification, &tray, &Tray::clearNotification);
    QObject::connect(&tray, &Tray::cancel, &backend, &Backend::cancel);
    QObject::connect(&app, &QCoreApplication::aboutToQuit, &backend, &Backend::cancel);
    // The theme also loads the language, and the notifications need it before Settings opens.
    Theme theme;
    backend.retranslate();
    QObject::connect(&theme, &Theme::changed, &backend, &Backend::retranslate);
    std::unique_ptr<QQmlApplicationEngine> engine;
    QQuickStyle::setStyle("Material");
    auto openSettings = [&] {
        if (!engine) {
            engine = std::make_unique<QQmlApplicationEngine>();
            QObject::connect(&theme, &Theme::changed, engine.get(), &QQmlEngine::retranslate);
            engine->rootContext()->setContextProperty("theme", &theme);
            engine->rootContext()->setContextProperty("backend", &backend);
            engine->load(QUrl("qrc:/Main.qml"));
            if (engine->rootObjects().isEmpty()) {
                // The agent can work without the window, so it stays. The usual cause is a
                // Qt Quick Controls package that is not installed.
                engine.reset();
                const QString message = QObject::tr("Settings could not open. Install the Qt Quick Controls packages that the TextFix guide lists.");
                QTextStream(stderr) << message << '\n';
                tray.notify(message, 10000);
                return;
            }
        }
        QMetaObject::invokeMethod(engine->rootObjects().first(), "open");
    };
    QObject::connect(&tray, &Tray::openSettings, &app, openSettings);
    auto dispatch = [&](const QString &request) {
        if (request == "quit") { backend.cancel(); app.quit(); }
        else if (request == "cancel") backend.cancel();
        else if (request == "settings") openSettings();
        else if (request == "fix" || request == "rewrite") backend.start(request == "rewrite" ? 1 : 0);
        else if (request == "clipboard" || request == "clipboard --rewrite") backend.start(request.endsWith("--rewrite") ? 1 : 0, true);
    };
    QObject::connect(&server, &QLocalServer::newConnection, &app, [&] {
        while (auto *socket = server.nextPendingConnection()) {
            auto read = [&, socket] {
                if (socket->bytesAvailable() > 128) { socket->disconnectFromServer(); return; }
                if (!socket->canReadLine()) return;
                const QString request = QString::fromUtf8(socket->readLine()).trimmed();
                socket->write("ok\n");
                socket->flush();
                socket->disconnectFromServer();
                QTimer::singleShot(0, &app, [&, request] { dispatch(request); });
            };
            QObject::connect(socket, &QLocalSocket::readyRead, &app, read);
            QObject::connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
            QTimer::singleShot(2000, socket, [socket] { socket->disconnectFromServer(); });
            read();
        }
    });
    QTimer::singleShot(0, &app, [&] { dispatch(QString::fromUtf8(request).trimmed()); });
    return app.exec();
}
