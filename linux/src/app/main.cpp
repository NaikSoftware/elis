#include "assistantrunner.h"
#include "control.h"
#include "help.h"
#include "hooks.h"
#include "library.h"
#include "zmx.h"
#include "mainwindow.h"
#include "paths.h"
#include "phone.h"
#include "smoothwheel.h"
#include "store.h"
#include "upload.h"
#ifdef ELIS_HAS_WEBENGINE
#include "pagecontent.h"
#endif

#include <KConfig>
#include <KConfigGroup>
#include <KSharedConfig>
#include <QApplication>
#include <QDBusConnection>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QIcon>
#include <QJsonDocument>
#include <QLocalServer>
#include <QLocalSocket>
#include <QLockFile>
#include <QMessageBox>
#include <QPalette>
#include <QPointer>
#include <QSocketNotifier>
#include <QTimer>

#include <csignal>
#include <optional>
#include <sys/socket.h>
#include <unistd.h>

// A freedesktop Inhibit/UnInhibit hold while on. The service drops it when this process's bus connection closes, so a
// crash leaves none behind. With no such service nothing is held.
struct Inhibitor {
    Inhibitor(QString service, QString path, QString iface)
        : service(std::move(service))
        , path(std::move(path))
        , iface(std::move(iface))
    {
    }
    const QString service, path, iface;
    QObject context;
    bool wanted = false, pending = false;
    std::optional<uint> cookie;
    void set(bool on)
    {
        wanted = on;
        reconcile();
    }
    void reconcile()
    {
        if (pending) // its reply reconciles
            return;
        if (!wanted && cookie) {
            QDBusConnection::sessionBus().asyncCall(QDBusMessage::createMethodCall(service, path, iface, QStringLiteral("UnInhibit")) << *cookie);
            cookie.reset();
        } else if (wanted && !cookie) {
            pending = true;
            const QDBusMessage call = QDBusMessage::createMethodCall(service, path, iface, QStringLiteral("Inhibit")) << QStringLiteral("Elis")
                                                                                                                       << QStringLiteral("An agent is working");
            auto *watcher = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(call), &context);
            QObject::connect(watcher, &QDBusPendingCallWatcher::finished, &context, [this, watcher] {
                watcher->deleteLater();
                pending = false;
                const QDBusPendingReply<uint> reply = *watcher;
                if (!reply.isValid())
                    return qWarning("%s: %s", qPrintable(iface), qPrintable(reply.error().message())); // retried at the next false -> true
                cookie = reply.value();
                reconcile();
            });
        }
    }
};

// One request line in, one response line out, then the connection closes.
static void serve(QLocalServer &server, WindowLibrary &library)
{
    QObject::connect(&server, &QLocalServer::newConnection, &server, [&] {
        while (QLocalSocket *socket = server.nextPendingConnection()) {
            QObject::connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
            QObject::connect(socket, &QLocalSocket::readyRead, socket, [socket, &library] {
                if (!socket->canReadLine()) {
                    if (socket->bytesAvailable() > maxRequestBytes)
                        socket->abort();
                    return;
                }
                QJsonParseError err{};
                const auto doc = QJsonDocument::fromJson(socket->readLine(maxRequestBytes + 1), &err);
                auto send = [](QLocalSocket *to, const QJsonObject &r) {
                    to->write(QJsonDocument(r).toJson(QJsonDocument::Compact) + '\n');
                    to->disconnectFromServer();
                };
                static const QStringList phone{"phone.status", "phone.enable", "phone.port", "phone.host", "phone.revoke"};
                if (phone.contains(doc.object().value("cmd").toString())) // app-wide, and enable/port/revoke answer late
                    return phoneCommand(doc.object(), [send, to = QPointer<QLocalSocket>(socket)](const QJsonObject &r) {
                        if (to)
                            send(to, r);
                    });
                const QJsonObject response = doc.isObject() ? library.dispatch(doc.object())
                                                            : QJsonObject{{"ok", false}, {"error", QStringLiteral("bad request: %1").arg(err.errorString())}};
                MainWindow::answer(socket, response, [send, socket](const QJsonObject &r) { send(socket, r); });
            });
        }
    });
}

