#include "mainwindow.h"
#include "assistantrunner.h"
#include "detectedlaunchers.h"
#include "cipanel.h"
#include "help.h"
#include "hooks.h"
#include "library.h"
#include "palette.h"
#include "sidebar.h"
#include "store.h"

#include <QScopeGuard>
#include <QApplication>
#include <QCheckBox>
#include <QDir>
#include <QFile>
#include <KActionCollection>
#include <KPageDialog>
#include <KParts/PartLoader>
#include <KParts/ReadOnlyPart>
#include <kde_terminal_interface.h>
#include <QEventLoop>
#include <QThread>
#include <QLineEdit>
#include <QListWidget>
#include <QDialog>
#include <QFrame>
#include <QLabel>
#include <QDesktopServices>
#include <QMenu>
#include <QMenuBar>
#include <QTimer>
#include <QElapsedTimer>
#include <QSet>
#include <algorithm>
#include <numeric>
#include <memory>
#include <signal.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <QPointer>
#include <QTemporaryDir>
#include <QToolButton>
#include <QSignalSpy>
#include <QJsonDocument>
#include <QJsonArray>
#include <QToolBar>
#include <QTest>
#include <QWheelEvent>
#include "control.h"
#include <QPushButton>
#include <QWheelEvent>
#include "smoothwheel.h"
#include "phone.h"
#include <QTcpServer>
#include "paneleadcover.h"
#include "elis_bridge.h"
#include "zmx.h"
#include "paths.h"
#include <QProcess>
#include <QUuid>
#include "konsoleprivate.h"
#include "assistantview.h"
#include <QAbstractItemView>
#include <QCompleter>
#include <QDragEnterEvent>
#include <QMimeData>
#include <QPlainTextEdit>
#include <QStackedWidget>

namespace Konsole
{
// stands in for the part's display: SmoothWheel picks its target by this class name
class TerminalDisplay : public QWidget
{
    Q_OBJECT
public:
    QList<int> deltas;

protected:
    void wheelEvent(QWheelEvent *e) override { deltas << e->angleDelta().y(); }
};
}

// records each URL QDesktopServices opens, and whether `watched` was still on screen then
class UrlSink : public QObject
{
    Q_OBJECT
public:
    QPointer<QWidget> watched;
    QList<QUrl> opened;
    bool watchedVisible = false;
    Q_INVOKABLE void open(const QUrl &url)
    {
        opened << url;
        watchedVisible = watched && watched->isVisible();
    }
};

// a library whose chat chose `choice` ("" for none), run by `standIn` in place of its binary; `detected` agents are
// found on a PATH that leads with a directory of its own
struct AssistantHost {
    QTemporaryDir state;
    DetectedLaunchers launchers;
    std::unique_ptr<WindowLibrary> lib;
    std::unique_ptr<AssistantRunner> runner;
    static QString path() { return QStringLiteral("/nonexistent-detected:") + qEnvironmentVariable("PATH"); }
    // resume: the stored conversation ids, as <state>/assistant/chat.jsonl.resume holds them
    explicit AssistantHost(const QByteArray &standIn, const QByteArray &choice = "claude", bool detected = true, const QByteArray &resume = {})
    {
        QDir().mkpath(state.filePath("assistant"));
        if (!resume.isEmpty()) {
            QFile file(state.filePath("assistant/chat.jsonl.resume"));
            if (file.open(QIODevice::WriteOnly))
                file.write(resume);
        }
        if (!choice.isEmpty()) {
            QFile file(state.filePath("assistant/chat.jsonl.provider"));
            if (file.open(QIODevice::WriteOnly))
                file.write(choice);
        }
        if (detected)
            launchers.found({"terminal", "claude", "codex"}, path());
        qputenv("ELIS_ASSISTANT_PROVIDER_CMD", standIn);
        lib = std::make_unique<WindowLibrary>(state.path());
        lib->launchers = &launchers;
        lib->load();
        runner = std::make_unique<AssistantRunner>(*lib, state.path());
        lib->assistantSink = runner.get();
    }
    ~AssistantHost()
    {
        lib->assistantSink = nullptr;
        runner.reset();
        qunsetenv("ELIS_ASSISTANT_PROVIDER_CMD");
    }
    QJsonObject ask(const QString &text) { return lib->dispatch({{"cmd", "assistant.ask"}, {"args", QJsonObject{{"text", text}}}}); }
    void choose(const QString &provider) { lib->dispatch({{"cmd", "assistant.provider"}, {"args", QJsonObject{{"provider", provider}}}}); }
    QStringList texts(const QString &kind)
    {
        QStringList out;
        const QJsonObject read = lib->dispatch({{"cmd", "assistant.read"}});
        for (const QJsonValue &e : read["result"]["assistant"]["entries"].toArray())
            if (e["kind"].toString() == kind)
                out << e["text"].toString();
        return out;
    }
    QJsonObject node()
    {
        const QJsonObject tree = lib->dispatch({{"cmd", "tree"}});
        return tree["result"]["tree"]["assistant"].toObject();
    }
    bool running() { return node()["running"].toBool(); }
};

class TestUi : public QObject
{
    Q_OBJECT

    QTemporaryDir dir;

private Q_SLOTS:

    void phoneCodeShowsTheChosenAddress()
    {
        const QString link = QStringLiteral("elis://pair?h=172.17.0.1&p=8765&t=tok-en_&f=ab12&n=my%20pc");
        const QString moved = pairLinkWithHost(link, QStringLiteral(" pc.tail1234.ts.net "), 8765);
        QCOMPARE(moved, QStringLiteral("elis://pair?h=pc.tail1234.ts.net&p=8765&t=tok-en_&f=ab12&n=my%20pc"));
        QCOMPARE(pairLinkWithHost(link, QString(), 8765), link); // no choice keeps what serve printed
        // a Bluetooth-only link gains the address and port, its other bytes as serve printed them
        QCOMPARE(pairLinkWithHost(QStringLiteral("elis://pair?t=a%2Bb&b=1"), QStringLiteral("pc"), 9000),
                 QStringLiteral("elis://pair?h=pc&p=9000&t=a%2Bb&b=1"));
        const QImage code = qrImage(link);
        QCOMPARE(code.width(), code.height());
        QVERIFY(code.width() >= 21 + 8);                       // the smallest QR plus a four-module quiet zone
        QCOMPARE(code.pixel(0, 0), qRgb(255, 255, 255));        // light border on any theme
        QCOMPARE(code.pixel(4, 4), qRgb(0, 0, 0));              // the top-left finder starts inside it
    }

    void connectAPhoneShowsTheRelaysLink()
    {
        if (qEnvironmentVariableIsEmpty("ELIS_STATE_DIR"))
            QSKIP("writes <state>/mobile: run it through ctest, which sets a throwaway ELIS_STATE_DIR");
        QTcpServer probe;
        QVERIFY(probe.listen(QHostAddress::LocalHost));
        const quint16 port = probe.serverPort();
        probe.close();
        PhoneRelay *relay = PhoneRelay::instance();
        relay->setPort(port);
        relay->setEnabled(true);
        auto off = qScopeGuard([relay] { relay->setEnabled(false); });
        QWidget window;
        showPhoneDialog(&window);
        auto *link = window.findChild<QLineEdit *>(QStringLiteral("phoneLink"));
        QVERIFY(link);
        QTRY_VERIFY_WITH_TIMEOUT(link->text().startsWith(QStringLiteral("elis://pair?")), 15000);
        QVERIFY(link->text().contains(QStringLiteral("&p=%1&").arg(port)));
        QVERIFY(!window.findChild<QLabel *>(QStringLiteral("phoneCode"))->pixmap().isNull());
        QVERIFY2(relay->error().isEmpty(), qPrintable(relay->error()));
        auto *bluetooth = window.findChild<QLabel *>(QStringLiteral("phoneBluetooth"));
        auto *settings = window.findChild<QPushButton *>(QStringLiteral("phoneBluetoothSettings"));
        QVERIFY(bluetooth && settings);
        QTRY_VERIFY_WITH_TIMEOUT(!relay->bluetooth().isEmpty(), 15000);
        QVERIFY2(bluetooth->text() == QStringLiteral("Advertising") || bluetooth->text().startsWith(QStringLiteral("Off: ")),
                 qPrintable(bluetooth->text()));
        QCOMPARE(!settings->isHidden(), relay->bluetooth() == QStringLiteral("off"));
        auto *dlg = window.findChild<QDialog *>(QStringLiteral("phoneDialog"));
        QVERIFY(dlg->height() >= dlg->sizeHint().height()); // the code was squeezed under the address row
        relay->setEnabled(false);
        QCOMPARE(bluetooth->text(), QStringLiteral("Off"));
        QVERIFY(settings->isHidden());
    }

    void phoneCommandsDriveTheRelay()
    {
        if (qEnvironmentVariableIsEmpty("ELIS_STATE_DIR"))
            QSKIP("writes <state>/mobile: run it through ctest, which sets a throwaway ELIS_STATE_DIR");
        auto call = [](const QString &cmd, const QJsonObject &args = {}) -> const QJsonObject {
            QJsonObject request{{"cmd", cmd}}, out;
            if (!args.isEmpty())
                request.insert("args", args);
            bool answered = false;
            phoneCommand(request, [&](const QJsonObject &r) { out = r, answered = true; });
            if (!QTest::qWaitFor([&] { return answered; }, PhoneRelay::startLimitMs + 5000))
                return QJsonObject{{"error", "no answer"}};
            return out;
        };
        PhoneRelay *relay = PhoneRelay::instance();
        auto off = qScopeGuard([relay] { relay->setEnabled(false); });
        QCOMPARE(call("phone.port", {{"port", 80}})["error"].toString(), QStringLiteral("port must be 1024...65535"));
        QCOMPARE(call("phone.enable", {{"mode", "maybe"}})["error"].toString(), QStringLiteral("phone.enable requires on|off|toggle"));
        QCOMPARE(call("phone.status", {{"window", "w"}})["error"].toString(), QStringLiteral("phone.status takes no target or --window"));
        QTcpServer probe;
        QVERIFY(probe.listen(QHostAddress::LocalHost));
        const quint16 port = probe.serverPort();
        probe.close();
        QJsonObject r = call("phone.port", {{"port", int(port)}});
        QCOMPARE(std::as_const(r)["result"]["phone"]["port"].toInt(), int(port));
        QVERIFY(!std::as_const(r)["result"]["phone"]["on"].toBool());
        r = call("phone.enable", {{"mode", "toggle"}}); // answers once serve listens and reported Bluetooth
        QVERIFY2(std::as_const(r)["ok"].toBool(), qPrintable(QJsonDocument(r).toJson()));
        QVERIFY2(std::as_const(r)["result"]["phone"]["listening"].toBool(), qPrintable(QJsonDocument(r).toJson()));
        QVERIFY(!std::as_const(r)["result"]["phone"]["bluetooth"].toString().isEmpty());
        QVERIFY(!std::as_const(r)["result"]["phone"].toObject().contains("link")); // the token stays out of every answer but status
        const QString link = call("phone.status")["result"]["phone"]["link"].toString();
        QVERIFY2(link.startsWith(QStringLiteral("elis://pair?")) && link.contains(QStringLiteral("&p=%1&").arg(port)), qPrintable(link));
        const QJsonObject tree = relay->readback();
        QVERIFY(tree["on"].toBool() && tree["listening"].toBool() && tree["port"].toInt() == port);
        QVERIFY(!tree.contains("link") && !tree.contains("hosts"));
        r = call("phone.host", {{"host", "pc.example"}});
        QCOMPARE(std::as_const(r)["result"]["phone"]["host"].toString(), QStringLiteral("pc.example"));
        QVERIFY(call("phone.status")["result"]["phone"]["link"].toString().contains(QStringLiteral("h=pc.example&")));
        QCOMPARE(call("phone.host", {{"auto", true}})["result"]["phone"]["host"].toString(), relay->hosts().value(0));
        r = call("phone.revoke");
        QVERIFY2(std::as_const(r)["result"]["phone"]["listening"].toBool(), qPrintable(QJsonDocument(r).toJson()));
        QCOMPARE(std::as_const(r)["result"]["phone"]["lastEvent"].toString(), QStringLiteral("paired phones revoked"));
        QVERIFY(call("phone.status")["result"]["phone"]["link"].toString() != link); // a new token
        r = call("phone.enable", {{"mode", "off"}});
        QVERIFY(!std::as_const(r)["result"]["phone"]["on"].toBool() && !std::as_const(r)["result"]["phone"]["listening"].toBool());
        QVERIFY(!std::as_const(r)["result"]["phone"].toObject().contains("bluetooth"));
    }

    void retiredPartNeverParsesWithoutItsView()
    {
        QWidget host;
        auto loaded = KParts::PartLoader::instantiatePart<KParts::ReadOnlyPart>(KPluginMetaData(QStringLiteral("kf6/parts/konsolepart")), &host, &host);
        QVERIFY2(loaded, qPrintable(loaded.errorString));
        QPointer<KParts::ReadOnlyPart> part = loaded.plugin;
        auto *t = qobject_cast<TerminalInterface *>(part);
        host.show();
        // the cell size query a demoted zmx client sends when a takeover attaches beside it
        t->startProgram(QStringLiteral("/bin/sh"), {QStringLiteral("sh"), QStringLiteral("-c"), QStringLiteral("sleep 0.2; printf '\\033[16t'; exec sleep 30")});
        QTRY_VERIFY(t->terminalProcessId() > 0);
        QEventLoop loop; // the app's own: the pass after the retirement deletes before it reads the pending query
        QTimer::singleShot(0, &loop, [&] {
            QThread::msleep(500);
            retirePart(part);
        });
        QTimer::singleShot(1500, &loop, &QEventLoop::quit);
        loop.exec();
        QVERIFY(!part);
    }

    void paneLeadCoverNamesPhoneWhenPhoneLeads()
    {
        auto reset = qScopeGuard([] { elis_free(elis_phone_viewers_reset()); });
        QWidget pane;
        PaneLeadCover cover(&pane, nullptr, QStringLiteral("phone-test-pane"), {}, {});
        auto *title = cover.findChild<QLabel *>(QStringLiteral("paneLeadTitle"));
        QVERIFY(title);
        Zmx::Lead lead;
        lead.covered = true;
        lead.role = QStringLiteral("follower");
        cover.apply(lead);
        QCOMPARE(title->text(), QStringLiteral("In use from another terminal"));
        elis_free(elis_phone_relay_line("phone leads from - pane phone-test-pane"));
        cover.apply(lead);
        QCOMPARE(title->text(), QStringLiteral("In use on your phone"));
        QCOMPARE(PaneLeadCover::title(QStringLiteral("follower"), true, true), QStringLiteral("Taking over…"));
    }

    void takeOverUncoversAPaneWhoseProgramSetATitle()
    {
        if (qEnvironmentVariableIsEmpty("ELIS_STATE_DIR"))
            QSKIP("runs zmx daemons in <state>: run it through ctest, which sets a throwaway ELIS_STATE_DIR");
        const QByteArray shell = qgetenv("SHELL");
        qputenv("SHELL", "/bin/sh");
        auto restoreShell = qScopeGuard([shell] { qputenv("SHELL", shell); });
        Store store;
        store.restoreModeAtLaunch = QStringLiteral("live");
        MainWindow w(store, dir.filePath("takeover.json"));
        w.restore({});
        // the title is in the screen a re-attach replays, right behind the client's role report
        const QString a = store.addSession(store.addWorkspace("w"), {}, {}, QStringLiteral("sleep 0.5; printf '\\033]2;agent\\033\\\\titled'; exec sleep 60"));
        store.select(a);
        w.show();
        const QString pane = store.session(a)->paneId;
        QVERIFY(!pane.isEmpty());
        auto killDaemon = qScopeGuard([pane] { Zmx::kill(stateDir(), {pane}); });
        QTRY_COMPARE_WITH_TIMEOUT(Zmx::lead(pane).role, QStringLiteral("leader"), 5000);
        QTRY_VERIFY_WITH_TIMEOUT(Zmx::screen(stateDir(), pane, false, 0).value_or(QString()).contains(QLatin1String("titled")), 5000);
        QTRY_COMPARE_WITH_TIMEOUT(store.session(a)->displayName(), QStringLiteral("agent"), 5000);

        const QString other = QUuid::createUuid().toString(QUuid::WithoutBraces);
        const QMap<QString, QString> set = Zmx::attach(stateDir(), other, QStringLiteral("/bin/sh"), {}, {}, false).set;
        Zmx::forget(other);
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        for (const QString &k : env.keys())
            if (k.startsWith(QLatin1String("ELIS_")) || k.startsWith(QLatin1String("ZMX_")))
                env.remove(k);
        env.insert(QStringLiteral("ZMX_DIR"), set.value(QStringLiteral("ZMX_DIR")));
        env.insert(QStringLiteral("ZMX_MANAGED"), QStringLiteral("phone"));
        env.insert(QStringLiteral("ZMX_MANAGED_CLAIM"), QStringLiteral("1"));
        const auto claim = [&env, pane](QProcess &phone) { // takes the lead, as the phone's Chat does
            phone.setProcessEnvironment(env);
            phone.start(QStringLiteral("script"), {QStringLiteral("-qfec"), Zmx::executable() + QStringLiteral(" attach ") + Zmx::daemonName(stateDir(), pane),
                                                   QStringLiteral("/dev/null")});
        };
        const auto stop = [](QProcess &phone) {
            phone.kill();
            phone.waitForFinished();
        };
        const auto shown = [&w] {
            const QList<PaneLeadCover *> covers = w.findChildren<PaneLeadCover *>();
            const auto it = std::find_if(covers.begin(), covers.end(), [](PaneLeadCover *c) { return c->isVisible(); });
            return it == covers.end() ? nullptr : *it;
        };
        const auto leads = [&] { return Zmx::lead(pane).role == QLatin1String("leader") && !Zmx::lead(pane).reattaching && !shown(); };

        QProcess first;
        auto stopFirst = qScopeGuard([&] { stop(first); });
        claim(first);
        QTRY_COMPARE_WITH_TIMEOUT(Zmx::lead(pane).role, QStringLiteral("follower"), 5000);
        QTRY_VERIFY(shown());
        QEventLoop loop; // the app's own: the report that retires the part arrives in a pass of it
        QTimer poll;
        connect(&poll, &QTimer::timeout, &loop, [&] {
            if (leads())
                loop.quit();
        });
        poll.start(50);
        QTimer::singleShot(0, &loop, [&] { stop(first); }); // the phone leaves: the pane leads again on its own
        QTimer::singleShot(5000, &loop, &QEventLoop::quit);
        loop.exec();
        QVERIFY(leads());

        QProcess second;
        auto stopSecond = qScopeGuard([&] { stop(second); });
        claim(second);
        QTRY_COMPARE_WITH_TIMEOUT(Zmx::lead(pane).role, QStringLiteral("follower"), 5000);
        QTRY_VERIFY(shown());
        QWidget *display = nullptr;
        for (QWidget *child : shown()->parentWidget()->findChildren<QWidget *>())
            if (child->inherits("Konsole::TerminalDisplay"))
                display = child;
        QVERIFY(display);
        QTest::keyClick(display, Qt::Key_A);
        QTRY_VERIFY_WITH_TIMEOUT(leads(), 5000);
    }