// A roomier default profile for this app only; KonsolePart hosts keep their own DefaultProfile, so Konsole is untouched
// and a profile the user picks later in Settings wins.
static void ensureProfile()
{
    KConfigGroup entry = KSharedConfig::openConfig()->group(QStringLiteral("Desktop Entry"));
    if (!entry.readEntry("DefaultProfile", QString()).isEmpty())
        return;
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/konsole");
    const QString file = dir + QStringLiteral("/elis.profile");
    if (!QFile::exists(file)) {
        QDir().mkpath(dir);
        KConfig profile(file, KConfig::SimpleConfig);
        profile.group(QStringLiteral("General")).writeEntry("Name", "elis");
        profile.group(QStringLiteral("General")).writeEntry("Parent", "FALLBACK/");
        profile.group(QStringLiteral("General")).writeEntry("TerminalMargin", 10);
        profile.group(QStringLiteral("Appearance")).writeEntry("ColorScheme", "Breeze");
        profile.sync();
    }
    entry.writeEntry("DefaultProfile", "elis.profile");
    entry.sync();
}

// elis --install agent-hooks|cli|skill|all [--home DIR]: the extras the launch installs, run by hand
static int installFromCommandLine(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    const QStringList args = app.arguments();
    const qsizetype at = args.indexOf(QStringLiteral("--home"));
    const QString home = at > 0 && at + 1 < args.size() ? args[at + 1] : QDir::homePath();
    const QString which = args.value(2);
    int failed = 0;
    for (const QString &one : which == QLatin1String("all") ? QStringList{"cli", "agent-hooks", "skill"} : QStringList{which}) {
        const Install::Report r = runInstaller(one, home);
        if (!r.error.isEmpty())
            fprintf(stderr, "Install Failed: %s\n", qPrintable(r.error)), ++failed;
        else
            printf("%s\n%s\n\n", qPrintable(r.title), qPrintable(r.text()));
    }
    if (which == QLatin1String("all") && at < 0 && !failed) { // the launch's stamp names this user's home only
        QDir().mkpath(stateDir());
        if (QFile stamp(extrasStamp()); stamp.open(QIODevice::WriteOnly | QIODevice::Truncate))
            stamp.write(extrasFingerprint() + '\n');
    }
    return failed ? 1 : 0;
}

// The brand copper as the palette's Highlight (D2); the rest stays the desktop's. Re-applied when the desktop
// scheme changes, since that replaces the whole palette.
class Accent : public QObject
{
public:
    using QObject::QObject;
    static void apply()
    {
        QPalette pal = QApplication::palette();
        const QColor copper(pal.color(QPalette::Window).lightness() < 128 ? 0xE08A45 : 0xC8742F);
        if (pal.color(QPalette::Highlight) == copper)
            return; // setPalette posts another palette change
        for (auto group : {QPalette::Active, QPalette::Inactive})
            pal.setColor(group, QPalette::Highlight, copper), pal.setColor(group, QPalette::HighlightedText, Qt::white);
        QApplication::setPalette(pal);
    }
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (watched == qApp && event->type() == QEvent::ApplicationPaletteChange)
            apply();
        return false;
    }
};