    void takeOverOfASessionNotShownKeepsItsPaneSizedAndShown()
    {
        if (qEnvironmentVariableIsEmpty("ELIS_STATE_DIR"))
            QSKIP("runs zmx daemons in <state>: run it through ctest, which sets a throwaway ELIS_STATE_DIR");
        const QByteArray shell = qgetenv("SHELL");
        qputenv("SHELL", "/bin/sh");
        auto restoreShell = qScopeGuard([shell] { qputenv("SHELL", shell); });
        Store store;
        store.restoreModeAtLaunch = QStringLiteral("live");
        MainWindow w(store, dir.filePath("takeover-hidden.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, {}, {}, QStringLiteral("exec sleep 60"));
        const QString b = store.addSession(ws, {}, {}, QStringLiteral("exec sleep 60"));
        store.select(b);
        w.show();
        const QString pane = store.session(a)->paneId;
        auto killDaemons = qScopeGuard([&store, pane, b] { Zmx::kill(stateDir(), {pane, store.session(b)->paneId}); });
        QTRY_COMPARE_WITH_TIMEOUT(Zmx::lead(pane).role, QStringLiteral("leader"), 5000);

        const QString other = QUuid::createUuid().toString(QUuid::WithoutBraces);
        const QMap<QString, QString> set = Zmx::attach(stateDir(), other, QStringLiteral("/bin/sh"), {}, {}, false).set;
        Zmx::forget(other);
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        for (const QString &k : env.keys())
            if (k.startsWith(QLatin1String("ELIS_")) || k.startsWith(QLatin1String("ZMX_")))
                env.remove(k);
        env.insert(QStringLiteral("ZMX_DIR"), set.value(QStringLiteral("ZMX_DIR")));
        env.insert(QStringLiteral("ZMX_MANAGED"), QStringLiteral("phone"));
        env.insert(QStringLiteral("ZMX_MANAGED_CLAIM"), QStringLiteral("1"));
        QProcess phone;
        phone.setProcessEnvironment(env);
        auto stopPhone = qScopeGuard([&phone] {
            phone.kill();
            phone.waitForFinished();
        });
        phone.start(QStringLiteral("script"), {QStringLiteral("-qfec"), Zmx::executable() + QStringLiteral(" attach ") + Zmx::daemonName(stateDir(), pane),
                                               QStringLiteral("/dev/null")});
        QTRY_COMPARE_WITH_TIMEOUT(Zmx::lead(pane).role, QStringLiteral("follower"), 5000);
        const auto paneShown = [&w, pane]() -> KParts::ReadOnlyPart * {
            for (auto *part : w.findChildren<KParts::ReadOnlyPart *>())
                if (part->property("elisPaneId").toString() == pane && part->widget() && !part->widget()->isHidden())
                    return part;
            return nullptr;
        };
        const auto retaken = [&] { return Zmx::lead(pane).role == QLatin1String("leader") && !Zmx::lead(pane).reattaching; };
        QEventLoop loop; // the app's own: the report that retires the part arrives in a pass of it
        QTimer poll;
        connect(&poll, &QTimer::timeout, &loop, [&] {
            if (retaken())
                loop.quit();
        });
        poll.start(50);
        QTimer::singleShot(0, &loop, [&] { phone.kill(); }); // the phone leaves: the pane takes the lead back on its own
        QTimer::singleShot(5000, &loop, &QEventLoop::quit);
        loop.exec();
        QVERIFY(retaken());

        KParts::ReadOnlyPart *fresh = paneShown();
        QVERIFY(fresh);
        const int pid = qobject_cast<TerminalInterface *>(fresh)->terminalProcessId();
        const int fd = ::open(qPrintable(QStringLiteral("/proc/%1/fd/0").arg(pid)), O_RDONLY | O_NOCTTY);
        QVERIFY(fd >= 0);
        winsize size{};
        ::ioctl(fd, TIOCGWINSZ, &size);
        ::close(fd);
        QVERIFY2(size.ws_row > 0 && size.ws_col > 0, "the attach client's pty has no size, so zmx lays the program out at its default");
        store.select(a);
        QTRY_VERIFY(fresh->widget()->isVisible());
    }

    void commandSessionNamesItselfWithoutBeingSelected()
    {
        if (qEnvironmentVariableIsEmpty("ELIS_STATE_DIR"))
            QSKIP("runs zmx daemons in <state>: run it through ctest, which sets a throwaway ELIS_STATE_DIR");
        const QByteArray shell = qgetenv("SHELL");
        qputenv("SHELL", "/bin/sh");
        auto restoreShell = qScopeGuard([shell] { qputenv("SHELL", shell); });
        const QString wsDir = dir.filePath("my-workspace");
        QVERIFY(QDir().mkpath(wsDir));
        Store store;
        store.restoreModeAtLaunch = QStringLiteral("live");
        const QString ws = store.addWorkspace("my-workspace", false, wsDir);
        const QString first = store.addSession(ws, {}, wsDir);
        store.select(first);
        MainWindow w(store, dir.filePath("phone-new.json"));
        w.restore({});
        w.show();
        const QString firstPane = store.session(first)->paneId;
        auto killFirst = qScopeGuard([firstPane] {
            if (!firstPane.isEmpty())
                Zmx::kill(stateDir(), {firstPane});
        });

        // a phone-created agent session runs via `session.new --command --no-select` and the phone takes the lead
        const QString go = dir.filePath("phone-go");
        const QString created = store.addSession(ws, {}, wsDir,
            QStringLiteral("sleep 0.5; printf '\\033]0;✳ Initial title\\007'; while [ ! -f '%1' ]; do sleep 0.05; done; printf '\\033]0;✳ Real session name\\007'; exec sleep 30")
                .arg(go));
        const QString createdPane = store.session(created)->paneId;
        auto killCreated = qScopeGuard([createdPane] {
            if (!createdPane.isEmpty())
                Zmx::kill(stateDir(), {createdPane});
        });
        QCOMPARE(store.selected, first);
        QTRY_COMPARE_WITH_TIMEOUT(store.session(created)->displayName(), QStringLiteral("Initial title"), 5000);

        // phone claims lead while the session stays unselected; a later title update (even with command cleared, as after restart) still reaches the tree
        const QString other = QUuid::createUuid().toString(QUuid::WithoutBraces);
        const QMap<QString, QString> set = Zmx::attach(stateDir(), other, QStringLiteral("/bin/sh"), {}, {}, false).set;
        Zmx::forget(other);
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        for (const QString &k : env.keys())
            if (k.startsWith(QLatin1String("ELIS_")) || k.startsWith(QLatin1String("ZMX_")))
                env.remove(k);
        env.insert(QStringLiteral("ZMX_DIR"), set.value(QStringLiteral("ZMX_DIR")));
        env.insert(QStringLiteral("ZMX_MANAGED"), QStringLiteral("phone"));
        env.insert(QStringLiteral("ZMX_MANAGED_CLAIM"), QStringLiteral("1"));
        QProcess phone;
        phone.setProcessEnvironment(env);
        auto stopPhone = qScopeGuard([&] {
            phone.kill();
            phone.waitForFinished();
        });
        phone.start(QStringLiteral("script"), {QStringLiteral("-qfec"), Zmx::executable() + QStringLiteral(" attach ") + Zmx::daemonName(stateDir(), createdPane),
                                               QStringLiteral("/dev/null")});
        QTRY_COMPARE_WITH_TIMEOUT(Zmx::lead(createdPane).role, QStringLiteral("follower"), 5000);
        store.session(created)->command.clear();
        QFile f(go);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.close();
        QTRY_COMPARE_WITH_TIMEOUT(store.session(created)->displayName(), QStringLiteral("Real session name"), 5000);
    }

    void smoothWheelReplaysNotchesLineByLine()
    {
        QCOMPARE(SmoothWheel::factor(500), 1.5);
        QCOMPARE(SmoothWheel::factor(10), 6.0);
        QCOMPARE(SmoothWheel::chunk(60, 40), 40);
        QCOMPARE(SmoothWheel::chunk(-1000, 40), -320);
        QCOMPARE(SmoothWheel::chunk(240, 120), 120);

        Konsole::TerminalDisplay display;
        display.setCursor(Qt::IBeamCursor); // Konsole's cursor when the program does not track the mouse
        QWidget other;
        SmoothWheel filter;
        qApp->installEventFilter(&filter);
        auto wheel = [](QWidget *to, int dy, Qt::KeyboardModifiers mods = Qt::NoModifier) {
            QWheelEvent e(QPointF(5, 5), QPointF(5, 5), {}, QPoint(0, dy), Qt::NoButton, mods, Qt::NoScrollPhase, false);
            return QApplication::sendEvent(to, &e) && e.isAccepted();
        };
        wheel(&display, 120); // one slow notch: 1.5x in whole lines, one now and the rest over the next frames
        QCOMPARE(display.deltas, QList<int>{40});
        QTRY_COMPARE(std::accumulate(display.deltas.begin(), display.deltas.end(), 0), 160);
        QVERIFY(display.deltas.size() > 2);

        display.deltas.clear();
        display.setCursor(Qt::ArrowCursor); // the program tracks the mouse: whole notches, the first one at once
        QTest::qWait(500);
        wheel(&display, 120);
        QCOMPARE(display.deltas, QList<int>{120});

        display.deltas.clear();
        wheel(&display, 120, Qt::ControlModifier); // zoom passes through as it came
        QCOMPARE(display.deltas, QList<int>{120});

        display.deltas.clear();
        for (int i = 0; i < 6; ++i)
            wheel(&display, -120); // a fast spin accelerates past 1.5 per notch
        QTRY_VERIFY(std::accumulate(display.deltas.begin(), display.deltas.end(), 0) < -6 * 180);
        qApp->removeEventFilter(&filter);
    }

    void linkClicksOpenOnce()
    {
        const auto ctrl = Qt::ControlModifier, shift = Qt::ShiftModifier, none = Qt::NoModifier;
        // at a prompt a plain click opens the link on release; the press stays plain so selection is unchanged
        QCOMPARE(linkClickModifiers(none, false, true), ctrl);
        QCOMPARE(linkClickModifiers(none, false, false), none);
        QCOMPARE(linkClickModifiers(ctrl, false, true), ctrl);
        QCOMPARE(linkClickModifiers(shift, false, true), shift);
        // a program tracking the mouse never sees a Ctrl+click, so only Konsole opens the link; other clicks stay its own
        QCOMPARE(linkClickModifiers(ctrl, true, false), ctrl | shift);
        QCOMPARE(linkClickModifiers(ctrl, true, true), ctrl | shift);
        QCOMPARE(linkClickModifiers(none, true, true), none);
        QCOMPARE(linkClickModifiers(ctrl | Qt::AltModifier, true, true), ctrl | Qt::AltModifier);
    }

    // the config dir follows ELIS_STATE_DIR (set by ctest), so nothing here touches ~/.config
    static QString writeConfig(const QString &name, const QString &text)
    {
        const QString dir = qEnvironmentVariable("ELIS_STATE_DIR") + QStringLiteral("/config");
        QDir().mkpath(dir);
        QFile f(dir + QLatin1Char('/') + name);
        if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate))
            return {};
        f.write(text.toUtf8());
        return f.fileName();
    }

    static QWidget *display(MainWindow &)
    {
        const bool ok = QTest::qWaitFor([] { return QApplication::focusWidget() && QApplication::focusWidget()->inherits("Konsole::TerminalDisplay"); }, 5000);
        return ok ? QApplication::focusWidget() : nullptr;
    }

    void keymapRebindsAndLeaderSequencesFireFromTheTerminal()
    {
        QTemporaryDir out;
        const QString touched = out.filePath("touched");
        writeConfig("keymap.conf", QStringLiteral("map ctrl+alt+l toggle_split\n"
                                                  "command \"Touch\" ctrl+a>g touch \"%1\" && echo \"{AGT_SESSION_ID}\" > \"%1\"\n"
                                                  "map bogus toggle_split\n")
                                       .arg(touched));
        Store store;
        MainWindow w(store, dir.filePath("keymap.json"));
        w.restore({});
        w.loadConfig();
        const QString id = store.addSession(store.addWorkspace("w"), {}, {});
        store.select(id);
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QWidget *term = display(w);
        QCOMPARE(w.keymap().diagnostics.size(), 1);
        QCOMPARE(w.namedAction("toggle_split")->shortcut(), QKeySequence("Ctrl+Alt+L"));

        QTest::keyClick(term, Qt::Key_L, Qt::ControlModifier | Qt::AltModifier);
        QTRY_VERIFY(store.session(id)->hasSplit);
        QTest::keyClick(term, Qt::Key_D, Qt::ControlModifier | Qt::ShiftModifier); // its old chord is free now
        QVERIFY(store.session(id)->splitVisible);

        QTRY_VERIFY_WITH_TIMEOUT(QApplication::focusWidget() && QApplication::focusWidget()->inherits("Konsole::TerminalDisplay"), 5000);
        term = QApplication::focusWidget();
        QTest::keyClick(term, Qt::Key_A, Qt::ControlModifier);
        QTest::keyClick(term, Qt::Key_G);
        QTRY_VERIFY_WITH_TIMEOUT(QFile::exists(touched) && QFile(touched).size() > 0, 5000);
        QFile f(touched);
        QVERIFY(f.open(QIODevice::ReadOnly));
        QCOMPARE(f.readAll().trimmed(), id.toUtf8()); // {AGT_SESSION_ID} expanded

        QString error;
        QJsonObject result;
        QVERIFY(!w.appCommand("keymap.run", id, {{"name", "nope"}}, &result, &error));
        QVERIFY(w.appCommand("keymap.list", {}, {}, &result, &error));
        QVERIFY(QJsonDocument(result).toJson().contains("\"marked\": true"));
    }

    void themePickerPreviewsRevertsAndCommits()
    {
        Store store;
        MainWindow w(store, dir.filePath("theme.json"));
        w.restore({});
        store.select(store.addSession(store.addWorkspace("w"), {}, {}));
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QWidget *term = display(w);
        QVERIFY(w.themes().contains("DarkPastels"));
        const QColor before = term->palette().color(QPalette::Window);
        w.previewTheme("DarkPastels");
        QTRY_VERIFY(term->palette().color(QPalette::Window) != before);
        w.previewTheme({});
        QTRY_COMPARE(term->palette().color(QPalette::Window), before);

        w.selectTheme();
        auto *search = qobject_cast<QLineEdit *>(QApplication::focusWidget());
        QVERIFY(search);
        QTest::keyClicks(search, "DarkPastels");
        QTRY_VERIFY(term->palette().color(QPalette::Window) != before); // the filtered row is previewed
        QTest::keyClick(search, Qt::Key_Escape);
        QTRY_COMPARE(term->palette().color(QPalette::Window), before);
        QVERIFY(store.settings.theme.isEmpty());

        w.selectTheme();
        search = qobject_cast<QLineEdit *>(QApplication::focusWidget());
        QTest::keyClicks(search, "DarkPastels");
        QTest::keyClick(search, Qt::Key_Return);
        QCOMPARE(store.settings.theme, QStringLiteral("DarkPastels"));
        QString error;
        QJsonObject result;
        QVERIFY(!w.appCommand("theme.set", {}, {{"name", "NoSuchScheme"}}, &result, &error));
        QVERIFY(w.appCommand("theme.set", {}, {}, &result, &error));
        QTRY_COMPARE(term->palette().color(QPalette::Window), before); // back to the profile's scheme
    }

    void windowTransparencyReachesTheTerminalAndSurvivesAThemeChange()
    {
        Store store;
        MainWindow w(store, dir.filePath("glass.json"));
        w.restore({});
        store.select(store.addSession(store.addWorkspace("w"), {}, {}));
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QWidget *term = display(w);
        QVERIFY(term);
        QVERIFY(w.testAttribute(Qt::WA_TranslucentBackground));
        QCOMPARE(KonsolePrivate::terminalOpacity(term), 1.0);
        Settings s = store.settings;
        s.windowTransparency = 40;
        store.setSettings(s);
        QTRY_COMPARE(KonsolePrivate::terminalOpacity(term), 0.6);
        const QColor scheme = term->palette().color(QPalette::Window);
        s.theme = "DarkPastels"; // a scheme change resets Konsole's opacity to the scheme's own
        store.setSettings(s);
        QTRY_VERIFY(term->palette().color(QPalette::Window) != scheme);
        QTest::qWait(50);
        QCOMPARE(KonsolePrivate::terminalOpacity(term), 0.6);
        // Konsole's own profile dialogs re-apply a scheme without asking the window: the new colours reach the view
        KonsolePrivate::setTerminalOpacity(term, 1.0);
        QEvent recolored(QEvent::PaletteChange);
        QApplication::sendEvent(term, &recolored);
        QCOMPARE(KonsolePrivate::terminalOpacity(term), 0.6);
        s.windowTransparency = 0;
        store.setSettings(s);
        QTRY_COMPARE(KonsolePrivate::terminalOpacity(term), 1.0);
    }