int main(int argc, char **argv)
{
    if (argc > 1 && qstrcmp(argv[1], "--install") == 0)
        return installFromCommandLine(argc, argv);
#ifdef ELIS_HAS_WEBENGINE
    registerPageScheme();
#endif
    QApplication app(argc, argv);
    app.installEventFilter(new SmoothWheel(&app));
    Accent::apply();
    app.installEventFilter(new Accent(&app));
    app.setApplicationName(QStringLiteral("elis")); // also names the Konsole-part profile namespace
    app.setApplicationVersion(QLatin1String(appVersion));
    app.setDesktopFileName(QStringLiteral("elis"));
    Q_INIT_RESOURCE(resources); // before the window: the fallback icon lives in the static UI library
    app.setWindowIcon(QIcon::fromTheme(QStringLiteral("elis"), QIcon(QStringLiteral(":/elis.png"))));

    const QString dir = stateDir();
    QDir().mkpath(dir);
    // two instances on one state dir would each rewrite the whole file from memory and lose the other's sessions
    QLockFile lock(dir + QStringLiteral("/elis.lock"));
    if (!lock.tryLock(0)) {
        QMessageBox::warning(nullptr, QStringLiteral("Elis"), QStringLiteral("Elis is already running on %1").arg(dir));
        return 1;
    }

    ensureProfile();
    Zmx::recordBuild(dir); // before any pane starts a daemon, which would otherwise date before the cutoff
    // no suspend, and no blanking or the lock after it, so an agent can still see and drive the desktop
    Inhibitor suspendHold(QStringLiteral("org.freedesktop.PowerManagement"), QStringLiteral("/org/freedesktop/PowerManagement/Inhibit"),
                          QStringLiteral("org.freedesktop.PowerManagement.Inhibit"));
    Inhibitor screenHold(QStringLiteral("org.freedesktop.ScreenSaver"), QStringLiteral("/org/freedesktop/ScreenSaver"),
                         QStringLiteral("org.freedesktop.ScreenSaver"));
    WindowLibrary library(dir);
    library.keepAwake = [&](bool on) {
        suspendHold.set(on);
        screenHold.set(on);
    };
    library.load(); // the windows open at the last quit, each with its saved frame
    AssistantRunner assistant(library, dir);
    library.assistantSink = &assistant;
    MainWindow &window = *library.active();
    // master's reap: Fresh shells and Re-run launches end every daemon a live run left, a live one those no pane claims
    for (const auto &e : library.entries())
        if (e.store) { // a window closed at the last quit has no store loaded
            Zmx::reap(dir, e.store->restoreModeAtLaunch, library.paneIds());
            break;
        }

    uploadSweep(dir, library.sessionIds());

    QLocalServer server;
    QLocalServer::removeServer(socketPath()); // safe: the lock says no live instance owns it
    server.setSocketOptions(QLocalServer::UserAccessOption);
    const bool listening = server.listen(socketPath());
    if (!listening)
        qWarning("control socket %s: %s", qPrintable(socketPath()), qPrintable(server.errorString()));
    for (MainWindow *w : library.openWindows())
        w->setSocketStatus(listening, server.errorString());
    serve(server, library);
    PhoneRelay::instance(); // phone access switched on in Connect a Phone comes back with the app
    // app-wide events, as the Mac's emitAppEvent; the window holding the pane rereads its tree's phoneViewers/phoneLead
    QObject::connect(PhoneRelay::instance(), &PhoneRelay::phoneEvent, &library, [&library](const QString &kind, const QJsonObject &payload) {
        MainWindow *holder = nullptr;
        for (MainWindow *w : library.openWindows())
            if (w->holdsPane(payload.value("paneID").toString()))
                holder = w;
        (holder ? holder : library.active())->events()->emitAppEvent(kind, payload);
        if (holder)
            holder->events()->scheduleTreeChanged();
    });
    window.events()->emitEvent(QStringLiteral("app.launched")); // hooks loaded, socket accepting, sessions restored

    // SIGTERM (logout, kill) must save like a window close; a self-pipe moves it onto the event loop
    static int sigFd[2];
    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, sigFd) == 0) {
        auto *notifier = new QSocketNotifier(sigFd[1], QSocketNotifier::Read, &app);
        QObject::connect(notifier, &QSocketNotifier::activated, &app, &QCoreApplication::quit);
        for (int sig : {SIGTERM, SIGINT, SIGHUP})
            std::signal(sig, [](int) { [[maybe_unused]] auto n = ::write(sigFd[0], "x", 1); });
    }
    QObject::connect(&app, &QCoreApplication::aboutToQuit, &library, [&library] {
        for (MainWindow *w : library.openWindows())
            w->save();
        library.saveIndex();
    });
    installExtrasOnUpdate(); // first launch or a new install: hooks, skill and the elisctl link follow the build
    if (const QString shot = qEnvironmentVariable("ELIS_SCREENSHOT"); !shot.isEmpty()) // dev aid for UI review
        QTimer::singleShot(6000, &window, [&window, shot] { window.grab().save(shot); });

    return app.exec();
}