    void oscNotificationsRaiseTheBadge()
    {
        Store store;
        MainWindow w(store, dir.filePath("osc.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString front = store.addSession(ws, {}, {}), back = store.addSession(ws, {}, {});
        store.settings.notificationsEnabled = false; // the badge is under test, not the desktop banner
        store.select(front);
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        display(w);
        QSignalSpy notified(&store, &Store::notified);
        QString error;
        QTest::qWait(500); // the shell is up
        w.type(back, QStringLiteral("left"), QStringLiteral("printf '\\033]9;nine\\007'; printf '\\033]777;notify;Title;Body\\007'\n"), &error);
        QTRY_COMPARE_WITH_TIMEOUT(notified.size(), 2, 5000);
        QStringList got;
        for (const auto &n : notified)
            got << n[1].toString() + "|" + n[2].toString();
        got.sort();
        QCOMPARE(got, (QStringList{"Title|Body", "|nine"}));
        QCOMPARE(store.session(back)->unseen, 2);
    }

    void settingsDialogAppliesLive()
    {
        Store store;
        MainWindow w(store, dir.filePath("settings.json"));
        w.restore({});
        store.select(store.addSession(store.addWorkspace("w"), {}, {}));
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QWidget *term = display(w);
        QAction *split = nullptr;
        for (QAction *a : w.findChild<QToolBar *>("titleStrip")->actions())
            if (a->text() == QStringLiteral("Split"))
                split = a;
        QVERIFY(split && split->isVisible());
        w.showSettings();
        auto *dlg = w.findChild<KPageDialog *>("settingsDialog");
        QVERIFY(dlg);
        QCheckBox *box = nullptr;
        for (QWidget *x : QApplication::allWidgets()) // KPageView parents a page only once it is shown
            if (auto *b = qobject_cast<QCheckBox *>(x); b && b->text().remove('&') == QStringLiteral("Split view")) // KDE adds accelerators
                box = b;
        QVERIFY(box);
        QVERIFY(box->isChecked());
        box->setChecked(false);
        QVERIFY(!store.settings.shows("split"));
        QVERIFY(!split->isVisible());
        const double size = term->font().pointSizeF();
        Settings s = store.settings;
        s.fontSize = size + 4;
        store.setSettings(s);
        QTRY_COMPARE(term->font().pointSizeF(), size + 4);
        QString error;
        QVERIFY(w.font(store.selected, "main", "reset", &error)); // reset returns to the Settings size, not the profile's
        QCOMPARE(term->font().pointSizeF(), size + 4);
        dlg->close();
    }
    void shortcutsReachTheAppFromTheTerminalAndTypingClearsAttention()
    {
        Store store;
        MainWindow w(store, dir.filePath("state.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        store.select(store.addSession(ws, {}, {}));
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QTRY_VERIFY_WITH_TIMEOUT(QApplication::focusWidget() && QApplication::focusWidget() != &w, 5000);
        QWidget *term = QApplication::focusWidget();

        QTest::keyClick(term, Qt::Key_N, Qt::ControlModifier | Qt::ShiftModifier);
        QTRY_COMPARE(store.allSessions().size(), 2);

        const QString first = store.workspaces.first().sessions.first().id;
        store.setStatus(first, "blocked");
        QTest::keyClick(term, Qt::Key_Up, Qt::ControlModifier | Qt::AltModifier | Qt::ShiftModifier);
        QTRY_COMPARE(store.selected, first);
        QCOMPARE(store.session(first)->status, QStringLiteral("blocked")); // a shortcut is not engagement

        QTRY_COMPARE(QApplication::focusWidget(), term); // focus follows the selection back to its terminal
        QTest::keyClick(term, Qt::Key_A);
        QCOMPARE(store.session(first)->status, QStringLiteral("idle"));
    }

    void undoCloseBringsBackTheSameTerminal()
    {
        Store store;
        MainWindow w(store, dir.filePath("undo.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, {}, {});
        store.select(a);
        store.select(store.addSession(ws, {}, {}));
        const QString closing = store.selected;
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QTRY_VERIFY_WITH_TIMEOUT(QApplication::focusWidget() && QApplication::focusWidget() != &w, 5000);
        QPointer<QWidget> term = QApplication::focusWidget();
        QTest::keyClick(term, Qt::Key_W, Qt::ControlModifier | Qt::ShiftModifier);
        QTRY_COMPARE(store.selected, a);
        QVERIFY(!store.session(closing));
        QTRY_VERIFY(QApplication::focusWidget() && QApplication::focusWidget() != term);
        QTest::keyClick(QApplication::focusWidget(), Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
        QTRY_COMPARE(store.selected, closing);
        QVERIFY(term); // the shell survived the grace window
        QTRY_COMPARE(QApplication::focusWidget(), term.data());
    }

    void overlayRunsOverTheSessionAndReportsItsExitStatus()
    {
        Store store;
        MainWindow w(store, dir.filePath("overlay.json"));
        w.restore({});
        const QString id = store.addSession(store.addWorkspace("w"), {}, {});
        store.select(id);
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QWidget *term = display(w);
        QVERIFY(term);
        auto run = [&](const QString &cmd, const QJsonObject &args = {}) {
            QJsonObject result;
            QString error;
            const bool ok = w.appCommand(cmd, id, args, &result, &error);
            return ok ? result : QJsonObject{{"error", error}};
        };
        QVERIFY(!run("session.overlay.open", {{"command", "printf 'OV_COPY_TOKEN\\n'; sleep 30; exit 3"}, {"sizePercent", 50}}).contains("error"));
        QCOMPARE(run("session.overlay.open", {{"command", "true"}})["error"].toString(), QStringLiteral("overlay already open"));
        QTRY_VERIFY(QApplication::focusWidget() && QApplication::focusWidget() != term); // the cover owns the keyboard
        QCOMPARE(w.sessionExtras(id)["overlaySizePercent"].toInt(), 50);
        QCOMPARE(run("session.overlay.result")["error"].toString(), QStringLiteral("overlay still running"));
        QCOMPARE(run("session.overlay.copy")["error"].toString(), QStringLiteral("no selection"));
        QTRY_VERIFY_WITH_TIMEOUT(run("session.overlay.text")["text"].toString().contains("OV_COPY_TOKEN"), 5000);
        for (KActionCollection *col : KActionCollection::allCollections())
            if (QAction *a = col->action(QStringLiteral("select-all")))
                a->trigger();
        QTRY_VERIFY2(run("session.overlay.copy")["text"].toString().contains("OV_COPY_TOKEN"),
                     qPrintable(QJsonDocument(run("session.overlay.copy")).toJson()));
        QCOMPARE(run("session.overlay.toggle")["text"].toString(), QStringLiteral("hidden"));
        QCOMPARE(w.sessionExtras(id)["hiddenOverlays"].toArray().first().toString(), QStringLiteral("session"));
        QTRY_COMPARE(QApplication::focusWidget(), term);
        QCOMPARE(w.namedAction("toggle_overlay")->text(), QStringLiteral("Show Overlays"));
        QVERIFY(!run("session.overlay.close").contains("error"));
        QVERIFY(!w.sessionExtras(id)["overlay"].toBool());
        QCOMPARE(run("session.overlay.copy")["error"].toString(), QStringLiteral("no overlay"));

        QVERIFY(!run("session.overlay.open", {{"command", "exit 3"}}).contains("error"));
        QTRY_VERIFY_WITH_TIMEOUT(!w.sessionExtras(id)["overlay"].toBool(), 5000);
        QCOMPARE(run("session.overlay.result")["exitCode"].toInt(), 3);
        QTRY_COMPARE(QApplication::focusWidget(), term);

        // the HUD takes no input: typing still reaches the terminal under it
        QVERIFY(!run("session.hud.open", {{"message", "building"}, {"spinner", "dot"}, {"hideAfter", 1}}).contains("error"));
        QCOMPARE(w.sessionExtras(id)["hud"].toObject()["message"].toString(), QStringLiteral("building"));
        QCOMPARE(run("session.overlay.copy")["error"].toString(), QStringLiteral("no overlay to read: the slot holds a hud"));
        QCOMPARE(QApplication::focusWidget(), term);
        QTRY_VERIFY_WITH_TIMEOUT(!w.sessionExtras(id).contains("hud"), 3000); // --hide-after clears it
        QCOMPARE(run("session.hud.close")["error"].toString(), QStringLiteral("no hud"));

        qputenv("VISUAL", "sleep 1; true"); // Edit Keymap runs the editor in a 95% overlay and closes with it
        w.namedAction("edit_keymap")->trigger();
        QCOMPARE(w.sessionExtras(id)["overlaySizePercent"].toInt(), 95);
        QTRY_VERIFY_WITH_TIMEOUT(!w.sessionExtras(id)["overlay"].toBool(), 5000);
        qunsetenv("VISUAL");
    }

    void restoreTerminalSizeTakesBackAPhoneGrid()
    {
        Store store;
        MainWindow w(store, dir.filePath("grid.json"));
        w.restore({});
        const QString a = store.addSession(store.addWorkspace("w"), {}, {});
        store.select(a);
        w.show();
        QTRY_VERIFY_WITH_TIMEOUT(w.gridSize(a, "left").isValid(), 5000);
        const QSize own = w.gridSize(a, "left");
        QMenu *menu = nullptr;
        for (QAction *m : w.menuBar()->actions())
            if (m->text() == QLatin1String("&Session"))
                menu = m->menu();
        QAction *restore = w.namedAction("restore_terminal_size");
        Q_EMIT menu->aboutToShow();
        QVERIFY(!restore->isEnabled()); // not on a phone's grid

        QString error;
        QVERIFY(w.setGrid(a, "left", QSize(40, 60), &error));
        QCOMPARE(w.gridSize(a, "left"), QSize(40, 60));
        Q_EMIT menu->aboutToShow();
        QVERIFY(restore->isEnabled());
        restore->trigger();
        QCOMPARE(w.gridSize(a, "left"), own); // the window's own size again
        Q_EMIT menu->aboutToShow();
        QVERIFY(!restore->isEnabled());

        QVERIFY(w.setGrid(a, "left", QSize(40, 60), &error));
        w.resize(w.size() + QSize(80, 40)); // the window takes the grid back on its own: nothing left to restore
        QTRY_VERIFY(w.gridSize(a, "left") != QSize(40, 60));
        Q_EMIT menu->aboutToShow();
        QVERIFY(!restore->isEnabled());
    }

    void dashboardHostsTheLivePanesAndGivesThemBack()
    {
        Store store;
        MainWindow w(store, dir.filePath("dash.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, {}, {});
        const QString b = store.addSession(ws, {}, {});
        store.select(a);
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QWidget *termA = display(w);
        QVERIFY(termA);
        QJsonObject result;
        QString error;
        QVERIFY(w.filePanel(QStringLiteral("show"), 0, &error));
        QVERIFY2(w.appCommand("dashboard", {}, {{"cells", QJsonArray{a + ":left", b + ":left"}}, {"fontMode", "untouched"}}, &result, &error), qPrintable(error));
        QCOMPARE(w.chromeState()["dashboardMembers"].toArray().size(), 2);
        QVERIFY(!w.chromeState()["sidebarVisible"].toBool()); // the grid takes the whole window
        QVERIFY(!w.chromeState()["filePanelVisible"].toBool());
        QWidget *grid = QApplication::focusWidget();
        QVERIFY(grid && grid->isAncestorOf(termA)); // the live terminal, not a copy
        QCOMPARE(w.windowTitle(), QStringLiteral("Dashboard"));
        QTest::keyClick(grid, Qt::Key_Right);
        QCOMPARE(w.chromeState()["dashboardHighlighted"].toString(), b + ":left");
        QTest::keyClick(grid, Qt::Key_Right); // no wrap
        QCOMPARE(w.chromeState()["dashboardHighlighted"].toString(), b + ":left");
        QTest::keyClick(grid, Qt::Key_X); // typing goes nowhere
        QTest::keyClick(grid, Qt::Key_Return);
        QCOMPARE(store.selected, b);
        QVERIFY(!w.chromeState().contains("dashboardMembers"));
        QVERIFY(w.chromeState()["sidebarVisible"].toBool()); // both panels come back
        QVERIFY(w.chromeState()["filePanelVisible"].toBool());
        for (QWidget *up = termA; up; up = up->parentWidget())
            QVERIFY(up->objectName() != QLatin1String("dashCell")); // back in its own splitter

        w.namedAction("dashboard")->trigger(); // the MRU grid with auto-size
        QCOMPARE(w.chromeState()["dashboardFontMode"].toString(), QStringLiteral("auto"));
        store.removeSession(a); // a member that goes away leaves the grid to the survivors
        QTRY_COMPARE(w.chromeState()["dashboardMembers"].toArray(), (QJsonArray{b + ":left"}));
        QTest::keyClick(QApplication::focusWidget(), Qt::Key_Escape);
        QVERIFY(!w.chromeState().contains("dashboardMembers"));
    }

    void dashboardClickGivesEveryPaneItsFontBack()
    {
        Store store;
        MainWindow w(store, dir.filePath("dashfont.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, {}, {});
        const QString b = store.addSession(ws, {}, {});
        store.select(b);
        store.select(a);
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QWidget *termA = display(w);
        QVERIFY(termA);
        store.select(b);
        QWidget *termB = display(w);
        QVERIFY(termB && termB != termA);
        const double fontA = termA->font().pointSizeF(), fontB = termB->font().pointSizeF();
        for (auto [d, dy] : {std::pair{termA, -130}, std::pair{termB, 130}}) { // scrolling leaves partial notches in Konsole's wheel accumulator
            QWheelEvent wheel(QPointF(4, 4), d->mapToGlobal(QPointF(4, 4)), {}, QPoint(0, dy), Qt::NoButton, {}, Qt::ScrollUpdate, false);
            QApplication::sendEvent(d, &wheel);
        }
        QTest::qWait(1100); // Konsole ignores Ctrl+wheel for a second after a scroll
        w.namedAction("dashboard")->trigger();
        QCOMPARE(w.chromeState()["dashboardMembers"].toArray().size(), 2);
        QVERIFY(termA->font().pointSizeF() < fontA);
        QVERIFY(termB->font().pointSizeF() < fontB);
        QVERIFY(w.save());
        QCOMPARE(store.session(a)->fontSize, 0.0);
        QTest::mouseClick(termA, Qt::LeftButton, {}, QPoint(20, 20));
        QTRY_VERIFY(!w.chromeState().contains("dashboardMembers"));
        QCOMPARE(store.selected, a);
        QCOMPARE(termA->font().pointSizeF(), fontA);
        QCOMPARE(termB->font().pointSizeF(), fontB);
    }

    void dashboardClickOnTheShownFinishedSessionClearsItsStatus()
    {
        Store store;
        MainWindow w(store, dir.filePath("dashvisit.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, {}, {});
        store.select(a);
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QWidget *termA = display(w);
        QVERIFY(termA);
        store.setStatus(a, "completed", true);
        w.namedAction("dashboard")->trigger();
        QVERIFY(w.chromeState().contains("dashboardMembers"));
        QTest::mouseClick(termA, Qt::LeftButton, {}, QPoint(20, 20));
        QTRY_VERIFY(!w.chromeState().contains("dashboardMembers"));
        QCOMPARE(store.session(a)->status, QStringLiteral("idle"));
    }

    void windowLibraryMigratesAndEachWindowKeepsItsOwnShortcuts()
    {
        QTemporaryDir state;
        {
            Store old;
            old.select(old.addSession(old.addWorkspace("legacy"), "kept", {}));
            QFile f(state.filePath("workspaces.json"));
            QVERIFY(f.open(QIODevice::WriteOnly));
            f.write(QJsonDocument(old.toJson()).toJson());
        }
        WindowLibrary lib(state.path());
        lib.load();
        QCOMPARE(lib.entries().size(), 1);
        QCOMPARE(lib.entries()[0].store->workspaces.first().name, QStringLiteral("legacy")); // the old file became window 1
        QVERIFY(!QFile::exists(state.filePath("workspaces.json")));
        const QString second = lib.newWindow("second");
        MainWindow *w2 = lib.entries()[1].window;
        Store *s2 = lib.entries()[1].store;
        w2->activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(w2));
        QWidget *term = display(*w2);
        QVERIFY(term && w2->isAncestorOf(term));
        // a chord both windows bind fires in the focused one: application-wide copies would be ambiguous and fire neither
        QTest::keyClick(term, Qt::Key_F, Qt::ControlModifier | Qt::AltModifier | Qt::ShiftModifier);
        QTRY_VERIFY(s2->session(s2->selected)->flagged);
        QVERIFY(!lib.entries()[0].store->allSessions().first()->flagged);
        const QString kept = s2->selected;
        lib.close(second);
        QTRY_VERIFY(!lib.entries()[1].open);
        QCOMPARE(lib.openWindows().size(), 1);
        QVERIFY(lib.select(second));
        QVERIFY(lib.entries()[1].store->session(kept)); // reopened from its own file
        QString error;
        QVERIFY(lib.remove(second, &error));
        QVERIFY(!lib.remove(lib.entries()[0].id, &error));
        QCOMPARE(error, QStringLiteral("cannot delete last window"));
    }

    void keepAwakeFollowsActiveAgentsInEveryOpenWindow()
    {
        QTemporaryDir state;
        WindowLibrary lib(state.path());
        QList<bool> calls;
        lib.keepAwake = [&calls](bool on) { calls << on; };
        lib.load();
        Store *s1 = lib.entries()[0].store;
        const QString a = s1->allSessions().first()->id;
        s1->setStatus(a, "active");
        s1->setStatus(a, "blocked");
        QCOMPARE(calls, (QList<bool>{true, false}));
        s1->setStatus(a, "active");
        Settings off = s1->settings;
        off.preventSleepWhileActive = false;
        s1->setSettings(off);
        off.preventSleepWhileActive = true;
        s1->setSettings(off);
        s1->removeSession(a);
        QCOMPARE(calls, (QList<bool>{true, false, true, false, true, false}));
        const QString second = lib.newWindow("second");
        Store *s2 = lib.entries()[1].store;
        s2->setStatus(s2->allSessions().first()->id, "active");
        lib.close(second);
        QTRY_COMPARE(calls, (QList<bool>{true, false, true, false, true, false, true, false}));
    }

    void assistantCommandsReachEveryWindowAndStampTheTree()
    {
        QTemporaryDir state;
        WindowLibrary lib(state.path());
        lib.load();
        lib.newWindow("second");
        MainWindow *w2 = lib.entries()[1].window;
        Store *s2 = lib.entries()[1].store;
        w2->activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(w2));
        const QString target = s2->allSessions().first()->id;
        s2->setAgent(target, QStringLiteral("claude"));
        const QJsonObject tree = lib.dispatch({{"cmd", "tree"}}).value("result")["tree"].toObject();
        QVERIFY(tree["assistant"].toObject().contains("providers"));
        QCOMPARE(tree["workspaces"][0]["sessions"][0]["id"].toString(), target);
        QVERIFY(!tree["workspaces"][0]["sessions"][0]["handle"].toString().isEmpty());
        const QJsonObject r = lib.dispatch({{"cmd", "assistant.send"}, {"args", QJsonObject{{"text", "hi there"}, {"recipients", QJsonArray{"@all"}}}}});
        QCOMPARE(r["result"]["assistant"]["deliveredIDs"].toArray(), QJsonArray{target});
    }

    void elisRowIsFirstInEveryMode()
    {
        Store store;
        const QString a = store.addWorkspace("alpha"), b = store.addWorkspace("beta");
        const QString a1 = store.addSession(a, "a1", {});
        store.addSession(b, "b1", {});
        Sidebar tree(store);
        auto first = [&] { return tree.topLevelItem(0)->data(0, SidebarRole::Kind).toInt(); };
        tree.rebuild();
        QCOMPARE(first(), int(SidebarRole::AssistantRow));
        QVERIFY(!(tree.topLevelItem(0)->flags() & (Qt::ItemIsEditable | Qt::ItemIsDragEnabled | Qt::ItemIsDropEnabled)));
        store.focusWorkspace(b, "add");
        store.setFilter(true);
        tree.rebuild();
        QCOMPARE(tree.topLevelItemCount(), 2);
        QCOMPARE(first(), int(SidebarRole::AssistantRow));
        store.setFilter(false);
        tree.setFlaggedView(true);
        QCOMPARE(tree.topLevelItemCount(), 1); // nothing flagged: only Elis
        store.setFlag(a1, true);
        tree.rebuild();
        QCOMPARE(first(), int(SidebarRole::AssistantRow));
        QCOMPARE(tree.topLevelItem(1)->data(0, SidebarRole::Id).toString(), a1);
        Settings s = store.settings;
        s.flaggedViewLayout = "tree";
        store.setSettings(s);
        tree.rebuild();
        QCOMPARE(first(), int(SidebarRole::AssistantRow));
        QCOMPARE(tree.topLevelItem(1)->data(0, SidebarRole::Id).toString(), a);
    }

    void selectingElisShowsTheChatAndKeysReachTheComposer()
    {
        Store store;
        MainWindow w(store, dir.filePath("elis-select.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, "a", {});
        store.select(a);
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        auto *tree = w.findChild<Sidebar *>();
        auto *view = w.findChild<AssistantView *>();
        auto *stack = w.findChild<QStackedWidget *>();
        QTest::mouseClick(tree->viewport(), Qt::LeftButton, {}, tree->visualItemRect(tree->topLevelItem(0)).center());
        QVERIFY(w.assistantShown());
        QCOMPARE(stack->currentWidget(), view);
        QVERIFY(store.selected.isEmpty()); // no session behind the chat for a shortcut to reach
        QVERIFY(tree->topLevelItem(0)->isSelected());
        QVERIFY(w.chromeState()["assistantShown"].toBool());
        auto *composer = view->findChild<QPlainTextEdit *>("assistantComposer");
        QTRY_COMPARE(QApplication::focusWidget(), composer);
        QTest::keyClicks(QApplication::focusWidget(), "hello");
        QCOMPARE(composer->toPlainText(), QStringLiteral("hello"));
        w.namedAction("close_session")->trigger();
        QVERIFY(store.session(a));
        store.select(a); // the session it left: a pick leaves the chat
        QVERIFY(!w.assistantShown());
        QVERIFY(stack->currentWidget() != view);
        QVERIFY(!w.chromeState().contains("assistantShown"));
    }

    void aReplyRaisesTheUnreadBadgeAndShowClearsIt()
    {
        QTemporaryDir state;
        WindowLibrary lib(state.path());
        lib.load();
        MainWindow *w = lib.entries()[0].window;
        Store *s = lib.entries()[0].store;
        w->show();
        w->activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(w));
        auto *tree = w->findChild<Sidebar *>();
        const QString id = s->allSessions().first()->id;
        auto unread = [&] { return tree->topLevelItem(0)->data(0, SidebarRole::Unseen).toInt(); };
        QVERIFY(lib.dispatch({{"cmd", "assistant.reply"}, {"target", id}, {"args", QJsonObject{{"text", "done"}}}})["ok"].toBool());
        QTRY_COMPARE(unread(), 1);
        const QJsonObject refused = lib.dispatch({{"cmd", "assistant.show"}, {"args", QJsonObject{{"window", "nope"}}}});
        QCOMPARE(refused["error"].toString(), QStringLiteral("no such window: nope"));
        QVERIFY(!w->assistantShown());
        QCOMPARE(unread(), 1);
        QVERIFY(lib.dispatch({{"cmd", "assistant.show"}})["ok"].toBool());
        QVERIFY(w->assistantShown());
        QVERIFY(s->selected.isEmpty());
        QTRY_COMPARE(unread(), 0);
        QVERIFY(lib.dispatch({{"cmd", "tree"}}).value("result")["tree"]["assistantShown"].toBool());
        QVERIFY(lib.dispatch({{"cmd", "assistant.reply"}, {"target", id}, {"args", QJsonObject{{"text", "again"}}}})["ok"].toBool());
        QTest::qWait(100);
        QCOMPARE(unread(), 0); // a reply arriving on the shown chat is already seen
        const QString second = lib.newWindow("second");
        lib.close(second);
        QTRY_VERIFY(!lib.entries()[1].open);
        const QJsonObject closed = lib.dispatch({{"cmd", "assistant.show"}, {"args", QJsonObject{{"window", second}}}});
        QCOMPARE(closed["error"].toString(), QStringLiteral("window not open — window.select it first"));
    }

    void assistantSeenClearsTheRowWithoutShowingTheChat()
    {
        QTemporaryDir state;
        WindowLibrary lib(state.path());
        lib.load();
        MainWindow *w = lib.entries()[0].window;
        w->show();
        auto *tree = w->findChild<Sidebar *>();
        const QString id = lib.entries()[0].store->allSessions().first()->id;
        auto unread = [&] { return tree->topLevelItem(0)->data(0, SidebarRole::Unseen).toInt(); };
        QVERIFY(lib.dispatch({{"cmd", "assistant.reply"}, {"target", id}, {"args", QJsonObject{{"text", "done"}}}})["ok"].toBool());
        QTRY_COMPARE(unread(), 1);
        QVERIFY(lib.dispatch({{"cmd", "assistant.seen"}})["ok"].toBool());
        QTRY_COMPARE(unread(), 0);
        QVERIFY(!w->assistantShown());
    }

    void aReplyBehindAnotherWindowStaysUnreadUntilTheChatIsInFront()
    {
        QTemporaryDir state;
        WindowLibrary lib(state.path());
        lib.load();
        MainWindow *w = lib.entries()[0].window;
        const QString id = lib.entries()[0].store->allSessions().first()->id;
        w->show();
        QWidget other;
        other.show();
        other.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&other));
        QVERIFY(lib.dispatch({{"cmd", "assistant.show"}, {"args", QJsonObject{{"window", w->windowId}}}})["ok"].toBool());
        QVERIFY(w->assistantShown());
        auto *tree = w->findChild<Sidebar *>();
        auto unread = [&] { return tree->topLevelItem(0)->data(0, SidebarRole::Unseen).toInt(); };
        QVERIFY(lib.dispatch({{"cmd", "assistant.reply"}, {"target", id}, {"args", QJsonObject{{"text", "done"}}}})["ok"].toBool());
        QTRY_COMPARE(unread(), 1);
        QTest::qWait(100);
        QCOMPARE(unread(), 1); // shown behind another window is not seen
        w->activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(w));
        QTRY_COMPARE(unread(), 0);
        QCOMPARE(QApplication::focusWidget(), w->findChild<QPlainTextEdit *>("assistantComposer")); // .show in the background
    }

    void ctrlTabFromTheChatReturnsToTheSessionItReplaced()
    {
        Store store;
        MainWindow w(store, dir.filePath("elis-mru.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, "a", {}), b = store.addSession(ws, "b", {});
        store.select(b);
        store.select(a);
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        w.showAssistant();
        w.namedAction("mru_switcher")->trigger();
        QKeyEvent release(QEvent::KeyRelease, Qt::Key_Control, Qt::NoModifier);
        QApplication::sendEvent(QApplication::focusWidget() ? QApplication::focusWidget() : &w, &release);
        QCOMPARE(store.selected, a);
        QVERIFY(!w.assistantShown());
    }

    void providerPickerClickWhileOpenClosesIt()
    {
        DetectedLaunchers launchers;
        launchers.found({"terminal", "claude", "codex"}, qEnvironmentVariable("PATH"));
        QTemporaryDir state;
        WindowLibrary lib(state.path());
        lib.launchers = &launchers;
        lib.load();
        MainWindow *w = lib.entries()[0].window;
        w->show();
        w->activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(w));
        w->showAssistant();
        auto *picker = w->findChild<QToolButton *>("assistantProvider");
        QTRY_VERIFY(picker->isEnabled());
        // the platform hands a press outside a popup to the popup, then replays it unless WA_NoMouseReplay
        auto pressOutside = [&](const QPoint &global) {
            picker->click();
            QPointer<QWidget> popup = QApplication::activePopupWidget();
            if (!popup)
                return -1;
            QTest::mousePress(popup, Qt::LeftButton, {}, popup->mapFromGlobal(global));
            return int(popup->isVisible()) * 2 + int(popup->testAttribute(Qt::WA_NoMouseReplay));
        };
        QCOMPARE(pressOutside(picker->mapToGlobal(picker->rect().center())), 1); // closed, the picker not pressed again
        QTRY_VERIFY(!QApplication::activePopupWidget());
        QCOMPARE(pressOutside(w->mapToGlobal(QPoint(5, w->height() - 5))), 0); // closed, the press reaches what it hit
    }

    void sidebarRowsDropIntoTheComposerAsTags()
    {
        QTemporaryDir state;
        WindowLibrary lib(state.path());
        lib.load();
        MainWindow *w = lib.entries()[0].window;
        Store *s = lib.entries()[0].store;
        const QString ws = s->workspaces.first().id;
        const QString id = s->allSessions().first()->id;
        s->renameWorkspace(ws, "mobile app");
        s->renameSession(id, "pair link");
        w->show();
        w->activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(w));
        w->showAssistant();
        const QJsonObject tree = lib.dispatch({{"cmd", "tree"}}).value("result")["tree"].toObject();
        const QString session = QLatin1Char('@') + tree["workspaces"][0]["sessions"][0]["handle"].toString();
        const QString group = QStringLiteral("@ws:") + tree["workspaces"][0]["handle"].toString();
        auto *sidebar = w->findChild<Sidebar *>();
        auto *view = w->findChild<AssistantView *>();
        QWidget *target = view->findChild<QPlainTextEdit *>("assistantComposer")->viewport();
        auto drop = [&](QMimeData *mime) {
            QVERIFY(mime);
            QDragEnterEvent enter(QPoint(10, 10), Qt::MoveAction, mime, Qt::LeftButton, {});
            QApplication::sendEvent(target, &enter);
            QVERIFY(enter.isAccepted());
            QDropEvent dropped(QPointF(10, 10), Qt::MoveAction, mime, Qt::LeftButton, {});
            QApplication::sendEvent(target, &dropped);
            QVERIFY(dropped.isAccepted());
            delete mime;
        };
        auto *composer = view->findChild<QPlainTextEdit *>("assistantComposer");
        composer->setPlainText("ask");
        drop(sidebar->dragMime(id)); // inside the word: the tag lands after it
        QCOMPARE(view->tags(), QStringList{session});
        QCOMPARE(composer->toPlainText(), "ask " + session + " ");
        QTest::mousePress(sidebar->viewport(), Qt::LeftButton, {}, sidebar->visualItemRect(sidebar->topLevelItem(1)).center());
        drop(sidebar->dragMime({})); // the pressed workspace header, again after the word
        QCOMPARE(composer->toPlainText(), "ask " + group + " " + session + " ");
    }

    void tagsStayWhereTheyAreTyped()
    {
        QTemporaryDir state;
        WindowLibrary lib(state.path());
        lib.load();
        MainWindow *w = lib.entries()[0].window;
        w->show();
        w->activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(w));
        w->showAssistant();
        const QJsonObject tree = lib.dispatch({{"cmd", "tree"}}).value("result")["tree"].toObject();
        const QString session = QLatin1Char('@') + tree["workspaces"][0]["sessions"][0]["handle"].toString();
        auto *view = w->findChild<AssistantView *>();
        auto *composer = view->findChild<QPlainTextEdit *>("assistantComposer");
        composer->setFocus();
        QTest::keyClicks(composer, "ask @");
        QTest::keyClicks(composer, session.mid(1));
        QTest::keyClick(view->findChild<QCompleter *>()->popup(), Qt::Key_Return);
        QTest::keyClicks(composer, "about @nobody");
        QCOMPARE(composer->toPlainText(), "ask " + session + " about @nobody");
        QCOMPARE(view->tags(), QStringList{session}); // a word that names nothing is not a tag
    }

    void atCompletionListsHandles()
    {
        QTemporaryDir state;
        WindowLibrary lib(state.path());
        lib.load();
        MainWindow *w = lib.entries()[0].window;
        Store *s = lib.entries()[0].store;
        s->renameSession(s->allSessions().first()->id, "pair link");
        s->addSession(s->workspaces.first().id, "logcat", {});
        w->show();
        w->activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(w));
        w->showAssistant();
        const QJsonObject tree = lib.dispatch({{"cmd", "tree"}}).value("result")["tree"].toObject();
        auto *view = w->findChild<AssistantView *>();
        auto *composer = view->findChild<QPlainTextEdit *>("assistantComposer");
        QCompleter *completer = view->findChild<QCompleter *>();
        auto listed = [&] {
            QStringList tags;
            for (int i = 0; completer->setCurrentRow(i); ++i)
                tags << completer->currentIndex().data(Qt::UserRole).toString();
            return tags;
        };
        composer->setFocus();
        QTest::keyClicks(composer, "ask @");
        QTRY_VERIFY(completer->popup()->isVisible());
        QStringList all{"@all", QStringLiteral("@ws:") + tree["workspaces"][0]["handle"].toString()};
        for (const QJsonValue &session : tree["workspaces"][0]["sessions"].toArray())
            all << QLatin1Char('@') + session["handle"].toString();
        QCOMPARE(listed(), all);
        QVERIFY(completer->popup()->sizeHintForRow(0) >= completer->popup()->fontMetrics().height()); // the palette's rows
        QTest::keyClicks(composer, "lo");
        QCOMPARE(listed(), QStringList{all.last()});
        QTest::keyClick(completer->popup(), Qt::Key_Return);
        QCOMPARE(view->tags(), QStringList{all.last()});
        QCOMPARE(composer->toPlainText(), "ask " + all.last() + " ");
        QVERIFY(!completer->popup()->isVisible());
    }

    void clearButtonFollowsWhetherTheChatHasEntries()
    {
        struct Quiet : AssistantSink {
            void enqueue(const QString &) override { }
            void providerChanged(const QString &) override { }
        } sink;
        QTemporaryDir state;
        DetectedLaunchers launchers;
        WindowLibrary lib(state.path());
        lib.launchers = &launchers;
        lib.assistantSink = &sink;
        lib.load();
        MainWindow *w = lib.entries()[0].window;
        w->show();
        w->showAssistant();
        auto *clear = w->findChild<QToolButton *>("assistantClear");
        QTRY_VERIFY(clear->isVisible() && !clear->isEnabled());
        QVERIFY(lib.dispatch({{"cmd", "assistant.ask"}, {"args", QJsonObject{{"text", "hi"}}}})["ok"].toBool());
        QTRY_VERIFY(clear->isEnabled());
        QVERIFY(lib.dispatch({{"cmd", "assistant.clear"}})["ok"].toBool());
        QTRY_VERIFY(!clear->isEnabled());
    }

    void providerPickerSitsAboveTheComposerAndPicksWithKeys()
    {
        struct Quiet : AssistantSink {
            void enqueue(const QString &) override { }
            void providerChanged(const QString &) override { }
        } sink;
        QTemporaryDir state;
        DetectedLaunchers launchers;
        launchers.found({"terminal", "claude", "codex"}, qEnvironmentVariable("PATH"));
        WindowLibrary lib(state.path());
        lib.launchers = &launchers;
        lib.assistantSink = &sink;
        lib.load();
        MainWindow *w = lib.entries()[0].window;
        w->show();
        w->activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(w));
        w->showAssistant();
        auto provider = [&] {
            const QJsonObject tree = lib.dispatch({{"cmd", "tree"}});
            return tree["result"]["tree"]["assistant"]["provider"].toString();
        };
        QVERIFY(lib.dispatch({{"cmd", "assistant.provider"}, {"args", QJsonObject{{"provider", "claude"}}}})["ok"].toBool());
        auto *picker = w->findChild<QToolButton *>("assistantProvider");
        QTRY_COMPARE(picker->text(), QStringLiteral("Claude Code"));
        picker->click();
        QWidget *popup = QApplication::activePopupWidget();
        QVERIFY(popup && popup->objectName() == QLatin1String("assistantProviderPopup"));
        const QWidget *box = w->findChild<QFrame *>("composer");
        QVERIFY(popup->geometry().bottom() - 14 < box->mapToGlobal(QPoint(0, 0)).y()); // the panel, not its shadow, clears the box
        QTest::keyClick(popup, Qt::Key_Down);
        QTest::keyClick(popup, Qt::Key_Return);
        QTRY_VERIFY(!QApplication::activePopupWidget());
        QCOMPARE(provider(), QStringLiteral("codex"));
    }

    void assistantProviderTakesOneInputPerTurnInOrder()
    {
        AssistantHost host("bash " ELIS_TEST_FIXTURES "/fake-provider.sh");
        const QByteArray sessionVar = qgetenv("ELIS_SESSION_ID"), claudeVar = qgetenv("CLAUDECODE");
        qputenv("ELIS_SESSION_ID", "leak");
        qputenv("CLAUDECODE", "1");
        auto restore = qScopeGuard([&] {
            sessionVar.isNull() ? qunsetenv("ELIS_SESSION_ID") : qputenv("ELIS_SESSION_ID", sessionVar);
            claudeVar.isNull() ? qunsetenv("CLAUDECODE") : qputenv("CLAUDECODE", claudeVar);
        });
        QSignalSpy events(host.lib->active()->events(), &EventSource::event);
        const QString session = host.lib->entries()[0].store->allSessions().first()->id;
        QVERIFY(host.ask("one")["ok"].toBool());
        QVERIFY(host.ask("two")["ok"].toBool());
        QVERIFY(host.lib->dispatch({{"cmd", "assistant.reply"}, {"target", session}, {"args", QJsonObject{{"text", "three"}}}})["ok"].toBool());
        QVERIFY(host.running());
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 3, 10000);
        const QStringList replies = host.texts("assistant");
        QVERIFY2(replies[0].endsWith(": one") && replies[1].endsWith(": two"), qPrintable(replies.join(" | ")));
        QVERIFY2(replies[2].endsWith(session + "] three"), qPrintable(replies[2])); // no " early": each input followed a result
        QVERIFY(!host.running());
        int answered = 0;
        for (const QList<QVariant> &e : std::as_const(events))
            answered += e.first().toJsonObject().value("payload")["kind"].toString() == QLatin1String("assistant");
        QCOMPARE(answered, 3);
    }

    void assistantPerInputProviderRunsOnceForEachInput()
    {
        // cat returns at once only on /dev/null stdin
        AssistantHost host("sh -c \"cat; head -n 5 " ELIS_TEST_ASSISTANT_FIXTURES "/codex.jsonl\"", "codex");
        QVERIFY(host.ask("one")["ok"].toBool());
        QVERIFY(host.ask("two")["ok"].toBool());
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant"), QStringList({"pong", "pong"}), 5000);
        QVERIFY(!host.running());
    }

    void assistantProviderThatCannotStartIsAnError()
    {
        AssistantHost host("/nonexistent/elis-fake-provider");
        QVERIFY(host.ask("hi")["ok"].toBool());
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("error").size(), 1, 5000);
        QVERIFY(!host.running());
    }

    void assistantProviderStopsWithTheAppAndStaysOnReselect()
    {
        AssistantHost host("bash " ELIS_TEST_FIXTURES "/fake-provider.sh");
        auto pidOf = [](const QString &reply) { return reply.section(QLatin1Char(' '), 1, 1).chopped(1).toInt(); };
        QVERIFY(host.ask("one")["ok"].toBool());
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 1, 5000);
        const int pid = pidOf(host.texts("assistant")[0]);
        QVERIFY(pid > 0 && ::kill(pid, 0) == 0);
        host.choose("claude");
        QTest::qWait(200);
        QCOMPARE(::kill(pid, 0), 0);
        host.runner.reset();
        QCOMPARE(::kill(pid, 0), -1);
    }

    void assistantSwitchMidTurnHandsTheCutInputToTheNewProvider()
    {
        AssistantHost host("bash " ELIS_TEST_FIXTURES "/fake-provider.sh");
        QVERIFY(host.ask("zero")["ok"].toBool());
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 1, 5000);
        const int first = host.texts("assistant")[0].section(QLatin1Char(' '), 1, 1).chopped(1).toInt();
        QVERIFY(host.ask("one")["ok"].toBool());
        host.choose("codex"); // claude is still answering "one"
        QTRY_COMPARE_WITH_TIMEOUT(::kill(first, 0), -1, 5000);
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 2, 5000);
        const QString answer = host.texts("assistant")[1];
        QVERIFY2(answer.endsWith("\n\none") && answer.contains("user: zero") && !answer.contains("user: one"), qPrintable(answer));
        QVERIFY(!host.running());
    }

    void assistantClearMidTurnStopsTheProviderAndStartsAfresh()
    {
        AssistantHost host("bash " ELIS_TEST_FIXTURES "/fake-provider.sh");
        auto pidOf = [](const QString &reply) { return reply.section(QLatin1Char(' '), 1, 1).chopped(1).toInt(); };
        QVERIFY(host.ask("zero")["ok"].toBool());
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 1, 5000);
        const int first = pidOf(host.texts("assistant")[0]);
        QSignalSpy events(host.lib->active()->events(), &EventSource::event);
        QVERIFY(host.ask("one")["ok"].toBool());
        QVERIFY(host.ask("two")["ok"].toBool());
        QVERIFY(host.lib->dispatch({{"cmd", "assistant.clear"}})["ok"].toBool());
        QVERIFY(host.lib->dispatch({{"cmd", "assistant.read"}}).value("result")["assistant"]["entries"].toArray().isEmpty());
        QVERIFY(!host.running());
        QTRY_COMPARE_WITH_TIMEOUT(::kill(first, 0), -1, 5000);
        QVERIFY(std::any_of(events.cbegin(), events.cend(),
                            [](const QList<QVariant> &e) { return e.first().toJsonObject().value("kind") == QLatin1String("assistant.cleared"); }));
        QFile resume(host.state.filePath("assistant/chat.jsonl.resume"));
        QVERIFY(resume.open(QIODevice::ReadOnly));
        QVERIFY(QJsonDocument::fromJson(resume.readAll()).object().isEmpty());
        QTest::qWait(500); // the cut turn's answer would have landed by now
        QVERIFY(host.texts("assistant").isEmpty());
        QVERIFY(host.ask("three")["ok"].toBool());
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 1, 5000);
        const QString answer = host.texts("assistant")[0];
        QVERIFY2(answer.endsWith(": three") && pidOf(answer) != first, qPrintable(answer));
    }

    void assistantErrorTurnKeepsTheQueue()
    {
        AssistantHost host("bash " ELIS_TEST_FIXTURES "/fake-provider.sh");
        QVERIFY(host.ask("fail")["ok"].toBool());
        QVERIFY(host.ask("two")["ok"].toBool());
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 1, 5000);
        QCOMPARE(host.texts("error"), QStringList{"boom"});
        QVERIFY(host.texts("assistant")[0].endsWith(": two"));
        QVERIFY(!host.running());
    }

    void assistantCrashMidTurnIsAnErrorAndTheNextInputRestarts()
    {
        AssistantHost host("bash " ELIS_TEST_FIXTURES "/fake-provider.sh");
        QVERIFY(host.ask("crash")["ok"].toBool());
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("error").size(), 1, 5000);
        QVERIFY2(host.texts("error")[0].contains("crashed"), qPrintable(host.texts("error")[0]));
        QVERIFY(!host.running());
        QVERIFY(host.ask("after")["ok"].toBool());
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 1, 5000);
        QVERIFY(host.texts("assistant")[0].endsWith(": after"));
    }

    void assistantProviderGetsThisAppsStateDirAndTools()
    {
        AssistantHost host("bash " ELIS_TEST_FIXTURES "/fake-provider.sh");
        QVERIFY(host.ask("env")["ok"].toBool());
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 1, 5000);
        QCOMPARE(host.texts("assistant")[0], host.state.path() + " " + QCoreApplication::applicationDirPath() + ":" + AssistantHost::path());
    }

    void assistantInputWaitsForDetectionAndSavesTheDefault()
    {
        AssistantHost host("bash " ELIS_TEST_FIXTURES "/fake-provider.sh", "", false);
        QVERIFY(host.ask("one")["ok"].toBool());
        QTest::qWait(500);
        QVERIFY(host.texts("assistant").isEmpty() && host.texts("error").isEmpty());
        QVERIFY(host.running());
        QVERIFY(host.node()["provider"].toString().isEmpty());
        host.launchers.found({"terminal", "claude"}, AssistantHost::path());
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 1, 5000);
        QCOMPARE(host.node()["provider"].toString(), QStringLiteral("claude"));
        QVERIFY(!host.running());
    }

    void treeListsTheLaunchersThePlusMenuOffers()
    {
        AssistantHost host("true", "");
        const QJsonObject tree = host.lib->dispatch({{"cmd", "tree"}}).value("result")["tree"].toObject();
        QCOMPARE(tree["launchers"].toArray(), (QJsonArray{"terminal", "claude", "codex"}));
    }

    void assistantTurnWithoutTextClearsTheWorkingState()
    {
        AssistantHost host("bash " ELIS_TEST_FIXTURES "/fake-provider.sh");
        MainWindow *w = host.lib->entries()[0].window;
        w->show();
        QVERIFY(QTest::qWaitForWindowExposed(w));
        w->showAssistant();
        host.ask("hi");
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 1, 5000);
        host.ask("quiet");
        auto *working = w->findChild<QLabel *>("assistantWorking");
        auto *tree = w->findChild<Sidebar *>();
        QTRY_VERIFY_WITH_TIMEOUT(!host.running(), 5000);
        QTRY_VERIFY(working->isHidden());
        QTRY_COMPARE(tree->topLevelItem(0)->data(0, SidebarRole::Status).toString(), QStringLiteral("idle"));
        QCOMPARE(host.texts("assistant").size(), 1);
    }

    void assistantResumeOfAGoneConversationStartsAfresh()
    {
        AssistantHost host("bash " ELIS_TEST_FIXTURES "/fake-provider.sh", "claude", true, R"({"claude":"gone"})");
        QCOMPARE(AssistantBridge::resume("claude"), QStringLiteral("gone"));
        host.ask("hi");
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 1, 5000);
        QVERIFY(host.texts("assistant")[0].endsWith("hi"));
        QVERIFY(host.texts("error").isEmpty());
        QVERIFY(AssistantBridge::resume("claude").startsWith("fake-")); // the fresh conversation, resumed next time
    }

    void assistantSavedProviderNoLongerInstalledRunsThePickersDefault()
    {
        AssistantHost host("bash " ELIS_TEST_FIXTURES "/fake-provider.sh", "opencode");
        host.ask("hi");
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 1, 5000);
        QCOMPARE(host.node()["provider"].toString(), QStringLiteral("claude"));
    }

    void assistantProviderChoiceWaitsForDetection()
    {
        AssistantHost host("bash " ELIS_TEST_FIXTURES "/fake-provider.sh", "claude", false);
        MainWindow *w = host.lib->entries()[0].window;
        w->show();
        QVERIFY(QTest::qWaitForWindowExposed(w));
        w->showAssistant();
        auto *picker = w->findChild<QToolButton *>("assistantProvider");
        QTRY_VERIFY(!picker->isEnabled());
        QCOMPARE(picker->text(), QStringLiteral("Claude Code")); // the saved choice, not "No agent found"
        const QJsonObject choose{{"cmd", "assistant.provider"}, {"args", QJsonObject{{"provider", "codex"}}}};
        QCOMPARE(host.lib->dispatch(choose)["error"].toString(), QStringLiteral("agents are still being detected; try again in a moment"));
        host.launchers.found({"terminal", "claude", "codex"}, AssistantHost::path());
        QTRY_VERIFY(picker->isEnabled());
        QVERIFY(host.lib->dispatch(choose)["ok"].toBool());
    }

    void assistantStreamProviderGetsTheRecapAfterASwitch()
    {
        AssistantHost host("bash " ELIS_TEST_FIXTURES "/fake-provider.sh", "codex");
        QVERIFY(host.ask("zero")["ok"].toBool());
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 1, 5000);
        QVERIFY(host.ask("one")["ok"].toBool());
        host.choose("claude"); // codex has not answered "one" yet
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 2, 5000);
        QString answer = host.texts("assistant")[1];
        QVERIFY2(answer.contains("Earlier messages in this chat") && answer.contains("user: zero") && !answer.contains("user: one")
                     && answer.endsWith("\n\none"),
                 qPrintable(answer));
        host.choose("codex"); // idle
        host.choose("claude");
        QVERIFY(host.ask("two")["ok"].toBool());
        QTRY_COMPARE_WITH_TIMEOUT(host.texts("assistant").size(), 3, 5000);
        answer = host.texts("assistant")[2];
        QVERIFY2(answer.contains("Earlier messages in this chat") && answer.contains("user: one") && answer.endsWith("\n\ntwo"), qPrintable(answer));
        QVERIFY(!host.running());
    }

    void detectedPathHasNoEmptyElementAndSurvivesAFailedProbe()
    {
        DetectedLaunchers launchers;
        launchers.probed({});
        QVERIFY(launchers.detected());
        QVERIFY2(!launchers.path().split(QLatin1Char(':')).contains(QString()), qPrintable(launchers.path()));
        launchers.probed("rc noise\nelis-launcher-path\n\n");
        QVERIFY2(!launchers.path().split(QLatin1Char(':')).contains(QString()), qPrintable(launchers.path()));
        launchers.probed("rc noise\nelis-launcher-path\n/login/bin\n");
        QVERIFY(launchers.path().startsWith("/login/bin:"));
        launchers.probed({}); // timed out
        QVERIFY(launchers.path().startsWith("/login/bin:"));
    }

    void typedTextGetsItsFinalReturnInItsOwnWrite()
    {
        Store store;
        MainWindow w(store, dir.filePath("paced.json"));
        w.restore({});
        const QString id = store.addSession(store.addWorkspace("w"), {}, {});
        store.select(id);
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QString error;
        QTRY_VERIFY_WITH_TIMEOUT(!w.text(id, "left", false, &error).trimmed().isEmpty(), 5000); // the prompt
        auto type = [&](const QString &text) { return dispatch(store, w, {{"cmd", "session.type"}, {"target", id}, {"args", QJsonObject{{"text", text}}}}); };
        // each dd is one read; head then takes the next ten bytes whatever the reads
        const QString read = QStringLiteral("dd bs=4096 count=1 2>/dev/null | od -An -tx1; ");
        QVERIFY(type("stty raw -echo; " + read + read + "head -c 10 | od -An -tx1; stty sane\n")["ok"].toBool());
        QTRY_COMPARE_WITH_TIMEOUT(w.foregroundArgv(id, "main").value(0), QStringLiteral("dd"), 5000);
        QVERIFY(type("hello\n")["ok"].toBool());
        bool replied = false;
        MainWindow::whenTyped(&w, [&] { replied = true; });
        QVERIFY(!replied); // a control reply waits for the Return
        QTRY_VERIFY(replied);
        const QRegularExpression twoReads(QStringLiteral("68 65 6c 6c 6f\\n *0d\\b")); // raw mode: no carriage return before a line
        QTRY_VERIFY2_WITH_TIMEOUT(twoReads.match(w.text(id, "left", false, &error)).hasMatch(), qPrintable(w.text(id, "left", false, &error)), 5000);
        QVERIFY(type("msg1\n")["ok"].toBool());
        QVERIFY(type("msg2\n")["ok"].toBool()); // still behind msg1's Return
        QTRY_VERIFY2_WITH_TIMEOUT(w.text(id, "left", false, &error).contains("6d 73 67 31 0d 6d 73 67 32 0d"), qPrintable(w.text(id, "left", false, &error)), 5000);
    }

    void selectingASessionUpdatesTheSidebarInPlace()
    {
        Store store;
        MainWindow w(store, dir.filePath("inplace.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, {}, {}), b = store.addSession(ws, {}, {});
        store.select(a);
        w.show();
        auto *tree = w.findChild<Sidebar *>();
        QTreeWidgetItem *wsItem = tree->topLevelItem(1), *rowA = wsItem->child(0), *rowB = wsItem->child(1);
        store.select(b);
        store.setStatus(a, "blocked");
        QCOMPARE(tree->topLevelItem(1), wsItem);
        QCOMPARE(wsItem->child(0), rowA);
        QCOMPARE(wsItem->child(1), rowB);
        QVERIFY(rowB->isSelected() && !rowA->isSelected());
        QCOMPARE(rowA->data(0, SidebarRole::Status).toString(), QStringLiteral("blocked"));
        store.addSession(ws, {}, {}); // a new row is a structural change
        QCOMPARE(tree->topLevelItem(1)->childCount(), 3);
    }

    void aBlinkingGlyphKeepsFadingThroughRebuilds()
    {
        Store store;
        MainWindow w(store, dir.filePath("blink.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, {}, {});
        store.setStatus(a, "active", false, true);
        w.show();
        auto *tree = w.findChild<Sidebar *>();
        QSet<int> seen;
        QElapsedTimer t;
        t.start();
        while (t.elapsed() < 600) { // rebuilding faster than a frame must not freeze the fade
            tree->rebuild();
            QTest::qWait(10);
            seen.insert(tree->blinkAlpha());
        }
        QVERIFY2(seen.size() > 3, "the fade never advanced");
        QVERIFY(*std::min_element(seen.begin(), seen.end()) < 120); // fades down toward master's 0.2
        store.setStatus(a, "idle");
        QCOMPARE(tree->blinkAlpha(), 255);
    }

    void anActiveRowKeepsItsAuroraDriftingWithoutABlink()
    {
        Store store;
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, {}, {});
        store.setStatus(a, "active");
        Sidebar tree(store);
        tree.rebuild();
        const qreal start = tree.auroraPhase();
        QTRY_VERIFY(tree.auroraPhase() != start);
        store.setStatus(a, "idle");
        tree.rebuild();
        const qreal stopped = tree.auroraPhase();
        QTest::qWait(100);
        QCOMPARE(tree.auroraPhase(), stopped);
    }

    void aWorkspaceRowRollsUpTheMostUrgentStatus()
    {
        Store store;
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, {}, {}), b = store.addSession(ws, {}, {});
        Sidebar tree(store);
        tree.rebuild();
        auto *row = tree.topLevelItem(1);
        QCOMPARE(row->data(0, SidebarRole::Status).toString(), QStringLiteral("idle"));
        store.setStatus(a, "completed");
        store.setStatus(b, "active", false, true);
        tree.rebuild();
        QCOMPARE(row->data(0, SidebarRole::Status).toString(), QStringLiteral("active")); // active outranks completed
        QVERIFY(row->data(0, SidebarRole::Blink).toBool());
        store.setStatus(a, "blocked");
        tree.rebuild();
        QCOMPARE(row->data(0, SidebarRole::Status).toString(), QStringLiteral("blocked"));
        QVERIFY(!row->data(0, SidebarRole::Blink).toBool());
    }

    void fontKeysZoomTheTerminalAndARelaunchKeepsIt()
    {
        QJsonObject saved;
        double base = 0;
        {
            Store store;
            MainWindow w(store, dir.filePath("font.json"));
            w.restore({});
            store.select(store.addSession(store.addWorkspace("w"), {}, {}));
            w.show();
            w.activateWindow();
            QVERIFY(QTest::qWaitForWindowActive(&w));
            QTRY_VERIFY_WITH_TIMEOUT(QApplication::focusWidget() && QApplication::focusWidget()->inherits("Konsole::TerminalDisplay"), 5000);
            QWidget *term = QApplication::focusWidget();
            base = term->font().pointSizeF();
            QTest::keyClick(term, Qt::Key_Plus, Qt::ControlModifier | Qt::ShiftModifier);
            QTest::keyClick(term, Qt::Key_Plus, Qt::ControlModifier | Qt::ShiftModifier);
            QCOMPARE(term->font().pointSizeF(), base + 2);
            QCOMPARE(store.session(store.selected)->fontSize, base + 2);
            QTest::keyClick(term, Qt::Key_0, Qt::ControlModifier | Qt::ShiftModifier);
            QCOMPARE(term->font().pointSizeF(), base);
            QCOMPARE(store.session(store.selected)->fontSize, 0.0);
            QString e;
            QVERIFY(w.font(store.selected, "main", "dec", &e));
            QCOMPARE(store.session(store.selected)->fontSize, base - 1);
            saved = store.toJson();
        }
        Store store;
        store.fromJson(saved);
        MainWindow w(store, dir.filePath("font2.json"));
        w.restore({});
        w.show();
        QWidget *term = nullptr;
        for (QWidget *x : w.findChildren<QWidget *>())
            if (x->inherits("Konsole::TerminalDisplay"))
                term = x;
        QVERIFY(term);
        QCOMPARE(term->font().pointSizeF(), base - 1);
    }

    void sessionPillListsWhatNeedsYouThenRecent()
    {
        Store store;
        MainWindow w(store, dir.filePath("recent.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, "alpha", {}), b = store.addSession(ws, "beta", {}), c = store.addSession(ws, "gamma", {});
        store.select(a);
        store.select(b);
        store.select(c);
        store.setStatus(a, "blocked");
        w.show();
        QAbstractButton *pill = nullptr;
        for (auto *t : w.findChildren<QAbstractButton *>())
            if (t->accessibleName() == QLatin1String("Session switcher"))
                pill = t;
        QVERIFY(pill && pill->isVisible());
        pill->click();
        auto *list = w.findChild<QFrame *>("palette")->findChild<QListWidget *>();
        QTRY_VERIFY(list->isVisible());
        QStringList listed;
        for (int i = 0; i < list->count(); ++i)
            listed << list->item(i)->text();
        QCOMPARE(listed, (QStringList{"Needs you", "alpha", "Recent", "beta"})); // the shown idle session is not a jump target
        QTest::keyClick(list, Qt::Key_Escape);
    }

    void sessionPaletteAbbreviatesHomeInTheDetail()
    {
        const QByteArray realHome = qgetenv("HOME");
        auto restoreHome = qScopeGuard([&] { qputenv("HOME", realHome); });
        const QString home = dir.filePath("home");
        QVERIFY(QDir().mkpath(home + "/src"));
        qputenv("HOME", home.toUtf8());
        Store store;
        MainWindow w(store, dir.filePath("tilde.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        store.addSession(ws, "in-home", home + "/src");
        store.addSession(ws, "at-home", home);
        store.select(store.addSession(ws, "elsewhere", "/usr"));
        w.show();
        w.namedAction("session_palette")->trigger();
        auto *list = w.findChild<QFrame *>("palette")->findChild<QListWidget *>();
        QTRY_VERIFY(list->isVisible());
        auto detailOf = [&](const QString &name) { return list->findItems(name, Qt::MatchExactly).value(0)->data(PaletteRole::Subtitle).toString(); };
        QCOMPARE(detailOf("in-home"), QStringLiteral("~/src"));
        QCOMPARE(detailOf("at-home"), QStringLiteral("~"));
    }

    void sessionPaletteRowsCarryStatusAndIdleHasNone()
    {
        Store store;
        MainWindow w(store, dir.filePath("status_roles.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, "blocked-s", {}), b = store.addSession(ws, "active-s", {}),
                      c = store.addSession(ws, "done-s", {}), d = store.addSession(ws, "idle-s", {}),
                      e = store.addSession(ws, "cur-s", {});
        store.select(a);
        store.select(b);
        store.select(c);
        store.select(d);
        store.select(e);
        store.setStatus(a, "blocked");
        store.setStatus(b, "active", false, true);
        store.setStatus(c, "completed");
        w.show();
        w.namedAction("session_palette")->trigger();
        auto *list = w.findChild<QFrame *>("palette")->findChild<QListWidget *>();
        QTRY_VERIFY(list->isVisible());
        auto statusOf = [&](const QString &name) {
            auto *row = list->findItems(name, Qt::MatchExactly).value(0);
            return row ? row->data(PaletteRole::Status).toString() : QStringLiteral("MISSING");
        };
        QCOMPARE(statusOf("blocked-s"), QStringLiteral("blocked"));
        QCOMPARE(statusOf("active-s"), QStringLiteral("active"));
        QCOMPARE(statusOf("done-s"), QStringLiteral("completed"));
        QCOMPARE(statusOf("idle-s"), QString());
        QVERIFY(list->findItems("active-s", Qt::MatchExactly).value(0)->data(PaletteRole::Blink).toBool());
        QTest::keyClick(w.findChild<QFrame *>("palette")->findChild<QLineEdit *>(), Qt::Key_Escape);

        // Ctrl+Tab switcher keeps a flat list with no headers and carries the same status role
        w.namedAction("mru_switcher")->trigger();
        QTRY_VERIFY(list->isVisible());
        for (int i = 0; i < list->count(); ++i)
            QVERIFY(!list->item(i)->data(PaletteRole::Header).toBool());
        QCOMPARE(statusOf("blocked-s"), QStringLiteral("blocked"));
        QCOMPARE(statusOf("active-s"), QStringLiteral("active"));
        QCOMPARE(statusOf("done-s"), QStringLiteral("completed"));
        QCOMPARE(statusOf("idle-s"), QString());
        QTest::keyClick(&w, Qt::Key_Escape);
    }

    void sessionPaletteSectionsOrderSelectedAttentionAndSearchSwap()
    {
        Store store;
        MainWindow w(store, dir.filePath("sections.json"));
        w.restore({});
        const QString ws = store.addWorkspace("proj");
        const QString a = store.addSession(ws, "done-s", {}), b = store.addSession(ws, "active-s", {}),
                      c = store.addSession(ws, "blocked-s", {}), d = store.addSession(ws, "recent-s", {}),
                      e = store.addSession(ws, "closed-s", {});
        store.select(d);
        store.select(a);
        store.select(b);
        store.select(c);
        store.setStatus(a, "completed");
        store.setStatus(b, "active");
        store.setStatus(c, "blocked"); // currently selected AND non-idle: stays in Needs you
        store.removeSession(e);
        w.show();
        w.namedAction("session_palette")->trigger();
        auto *palette = w.findChild<QFrame *>("palette");
        auto *list = palette->findChild<QListWidget *>();
        auto *search = palette->findChild<QLineEdit *>();
        QTRY_VERIFY(list->isVisible());

        QStringList rows;
        QList<bool> headers;
        for (int i = 0; i < list->count(); ++i) {
            rows << list->item(i)->text();
            headers << list->item(i)->data(PaletteRole::Header).toBool();
        }
        QCOMPARE(rows, (QStringList{"Needs you", "blocked-s", "active-s", "done-s", "Recent", "recent-s", "Recently closed", "closed-s"}));
        QCOMPARE(headers, (QList<bool>{true, false, false, false, true, false, true, false}));
        QCOMPARE(list->currentItem()->text(), QStringLiteral("blocked-s")); // first real row, not header

        // non-empty query replaces the three sections with one "Sessions" header
        QTest::keyClicks(search, "-s");
        QStringList filtered;
        for (int i = 0; i < list->count(); ++i)
            filtered << list->item(i)->text();
        QCOMPARE(filtered, (QStringList{"Sessions", "done-s", "active-s", "blocked-s", "recent-s", "closed-s"}));
        QVERIFY(list->item(0)->data(PaletteRole::Header).toBool());
        QCOMPARE(list->currentItem()->text(), QStringLiteral("done-s"));
        QTest::keyClick(search, Qt::Key_Escape);
    }

    void sessionPaletteArrowsSkipHeaders()
    {
        Store store;
        MainWindow w(store, dir.filePath("skip_headers.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, "alpha", {}), b = store.addSession(ws, "beta", {}), c = store.addSession(ws, "gamma", {});
        store.select(a);
        store.select(b);
        store.select(c);
        store.setStatus(a, "blocked");
        w.show();
        w.namedAction("session_palette")->trigger();
        auto *palette = w.findChild<QFrame *>("palette");
        auto *list = palette->findChild<QListWidget *>();
        auto *search = palette->findChild<QLineEdit *>();
        QTRY_VERIFY(list->isVisible());
        // 0: Needs you (header), 1: alpha, 2: Recent (header), 3: beta
        QCOMPARE(list->currentRow(), 1);
        QCOMPARE(list->currentItem()->text(), QStringLiteral("alpha"));
        QTest::keyClick(search, Qt::Key_Down);
        QCOMPARE(list->currentRow(), 3);
        QCOMPARE(list->currentItem()->text(), QStringLiteral("beta"));
        QTest::keyClick(search, Qt::Key_Up);
        QCOMPARE(list->currentRow(), 1);
        QCOMPARE(list->currentItem()->text(), QStringLiteral("alpha"));
        QTest::keyClick(search, Qt::Key_J, Qt::ControlModifier);
        QCOMPARE(list->currentRow(), 3);
        QTest::keyClick(search, Qt::Key_K, Qt::ControlModifier);
        QCOMPARE(list->currentRow(), 1);
        // clicking a header does nothing
        QTest::mouseClick(list->viewport(), Qt::LeftButton, {}, list->visualItemRect(list->item(2)).center());
        QVERIFY(palette->isVisible());
        QCOMPARE(list->currentRow(), 1);
        QTest::keyClick(search, Qt::Key_Escape);
    }

    void sessionPaletteRecentlyClosedDetailIsWorkspaceName()
    {
        Store store;
        MainWindow w(store, dir.filePath("closed_detail.json"));
        w.restore({});
        const QString ws = store.addWorkspace("mobile");
        const QString a = store.addSession(ws, "keep", {}), b = store.addSession(ws, "ble-spike", {}),
                      c = store.addSession(ws, "resumed", {}, {}, -1, QStringLiteral("claude --resume abc"));
        store.select(a);
        store.removeSession(b);
        store.removeSession(c);
        w.show();
        w.namedAction("session_palette")->trigger();
        auto *palette = w.findChild<QFrame *>("palette");
        auto *list = palette->findChild<QListWidget *>();
        QTRY_VERIFY(list->isVisible());
        auto *plainRow = list->findItems("ble-spike", Qt::MatchExactly).value(0);
        auto *claudeRow = list->findItems("resumed", Qt::MatchExactly).value(0);
        QVERIFY(plainRow && claudeRow);
        QCOMPARE(plainRow->data(PaletteRole::Subtitle).toString(), QStringLiteral("mobile"));
        QVERIFY(!plainRow->data(PaletteRole::Subtitle).toString().contains(QStringLiteral("closed"), Qt::CaseInsensitive));
        QCOMPARE(plainRow->data(PaletteRole::Workspace).toString(), QString());
        QCOMPARE(plainRow->data(PaletteRole::Status).toString(), QString());
        QCOMPARE(plainRow->data(PaletteRole::Icon).toString(), QStringLiteral("terminal"));
        QCOMPARE(claudeRow->data(PaletteRole::Icon).toString(), QStringLiteral("claude"));
        QTest::keyClick(palette->findChild<QLineEdit *>(), Qt::Key_Escape);
    }

    void footerFilterNarrowsTheTreeAndTintReachesTheRow()
    {
        Store store;
        MainWindow w(store, dir.filePath("filter.json"));
        w.restore({});
        const QString a = store.addWorkspace("a");
        store.addWorkspace("b");
        store.select(store.addSession(a, {}, {}));
        w.show();
        auto *tree = w.findChild<Sidebar *>();
        QToolButton *filter = nullptr;
        for (auto *b : w.findChildren<QToolButton *>())
            if (b->accessibleName() == QLatin1String("Toggle Workspace Filter"))
                filter = b;
        QVERIFY(filter && !filter->isEnabled());
        QCOMPARE(tree->topLevelItemCount(), 3);
        store.focusWorkspace(a, "add");
        QVERIFY(filter->isEnabled());
        QCOMPARE(tree->topLevelItemCount(), 3);
        filter->click();
        QVERIFY(store.focusEnabled);
        QCOMPARE(tree->topLevelItemCount(), 2);
        QVERIFY(tree->topLevelItem(1)->data(0, SidebarRole::Focused).toBool());
        store.setTint(a, "red");
        QCOMPARE(tree->topLevelItem(1)->data(0, SidebarRole::TintColor).toString(), QStringLiteral("red"));
    }

    void aProgressRowCarriesTheFillRoles()
    {
        Store store;
        MainWindow w(store, dir.filePath("progressrow.json"));
        w.restore({});
        const QString a = store.addSession(store.addWorkspace("w"), {}, {});
        store.select(a);
        store.setTint(a, "#336699");
        w.show();
        auto *tree = w.findChild<Sidebar *>();
        auto row = [&] { return tree->topLevelItem(1)->child(0); };
        QVERIFY(!row()->data(0, SidebarRole::ProgressFill).isValid());
        store.setControlProgress(a, QJsonObject{{"percent", 50}});
        QCOMPARE(row()->data(0, SidebarRole::ProgressFill).toDouble(), 0.5);
        QCOMPARE(row()->data(0, SidebarRole::ProgressColor).toString(), QStringLiteral("#336699"));
        QVERIFY(!row()->data(0, SidebarRole::Wave).toBool());
        store.setStatus(a, "blocked");
        QVERIFY(!row()->data(0, SidebarRole::ProgressFill).isValid());
        QVERIFY(!row()->data(0, SidebarRole::Wave).toBool());
        store.setStatus(a, "active");
        store.setControlProgress(a, QJsonObject{{"indeterminate", true}});
        QVERIFY(!row()->data(0, SidebarRole::ProgressFill).isValid());
        QVERIFY(row()->data(0, SidebarRole::Wave).toBool());
        store.setStatus(a, "completed");
        store.setTerminalProgress(a, "p1", {{"update", "set"}, {"progress", QJsonObject{{"indeterminate", true}}}});
        QVERIFY(row()->data(0, SidebarRole::Wave).toBool()); // indeterminate waves without an agent status
    }

    void tintMenuListsTheMacPaletteAndAHexAsCustom()
    {
        Store store;
        MainWindow w(store, dir.filePath("tintmenu.json"));
        w.restore({});
        const QString a = store.addSession(store.addWorkspace("w"), {}, {});
        store.select(a);
        store.setTint(a, "#FF8800");
        w.show();
        auto *tree = w.findChild<Sidebar *>();
        QTreeWidgetItem *row = tree->topLevelItem(1)->child(0);
        QCOMPARE(row->data(0, SidebarRole::TintColor).toString(), QStringLiteral("#ff8800"));
        QStringList titles;
        QTimer::singleShot(0, this, [&] {
            auto *menu = qobject_cast<QMenu *>(QApplication::activePopupWidget());
            QAction *mint = nullptr;
            for (QAction *m : menu->actions())
                if (m->text() == QLatin1String("Tint"))
                    for (QAction *c : m->menu()->actions()) {
                        titles << c->text() + (c->isChecked() ? QStringLiteral("*") : QString());
                        if (c->text() == QLatin1String("Mint"))
                            mint = c;
                    }
            mint->trigger();
            menu->close();
        });
        Q_EMIT tree->customContextMenuRequested(tree->visualItemRect(row).center());
        QCOMPARE(titles, (QStringList{"None", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray", "Teal", "Pink", "Brown",
                                      "Indigo", "Mint", "Custom #ff8800*"}));
        QCOMPARE(store.session(a)->tint, Tint{"mint"});
        QCOMPARE(tintColor("mint"), QColor(QApplication::palette().color(QPalette::Window).lightness() < 128 ? 0x63E6E2 : 0x00C7BE));
        QCOMPARE(tintColor("#ff8800"), QColor(0xFF8800));
    }

    void sessionPaletteFiltersAndSelects()
    {
        Store store;
        MainWindow w(store, dir.filePath("palette.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        store.select(store.addSession(ws, "alpha", {}));
        const QString beta = store.addSession(ws, "beta", {});
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QTRY_VERIFY_WITH_TIMEOUT(QApplication::focusWidget() && QApplication::focusWidget() != &w, 5000);
        QTest::keyClick(QApplication::focusWidget(), Qt::Key_P, Qt::ControlModifier);
        QTRY_VERIFY(qobject_cast<QLineEdit *>(QApplication::focusWidget()));
        QTest::keyClicks(QApplication::focusWidget(), "bet");
        QTest::keyClick(QApplication::focusWidget(), Qt::Key_Return);
        QCOMPARE(store.selected, beta);
    }

    void sessionPaletteRowRunsOnClick()
    {
        Store store;
        MainWindow w(store, dir.filePath("click.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        store.select(store.addSession(ws, "alpha", {}));
        const QString beta = store.addSession(ws, "beta", {});
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QTRY_VERIFY_WITH_TIMEOUT(QApplication::focusWidget() && QApplication::focusWidget() != &w, 5000);
        QTest::keyClick(QApplication::focusWidget(), Qt::Key_P, Qt::ControlModifier);
        auto *list = w.findChild<QFrame *>("palette")->findChild<QListWidget *>();
        QTRY_VERIFY(list->isVisible() && list->count() > 0);
        QListWidgetItem *row = list->findItems("beta", Qt::MatchContains).value(0);
        QVERIFY(row);
        const QPoint at = list->visualItemRect(row).center();
        const QPointF inWindow(list->viewport()->mapTo(&w, at));
        QMouseEvent press(QEvent::MouseButtonPress, inWindow, list->viewport()->mapToGlobal(QPointF(at)), Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
        QCoreApplication::sendEvent(w.windowHandle(), &press); // as the platform delivers it: the window first
        QVERIFY(list->isVisible());
        QTest::mouseClick(list->viewport(), Qt::LeftButton, {}, at);
        QTRY_COMPARE(store.selected, beta);
    }

    void sessionPaletteKeepsItsSearchFieldWhenNothingMatches()
    {
        Store store;
        MainWindow w(store, dir.filePath("nomatch.json"));
        w.restore({});
        store.select(store.addSession(store.addWorkspace("w"), "alpha", {}));
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        QTRY_VERIFY_WITH_TIMEOUT(QApplication::focusWidget() && QApplication::focusWidget() != &w, 5000);
        QTest::keyClick(QApplication::focusWidget(), Qt::Key_P, Qt::ControlModifier);
        QTRY_VERIFY(qobject_cast<QLineEdit *>(QApplication::focusWidget()));
        auto *search = qobject_cast<QLineEdit *>(QApplication::focusWidget());
        QTest::keyClicks(search, "qws");
        auto *palette = w.findChild<QFrame *>("palette");
        QVERIFY(!palette->findChild<QListWidget *>()->isVisible());
        QTRY_VERIFY(search->height() >= search->sizeHint().height());
        QVERIFY(palette->geometry().contains(palette->mapToParent(search->geometry().bottomRight())));
    }

    void secondLineGrowsItsRowWhereSettingsShowIt()
    {
        Store store;
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, "a", {}), b = store.addSession(ws, "b", {});
        store.addSession(ws, "c", {});
        store.session(a)->infoSpans = {{"step "}, {"2", true}};
        Sidebar tree(store);
        tree.rebuild();
        tree.resize(260, 400);
        tree.show();
        auto height = [&](const QString &id) {
            for (int i = 0; i < tree.topLevelItem(1)->childCount(); ++i)
                if (tree.topLevelItem(1)->child(i)->data(0, SidebarRole::Id).toString() == id)
                    return tree.visualItemRect(tree.topLevelItem(1)->child(i)).height();
            return -1;
        };
        QTRY_COMPARE(height(a), height(b) + QFontMetrics(Sidebar::infoFont(tree.font())).height());
        Settings st = store.settings;
        st.sessionInfoDisplay = QStringLiteral("flagged");
        store.setSettings(st);
        tree.rebuild();
        QTRY_COMPARE(height(a), height(b)); // hidden outside the flagged view, still set
        QCOMPARE(store.session(a)->infoSpans.size(), 2);
    }

    void ciColoursReadOnEveryTintedRow()
    {
        const auto luminance = [](const QColor &c) {
            const auto linear = [](qreal v) { return v <= 0.04045 ? v / 12.92 : std::pow((v + 0.055) / 1.055, 2.4); };
            return 0.2126 * linear(c.redF()) + 0.7152 * linear(c.greenF()) + 0.0722 * linear(c.blueF());
        };
        const auto over = [](const QColor &under, const QColor &layer, qreal a) {
            return QColor::fromRgbF(under.redF() * (1 - a) + layer.redF() * a, under.greenF() * (1 - a) + layer.greenF() * a,
                                    under.blueF() * (1 - a) + layer.blueF() * a);
        };
        for (const bool dark : {true, false}) {
            const QColor window(dark ? 0x202326 : 0xEFF0F1), text(dark ? 0xFCFCFC : 0x232629);
            const auto swatch = [&](const QString &name) {
                for (const TintSwatch &s : Store::tintPalette())
                    if (s.name == name)
                        return QColor(dark ? s.dark : s.light);
                return QColor();
            };
            const QColor active = statusColor(Settings{}, QStringLiteral("active"));
            for (const TintSwatch &t : Store::tintPalette()) {
                const QColor tint(dark ? t.dark : t.light), band = over(window, tint, 0.10);
                // the info line's backgrounds: banded, row-tinted, hovered, selected, and both drifting active stops
                const QList<QColor> unders{band, over(band, tint, 0.09), over(band, text, 0.07), over(over(band, tint, 0.09), tint, 0.20),
                                           over(band, tint, 0.20), over(band, active, 0.20), over(band, tint, 41 / 255.0)};
                for (const QString &ci : {QStringLiteral("red"), QStringLiteral("yellow"), QStringLiteral("green")})
                    for (const QColor &bg : unders) {
                        const QColor c = legibleOn(swatch(ci), {bg}, text);
                        const qreal a = luminance(c), b = luminance(bg);
                        QVERIFY2((std::max(a, b) + 0.05) / (std::min(a, b) + 0.05) >= 4.5, qPrintable(QStringLiteral("%1 on %2 %3").arg(ci, t.name, dark ? "dark" : "light")));
                    }
            }
        }
        QCOMPARE(legibleOn(QColor(0x30D158), {QColor(0x202326)}, QColor(0xFCFCFC)).rgba(), QColor(0x30D158).rgba()); // already legible: untouched
        // mid-gray text on a dark wave: red eases toward white and keeps its hue
        const QColor dark(0x282C34), wave = over(dark, QColor(0xDBD9E6), 0.20);
        const QColor red = legibleOn(QColor(0xFF0000), {dark, wave}, QColor(0xABB2BF));
        QVERIFY(red != QColor(0xABB2BF));
        QVERIFY(red.redF() > red.greenF() && red.redF() > red.blueF());
        for (const QColor &bg : {dark, wave}) {
            const qreal a = luminance(over(bg, red, red.alphaF())), b = luminance(bg);
            QVERIFY((std::max(a, b) + 0.05) / (std::min(a, b) + 0.05) >= 4.5);
        }
    }

    void aClickOnTheShownSessionsCiLineOpensItsPanel()
    {
        Store store;
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, "a", {}), b = store.addSession(ws, "b", {});
        store.addSession(ws, "c", {});
        store.select(b);
        Sidebar tree(store);
        CiLine line(store, &tree, nullptr);
        QTest::qWait(300); // the first poll finds no repository and clears nothing
        const QJsonObject ci{{"branch", "main"}, {"sha", "abc1234"},
                             {"pr", QJsonObject{{"number", 56}, {"title", "Refactor"}, {"url", "https://github.com/o/r/pull/56"},
                                                {"approved", QJsonArray{"alice"}}, {"changesRequested", QJsonArray{}}}},
                             {"runs", QJsonArray{QJsonObject{{"workflow", "build"}, {"state", "failed"}, {"url", "https://github.com/o/r/actions/runs/1"}}}}};
        store.setCi(a, ci, {{QStringLiteral("#56"), true}, {QStringLiteral(" · "), false, false, false, true}, {QStringLiteral("✗ build"), false, false, false, false, QStringLiteral("red")}});
        tree.resize(300, 400);
        tree.show();
        tree.rebuild();
        QVERIFY(QTest::qWaitForWindowExposed(&tree));
        QSignalSpy panel(&tree, &Sidebar::ciPanelRequested);
        const QRect rect = tree.visualItemRect(tree.topLevelItem(1)->child(0));
        const QRect title = tree.titleRect(tree.indexAt(rect.center()), rect);
        const QPoint edge(rect.center().x(), title.bottom() - 4); // the line's top edge
        QTest::mouseClick(tree.viewport(), Qt::LeftButton, {}, edge);
        QCOMPARE(panel.count(), 0);
        QTRY_COMPARE(tree.selectedSessionIds(), QStringList{a});
        QTest::mouseClick(tree.viewport(), Qt::LeftButton, {}, edge);
        QCOMPARE(panel.count(), 1);
        QCOMPARE(panel.at(0).at(0).toString(), a);
        QCOMPARE(tree.selectedSessionIds(), QStringList{a});
        const auto visiblePanel = [] {
            for (QWidget *w : QApplication::topLevelWidgets())
                if (auto *f = qobject_cast<QFrame *>(w); f && f->isVisible() && f->windowFlags().testFlag(Qt::Popup))
                    return f;
            return static_cast<QFrame *>(nullptr);
        };
        QFrame *shown = nullptr;
        QTRY_VERIFY((shown = visiblePanel()));
        QStringList texts;
        for (QLabel *label : shown->findChildren<QLabel *>())
            texts << label->text();
        QVERIFY(texts.first().contains("https://github.com/o/r/pull/56") && texts.first().contains("#56 Refactor"));
        QVERIFY(texts.contains("Approved: alice"));
        QVERIFY(texts.contains("Failed"));
        QVERIFY(texts.last().contains("https://github.com/o/r/actions/runs/1") && texts.last().contains("build"));
        UrlSink sink;
        sink.watched = shown;
        QDesktopServices::setUrlHandler(QStringLiteral("https"), &sink, "open");
        const auto unhandle = qScopeGuard([] { QDesktopServices::unsetUrlHandler(QStringLiteral("https")); });
        Q_EMIT shown->findChildren<QLabel *>().last()->linkActivated(QStringLiteral("https://github.com/o/r/actions/runs/1"));
        QCOMPARE(sink.opened, QList<QUrl>{QUrl(QStringLiteral("https://github.com/o/r/actions/runs/1"))});
        QVERIFY(!sink.watchedVisible); // Wayland launches the browser only once the panel no longer has focus

        QTest::mouseClick(tree.viewport(), Qt::LeftButton, {}, edge);
        QTRY_VERIFY((shown = visiblePanel()));
        const QPointer<QFrame> guard = shown;
        store.setCi(a, {}, {});
        QTRY_VERIFY(guard.isNull() || !guard->isVisible()); // the panel goes with its line
    }

    void foldingAWorkspaceByClickRefreshesItsBandPadding()
    {
        Store store;
        const QString ws = store.addWorkspace("w");
        store.addSession(ws, "a", {});
        Sidebar tree(store);
        tree.rebuild();
        tree.resize(260, 400);
        tree.show();
        QTreeWidgetItem *row = tree.topLevelItem(1);
        const int open = tree.visualItemRect(row).height();
        QTest::mouseClick(tree.viewport(), Qt::LeftButton, {}, tree.visualItemRect(row).center());
        QVERIFY(store.collapsed.contains(ws));
        QTRY_COMPARE(tree.visualItemRect(row).height(), open + Sidebar::groupGap + Sidebar::groupPadding); // its bottom edge now closes the band
    }

    void sessionPillFollowsTheInterfaceTogglesAndHangsThePalette()
    {
        Store store;
        MainWindow w(store, dir.filePath("pill.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        store.select(store.addSession(ws, "alpha", {}));
        store.addSession(ws, "beta", {});
        store.session(store.selected)->context = QStringLiteral("a fairly long context line");
        Q_EMIT store.changed();
        w.resize(1100, 700);
        w.show();
        QAbstractButton *pill = nullptr;
        for (auto *t : w.findChildren<QAbstractButton *>())
            if (t->accessibleName() == QLatin1String("Session switcher"))
                pill = t;
        QVERIFY(pill);
        const int withContext = pill->sizeHint().width();
        Settings st = store.settings;
        st.hiddenInterfaceElements << QStringLiteral("sessionContext");
        store.setSettings(st);
        QVERIFY(pill->sizeHint().width() < withContext);
        pill->click();
        auto *palette = w.findChild<QFrame *>("palette");
        QTRY_VERIFY(palette->isVisible());
        const QRect at(pill->mapTo(&w, QPoint()), pill->size());
        QVERIFY(palette->geometry().top() > at.bottom()); // hung under the pill, as elis's switcher is
        QVERIFY(qAbs(palette->geometry().center().x() - at.center().x()) <= 1);
        QTest::keyClick(palette->findChild<QListWidget *>(), Qt::Key_Escape);
    }

    void flaggedViewLayouts()
    {
        Store store;
        const QString a = store.addWorkspace("alpha"), b = store.addWorkspace("beta"), c = store.addWorkspace("gamma");
        const QString a1 = store.addSession(a, "a1", {}), a2 = store.addSession(a, "a2", {});
        store.addSession(b, "b1", {});
        const QString c1 = store.addSession(c, "c1", {});
        store.setFlag(a1, true), store.setFlag(a2, true), store.setFlag(c1, true);
        Sidebar tree(store);
        tree.setFlaggedView(true);
        QCOMPARE(tree.topLevelItemCount(), 4); // Elis, then flat: one list labelled with the workspace
        QCOMPARE(tree.topLevelItem(1)->data(0, SidebarRole::WorkspaceLabel).toString(), QStringLiteral("alpha"));
        Settings s = store.settings;
        s.flaggedViewLayout = "plain";
        store.setSettings(s);
        tree.rebuild();
        QVERIFY(tree.topLevelItem(1)->data(0, SidebarRole::WorkspaceLabel).toString().isEmpty());
        s.flaggedViewLayout = "tree";
        store.setSettings(s);
        tree.rebuild();
        QCOMPARE(tree.topLevelItemCount(), 3); // Elis; beta holds nothing flagged
        QCOMPARE(tree.topLevelItem(1)->text(0), QStringLiteral("alpha"));
        QCOMPARE(tree.topLevelItem(1)->childCount(), 2);
        QCOMPARE(tree.topLevelItem(2)->child(0)->data(0, SidebarRole::Id).toString(), c1);
        store.collapsed.insert(a); // shared with the ordinary tree
        tree.rebuild();
        QVERIFY(!tree.topLevelItem(1)->isExpanded());
    }

    void clicksNeverDeselectTheShownSession()
    {
        Store store;
        const QString ws = store.addWorkspace("w");
        const QString s1 = store.addSession(ws, "s1", {});
        store.addSession(ws, "s2", {});
        store.select(s1);
        Sidebar tree(store);
        tree.resize(300, 400);
        tree.show();
        tree.rebuild();
        QVERIFY(QTest::qWaitForWindowExposed(&tree));
        auto shown = [&] { return tree.selectedSessionIds() == QStringList{s1}; };
        QVERIFY(shown());
        QTest::mouseClick(tree.viewport(), Qt::LeftButton, {}, QPoint(150, 390));
        QVERIFY(shown());
        QTest::mouseClick(tree.viewport(), Qt::LeftButton, Qt::ControlModifier, tree.visualItemRect(tree.topLevelItem(1)->child(0)).center());
        QVERIFY(shown());
        QTest::mouseClick(tree.viewport(), Qt::LeftButton, {}, tree.visualItemRect(tree.topLevelItem(1)).topLeft() + QPoint(5, 5));
        QVERIFY(shown());
    }

    void aClickOnTheShownFinishedSessionClearsItsStatus()
    {
        Store store;
        const QString ws = store.addWorkspace("w");
        const QString s1 = store.addSession(ws, "s1", {}), s2 = store.addSession(ws, "s2", {});
        store.select(s1);
        Sidebar tree(store);
        QObject::connect(&store, &Store::changed, &tree, &Sidebar::rebuild); // as MainWindow wires it
        QObject::connect(&store, &Store::titleChanged, &tree, &Sidebar::rebuild);
        QObject::connect(&tree, &QTreeWidget::currentItemChanged, &tree, [&](QTreeWidgetItem *item) {
            if (item && item->data(0, SidebarRole::Kind).toInt() == SidebarRole::SessionRow)
                store.select(item->data(0, SidebarRole::Id).toString());
        });
        tree.resize(300, 400);
        tree.show();
        tree.rebuild();
        QVERIFY(QTest::qWaitForWindowExposed(&tree));
        const auto row = [&](int i) { return tree.visualItemRect(tree.topLevelItem(1)->child(i)).center(); };
        store.setStatus(s1, "completed", true);
        store.setUnseen(s1, 2);
        QTest::mouseClick(tree.viewport(), Qt::LeftButton, {}, row(0));
        QCOMPARE(store.session(s1)->status, QStringLiteral("idle"));
        QCOMPARE(store.session(s1)->unseen, 0);
        QCOMPARE(tree.selectedSessionIds(), QStringList{s1});
        store.setStatus(s1, "completed", true);
        QTest::mouseClick(tree.viewport(), Qt::LeftButton, {}, row(1));
        QCOMPARE(store.selected, s2);
        QCOMPARE(store.session(s1)->status, QStringLiteral("idle"));
    }

    void aFinishedSessionsCloseButtonAsksToCloseIt()
    {
        Store store;
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, "a", {}), b = store.addSession(ws, "b", {}), c = store.addSession(ws, "c", {});
        const QString d = store.addSession(ws, "d", {}), e = store.addSession(ws, "e", {}), f = store.addSession(ws, "f", {});
        store.setStatus(a, "completed");
        store.setStatus(b, "active");
        store.setStatus(c, "idle");
        store.setStatus(d, "idle");
        store.setBusy(d, true); // a plain command running
        store.setStatus(e, "completed");
        store.setAgent(e, "claude");
        store.setBusy(e, true); // an agent that finished its turn
        store.session(f)->unseen = 1; // an attention badge
        Sidebar tree(store);
        tree.resize(300, 400);
        tree.show();
        tree.rebuild();
        QVERIFY(QTest::qWaitForWindowExposed(&tree));
        QSignalSpy spy(&tree, &Sidebar::closeRequested);
        auto click = [&](int row) {
            QTest::mouseClick(tree.viewport(), Qt::LeftButton, {},
                              Sidebar::closeButtonRect(tree.visualItemRect(tree.topLevelItem(1)->child(row))).center());
        };
        click(1); // an active session has no close button
        QVERIFY(spy.isEmpty());
        click(0);
        QCOMPARE(spy.size(), 1);
        QCOMPARE(spy.first().first().toString(), a);
        click(2); // an idle session closes too
        QCOMPARE(spy.size(), 2);
        QCOMPARE(spy.last().first().toString(), c);
        click(3); // a running command keeps its row
        click(5); // so does an attention badge
        QCOMPARE(spy.size(), 2);
        click(4);
        QCOMPARE(spy.size(), 3);
        QCOMPARE(spy.last().first().toString(), e);
    }

    void editorsFlagAndMarkLive()
    {
        Store store;
        MainWindow w(store, dir.filePath("editors.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w"), other = store.addWorkspace("o");
        const QString id = store.addSession(ws, "one", {});
        store.select(id);
        w.editFlaggedSessions();
        auto *list = w.findChild<QDialog *>("checklist")->findChild<QListWidget *>();
        QCOMPARE(list->count(), 1);
        QCOMPARE(list->item(0)->text(), QStringLiteral("one : w"));
        emit list->itemActivated(list->item(0));
        QVERIFY(store.session(id)->flagged);
        w.findChild<QDialog *>("checklist")->close();
        QTRY_VERIFY(!w.findChild<QDialog *>("checklist"));
        w.editFocusedWorkspaces();
        list = w.findChild<QDialog *>("checklist")->findChild<QListWidget *>();
        list->item(1)->setCheckState(Qt::Checked);
        QCOMPARE(store.focused, QStringList{other});
        QVERIFY(!store.focusEnabled); // marking never narrows on its own
        QVERIFY(w.findChild<QToolBar *>("titleStrip")->actions().size() > 0);
        bool grid = false;
        for (QAction *act : w.findChild<QToolBar *>("titleStrip")->actions())
            grid |= act->text() == QLatin1String("Dashboard");
        QVERIFY(grid);
    }

    void autoFollowWalksBlockedSessionsOnce()
    {
        Store store;
        MainWindow w(store, dir.filePath("follow.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        const QString a = store.addSession(ws, "a", {}), b = store.addSession(ws, "b", {}), here = store.addSession(ws, "here", {});
        store.select(here);
        store.setStatus(a, "blocked");
        QTest::qWait(5);
        store.setStatus(b, "blocked");
        QVERIFY(w.autoFollowTick(60000).isEmpty()); // disabled by default
        Settings s = store.settings;
        s.autoFollowAttention = "s5";
        store.setSettings(s);
        QCOMPARE(w.autoFollowMs(), 5000);
        QVERIFY(w.autoFollowTick(1000).isEmpty()); // not idle long enough
        QCOMPARE(w.autoFollowTick(6000), a);      // oldest first
        QCOMPARE(w.autoFollowTick(6000), b);
        QVERIFY(w.autoFollowTick(6000).isEmpty()); // each block once
        store.setStatus(a, "idle");
        store.setStatus(a, "blocked"); // a new episode
        store.select(here);
        store.setStatus(here, "active");
        s.autoFollowStayOnActive = true;
        store.setSettings(s);
        QVERIFY(w.autoFollowTick(6000).isEmpty()); // holds while the current session runs
        s.autoFollowStayOnActive = false;
        store.setSettings(s);
        QCOMPARE(w.autoFollowTick(6000), a);
    }

    void scrollbackReadsWhileOutputStreamsKeepTheViewFollowing()
    {
        Store store;
        MainWindow w(store, dir.filePath("follow.json"));
        w.restore({});
        const QString id = store.addSession(store.addWorkspace("w"), {}, {});
        store.select(id);
        w.show();
        QVERIFY(QTest::qWaitForWindowExposed(&w));
        auto call = [&](const QString &cmd, const QJsonObject &args = {}) -> const QJsonObject {
            return dispatch(store, w, {{"cmd", cmd}, {"target", id}, {"args", args}});
        };
        // the shell's pace bounds every wait, so a loaded machine only makes the test slower
        QTRY_VERIFY_WITH_TIMEOUT(!call("session.text")["result"]["text"].toString().trimmed().isEmpty(), 30000);
        QVERIFY(call("session.type", {{"text", "seq 1 100\n"}})["ok"].toBool());
        QTRY_VERIFY_WITH_TIMEOUT(call("session.text")["result"]["text"].toString().contains("\n100\n"), 30000);
        // the clear empties the history the scrollbar still counts, then the rows fill it again
        QVERIFY(call("session.type", {{"text", "clear; for i in $(seq 1 200); do echo row$i; sleep 0.005; done; echo DO''NE\n"}})["ok"].toBool());
        // a phone polls like this; reads land between Konsole receiving output and its scrollbar catching up. The wait
        // lasts while rows keep coming: it fails only after 10 s with no new row
        QString last;
        QElapsedTimer still;
        still.start();
        for (QString tail; !(tail = call("session.text", {{"lines", 5}})["result"]["text"].toString()).contains("DONE"); QTest::qWait(10)) {
            if (tail != last)
                last = tail, still.restart();
            QVERIFY2(still.elapsed() < 10000, qPrintable(QStringLiteral("output stopped at: ") + last));
        }
        QTRY_VERIFY_WITH_TIMEOUT(call("session.text")["result"]["text"].toString().contains("DONE"), 10000);
    }

    void controlCommandsDriveTheWindow()
    {
        Store store;
        MainWindow w(store, dir.filePath("control.json"));
        w.restore({});
        const QString id = store.addSession(store.addWorkspace("w"), {}, {});
        store.select(id);
        w.show();
        w.activateWindow();
        QVERIFY(QTest::qWaitForWindowActive(&w));
        auto call = [&](const QString &cmd, const QString &target = {}, const QJsonObject &args = {}) -> const QJsonObject {
            return dispatch(store, w, {{"cmd", cmd}, {"target", target}, {"args", args}});
        };
        QTRY_VERIFY_WITH_TIMEOUT(!call("session.text", id)["result"]["text"].toString().trimmed().isEmpty(), 5000); // the prompt
        QVERIFY(call("session.type", id, {{"text", "seq 1 200\n"}})["ok"].toBool());
        QTRY_VERIFY_WITH_TIMEOUT(call("session.text", id, {{"lines", 2}})["result"]["text"].toString().contains("200"), 5000);
        const QString all = call("session.text", id, {{"all", true}})["result"]["text"].toString();
        QVERIFY(all.contains("\n1\n") && all.contains("\n200\n")); // scrollback beyond the screen
        QVERIFY(!call("session.text", id)["result"]["text"].toString().contains("\n1\n"));
        QCOMPARE(call("session.copy", id)["error"].toString(), QStringLiteral("no selection"));
        QVERIFY(call("session.selectall", id)["ok"].toBool());
        QVERIFY(call("session.copy", id)["result"]["text"].toString().contains("200"));
        const QJsonObject found = call("session.search", id, {{"text", "199"}})["result"].toObject();
        QVERIFY(found["count"].toInt() >= 1);
        QVERIFY(call("session.search", id, {{"to", "close"}})["ok"].toBool());

        QVERIFY(call("sidebar", {}, {{"mode", "hide"}})["ok"].toBool());
        QVERIFY(!call("tree")["result"]["tree"]["sidebarVisible"].toBool());
        QVERIFY(call("sidebar", {}, {{"mode", "show"}})["ok"].toBool());
        QCOMPARE(call("sidebar.width", {}, {{"sidebarWidth", 300}})["result"]["sidebarWidth"].toDouble(), 300.0);
        QCOMPARE(call("sidebar.width", {}, {})["error"].toString(), QStringLiteral("sidebar.width requires a width in points"));
        QVERIFY(call("filepanel", {}, {{"mode", "show"}})["ok"].toBool());
        QVERIFY(call("tree")["result"]["tree"]["filePanelVisible"].toBool());
        QCOMPARE(call("filepanel.width", {}, {{"filePanelWidth", 280}})["result"]["filePanelWidth"].toInt(), 280);
        QCOMPARE(call("tree")["result"]["tree"]["filePanelWidth"].toInt(), 280);
        QCOMPARE(call("filepanel.width", {}, {})["error"].toString(), QStringLiteral("filepanel.width requires a width in points"));
        QVERIFY(call("filepanel", {}, {{"mode", "hide"}})["ok"].toBool());
        QVERIFY(!call("tree")["result"]["tree"]["filePanelVisible"].toBool());
        QCOMPARE(call("session.focus", id)["error"].toString(), QStringLiteral("session has no split"));
        QVERIFY(call("surface.zoom", {}, {{"mode", "show"}})["ok"].toBool());
        QCOMPARE(call("tree")["result"]["tree"]["zoomedSurface"].toString(), QStringLiteral("surface:%1:left").arg(id));
        QVERIFY(call("surface.zoom", {}, {{"mode", "hide"}})["ok"].toBool());
        QVERIFY(!call("tree")["result"]["tree"].toObject().contains("zoomedSurface"));
        QCOMPARE(call("surface.zoom", "quick")["error"].toString(), QStringLiteral("surface not available: quick"));
        QVERIFY(call("session.context", id, {{"mode", "set"}, {"text", "issue 7"}})["ok"].toBool());

        // pick: the palette, picked by Enter
        const QString pick = call("pick.open", {}, {{"items", QJsonArray{QJsonObject{{"id", "a"}, {"label", "alpha"}}, QJsonObject{{"id", "b"}, {"label", "beta"}}}},
                                                    {"query", "bet"}})["result"]["id"].toString();
        QCOMPARE(call("tree")["result"]["tree"]["pickPending"].toString(), pick);
        QCOMPARE(call("pick.result", pick)["result"]["pick"]["result"].toString(), QStringLiteral("pending"));
        QTest::keyClick(QApplication::focusWidget(), Qt::Key_Return);
        const QJsonObject picked = call("pick.result", pick)["result"]["pick"].toObject();
        QCOMPARE(picked["id"].toString(), QStringLiteral("b"));
        QCOMPARE(picked["index"].toInt(), 1);
        const QString cancelled = call("pick.open", {}, {{"items", QJsonArray{QJsonObject{{"id", "a"}, {"label", "alpha"}}}}})["result"]["id"].toString();
        QVERIFY(call("pick.cancel", cancelled)["ok"].toBool());
        QCOMPARE(call("pick.result", cancelled)["result"]["pick"]["result"].toString(), QStringLiteral("cancelled"));

        // ask: a dialog whose button answers
        const QJsonObject askArgs{{"title", "Ship it?"}, {"buttons", QJsonArray{QJsonObject{{"id", "yes"}, {"label", "Yes"}}, QJsonObject{{"id", "no"}, {"label", "No"}}}}};
        const QString ask = call("ask.open", id, askArgs)["result"]["id"].toString();
        QCOMPARE(call("tree")["result"]["tree"]["workspaces"][0]["sessions"][0]["ask"]["id"].toString(), ask);
        QCOMPARE(call("ask.open", id, askArgs)["error"].toString(), QStringLiteral("ask already pending"));
        QPushButton *yes = nullptr;
        for (QPushButton *b : w.findChild<QDialog *>("ask")->findChildren<QPushButton *>())
            if (b->text() == QLatin1String("Yes"))
                yes = b;
        yes->click();
        const QJsonObject answer = call("ask.result", ask)["result"]["ask"].toObject();
        QCOMPARE(answer["result"].toString(), QStringLiteral("answered"));
        QCOMPARE(answer["id"].toString(), QStringLiteral("yes"));
        // clicking an explicit --cancel button or a generated Cancel resolves as {"result":"escaped"}
        QJsonObject askWithCancel = askArgs;
        askWithCancel.insert("cancelButton", "no");
        const QString askEsc = call("ask.open", id, askWithCancel)["result"]["id"].toString();
        for (QPushButton *b : w.findChild<QDialog *>("ask")->findChildren<QPushButton *>())
            if (b->text().remove(QLatin1Char('&')) == QLatin1String("No"))
                b->click();
        QCOMPARE(call("ask.result", askEsc)["result"]["ask"].toObject(), (QJsonObject{{"result", "escaped"}}));
        const QString formEsc = call("ask.open", id, {{"title", "Name?"}, {"input", "line"}, {"value", "x"}})["result"]["id"].toString();
        for (QPushButton *b : w.findChild<QDialog *>("ask")->findChildren<QPushButton *>())
            if (b->text().remove(QLatin1Char('&')) == QLatin1String("Cancel"))
                b->click();
        QCOMPARE(call("ask.result", formEsc)["result"]["ask"].toObject(), (QJsonObject{{"result", "escaped"}}));
        const QString form = call("ask.open", id, {{"title", "Name?"}, {"input", "line"}, {"value", "x"}})["result"]["id"].toString();
        QVERIFY(call("ask.cancel", form)["ok"].toBool());
        QCOMPARE(call("ask.result", form)["result"]["ask"]["result"].toString(), QStringLiteral("cancelled"));
        QCOMPARE(call("ask.result", "nope")["error"].toString(), QStringLiteral("unknown ask: nope"));

        // msg: panes have ids, and the event lands in the window's stream
        const QStringList panes = w.paneIds(id);
        QCOMPARE(panes.size(), 1);
        QSignalSpy events(w.events(), &EventSource::event);
        QVERIFY(call("msg.send", {}, {{"body", "hello"}, {"recipients", QJsonArray{id + ":left"}}})["ok"].toBool());
        QCOMPARE(events.last().first().toJsonObject()["kind"].toString(), QStringLiteral("message"));
        QCOMPARE(call("msg.read", {}, {{"identity", id + ":" + panes[0]}, {"ack", true}})["result"]["messages"][0]["body"].toString(), QStringLiteral("hello"));
    }

    void footerPlusAddsASessionToTheCurrentWorkspace()
    {
        Store store;
        MainWindow w(store, dir.filePath("plus.json"));
        w.restore({});
        const QString ws = store.addWorkspace("w");
        store.select(store.addSession(ws, {}, {}));
        QToolButton *plus = nullptr;
        for (QToolButton *b : w.findChildren<QToolButton *>())
            if (b->accessibleName() == QLatin1String("New Session"))
                plus = b;
        QVERIFY(plus && !plus->menu());
        const int before = store.workspace(ws)->sessions.size();
        plus->click();
        QCOMPARE(store.workspace(ws)->sessions.size(), before + 1);
    }

    void helpMenuHoldsOnlyTheDocs()
    {
        Store store;
        MainWindow w(store, dir.filePath("help.json"));
        w.restore({});
        QStringList help;
        for (QAction *menu : w.menuBar()->actions())
            if (menu->text() == QLatin1String("&Help"))
                for (QAction *a : menu->menu()->actions())
                    if (!a->isSeparator())
                        help << a->text();
        QCOMPARE(help, QStringList{"Developer Documentation…"}); // the installers run on install or update instead
        QVERIFY(!bundled("agent-status").isEmpty() && !bundled("skill/elis").isEmpty());
        QCOMPARE(extrasFingerprint(), extrasFingerprint());
        QCOMPARE(extrasFingerprint().size(), 64);
    }
};

QTEST_MAIN(TestUi)
#include "test_ui.moc"
