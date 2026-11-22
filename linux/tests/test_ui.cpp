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
#include <KPageDialog>
#include <QLineEdit>
#include <QListWidget>
#include <QDialog>
#include <QFrame>
#include <QLabel>
#include <QMenu>
#include <QMenuBar>
#include <QTimer>
#include <QElapsedTimer>
#include <QSet>
#include <algorithm>
#include <numeric>
#include <memory>
#include <signal.h>
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
#include "konsoleprivate.h"

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

// a library whose chat chose `choice` ("" for none), run by `standIn` in place of its binary; `detected` agents are
// found on a PATH that leads with a directory of its own
struct AssistantHost {
    QTemporaryDir state;
    DetectedLaunchers launchers;
    std::unique_ptr<WindowLibrary> lib;
    std::unique_ptr<AssistantRunner> runner;
    static QString path() { return QStringLiteral("/nonexistent-detected:") + qEnvironmentVariable("PATH"); }
    explicit AssistantHost(const QByteArray &standIn, const QByteArray &choice = "claude", bool detected = true)
    {
        QDir().mkpath(state.filePath("assistant"));
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
        const QString moved = pairLinkWithHost(link, QStringLiteral(" pc.tail1234.ts.net "));
        QCOMPARE(moved, QStringLiteral("elis://pair?h=pc.tail1234.ts.net&p=8765&t=tok-en_&f=ab12&n=my%20pc"));
        QCOMPARE(pairLinkWithHost(link, QString()), link); // no choice keeps what serve printed
        const QImage code = qrImage(link);
        QCOMPARE(code.width(), code.height());
        QVERIFY(code.width() >= 21 + 8);                       // the smallest QR plus a four-module quiet zone
        QCOMPARE(code.pixel(0, 0), qRgb(255, 255, 255));        // light border on any theme
        QCOMPARE(code.pixel(4, 4), qRgb(0, 0, 0));              // the top-left finder starts inside it
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
        QVERIFY(!run("session.overlay.open", {{"command", "sleep 30; exit 3"}, {"sizePercent", 50}}).contains("error"));
        QCOMPARE(run("session.overlay.open", {{"command", "true"}})["error"].toString(), QStringLiteral("overlay already open"));
        QTRY_VERIFY(QApplication::focusWidget() && QApplication::focusWidget() != term); // the cover owns the keyboard
        QCOMPARE(w.sessionExtras(id)["overlaySizePercent"].toInt(), 50);
        QCOMPARE(run("session.overlay.result")["error"].toString(), QStringLiteral("overlay still running"));
        QCOMPARE(run("session.overlay.toggle")["text"].toString(), QStringLiteral("hidden"));
        QCOMPARE(w.sessionExtras(id)["hiddenOverlays"].toArray().first().toString(), QStringLiteral("session"));
        QTRY_COMPARE(QApplication::focusWidget(), term);
        QCOMPARE(w.namedAction("toggle_overlay")->text(), QStringLiteral("Show Overlays"));
        QVERIFY(!run("session.overlay.close").contains("error"));
        QVERIFY(!w.sessionExtras(id)["overlay"].toBool());

        QVERIFY(!run("session.overlay.open", {{"command", "exit 3"}}).contains("error"));
        QTRY_VERIFY_WITH_TIMEOUT(!w.sessionExtras(id)["overlay"].toBool(), 5000);
        QCOMPARE(run("session.overlay.result")["exitCode"].toInt(), 3);
        QTRY_COMPARE(QApplication::focusWidget(), term);

        // the HUD takes no input: typing still reaches the terminal under it
        QVERIFY(!run("session.hud.open", {{"message", "building"}, {"spinner", "dot"}, {"hideAfter", 1}}).contains("error"));
        QCOMPARE(w.sessionExtras(id)["hud"].toObject()["message"].toString(), QStringLiteral("building"));
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
        QVERIFY(!w.chromeState()["filePanel"].toObject()["visible"].toBool());
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
        QVERIFY(w.chromeState()["filePanel"].toObject()["visible"].toBool());
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
        QTreeWidgetItem *wsItem = tree->topLevelItem(0), *rowA = wsItem->child(0), *rowB = wsItem->child(1);
        store.select(b);
        store.setStatus(a, "blocked");
        QCOMPARE(tree->topLevelItem(0), wsItem);
        QCOMPARE(wsItem->child(0), rowA);
        QCOMPARE(wsItem->child(1), rowB);
        QVERIFY(rowB->isSelected() && !rowA->isSelected());
        QCOMPARE(rowA->data(0, SidebarRole::Status).toString(), QStringLiteral("blocked"));
        store.addSession(ws, {}, {}); // a new row is a structural change
        QCOMPARE(tree->topLevelItem(0)->childCount(), 3);
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
        auto *row = tree.topLevelItem(0);
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
        QCOMPARE(tree->topLevelItemCount(), 2);
        store.focusWorkspace(a, "add");
        QVERIFY(filter->isEnabled());
        QCOMPARE(tree->topLevelItemCount(), 2);
        filter->click();
        QVERIFY(store.focusEnabled);
        QCOMPARE(tree->topLevelItemCount(), 1);
        QVERIFY(tree->topLevelItem(0)->data(0, SidebarRole::Focused).toBool());
        store.setTint(a, "red");
        QCOMPARE(tree->topLevelItem(0)->data(0, SidebarRole::TintColor).toString(), QStringLiteral("red"));
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
        QTreeWidgetItem *row = tree->topLevelItem(0)->child(0);
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
            for (int i = 0; i < tree.topLevelItem(0)->childCount(); ++i)
                if (tree.topLevelItem(0)->child(i)->data(0, SidebarRole::Id).toString() == id)
                    return tree.visualItemRect(tree.topLevelItem(0)->child(i)).height();
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

    void aClickOnTheCiLineOpensItsPanelAndSelectsNothing()
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
        const QRect rect = tree.visualItemRect(tree.topLevelItem(0)->child(0));
        const QRect title = tree.titleRect(tree.indexAt(rect.center()), rect);
        QTest::mouseClick(tree.viewport(), Qt::LeftButton, {}, QPoint(rect.center().x(), title.bottom() - 4)); // the line's top edge
        QCOMPARE(panel.count(), 1);
        QCOMPARE(panel.at(0).at(0).toString(), a);
        QCOMPARE(tree.selectedSessionIds(), QStringList{b});
        QFrame *shown = nullptr;
        QTRY_VERIFY((shown = [] {
            for (QWidget *w : QApplication::topLevelWidgets())
                if (auto *f = qobject_cast<QFrame *>(w); f && f->isVisible() && f->windowFlags().testFlag(Qt::Popup))
                    return f;
            return static_cast<QFrame *>(nullptr);
        }()));
        QStringList texts;
        for (QLabel *label : shown->findChildren<QLabel *>())
            texts << label->text();
        QVERIFY(texts.first().contains("https://github.com/o/r/pull/56") && texts.first().contains("#56 Refactor"));
        QVERIFY(texts.contains("Approved: alice"));
        QVERIFY(texts.contains("Failed"));
        QVERIFY(texts.last().contains("https://github.com/o/r/actions/runs/1") && texts.last().contains("build"));
        const QPointer<QFrame> guard = shown;
        store.setCi(a, {}, {});
        QTRY_VERIFY(guard.isNull() || !guard->isVisible()); // the panel goes with its line

        QTest::mouseClick(tree.viewport(), Qt::LeftButton, {}, QPoint(rect.center().x(), title.center().y()));
        QCOMPARE(panel.count(), 1);
        QTRY_COMPARE(tree.selectedSessionIds(), QStringList{a});
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
        QTreeWidgetItem *row = tree.topLevelItem(0);
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
        QCOMPARE(tree.topLevelItemCount(), 3); // flat: one list labelled with the workspace
        QCOMPARE(tree.topLevelItem(0)->data(0, SidebarRole::WorkspaceLabel).toString(), QStringLiteral("alpha"));
        Settings s = store.settings;
        s.flaggedViewLayout = "plain";
        store.setSettings(s);
        tree.rebuild();
        QVERIFY(tree.topLevelItem(0)->data(0, SidebarRole::WorkspaceLabel).toString().isEmpty());
        s.flaggedViewLayout = "tree";
        store.setSettings(s);
        tree.rebuild();
        QCOMPARE(tree.topLevelItemCount(), 2); // beta holds nothing flagged
        QCOMPARE(tree.topLevelItem(0)->text(0), QStringLiteral("alpha"));
        QCOMPARE(tree.topLevelItem(0)->childCount(), 2);
        QCOMPARE(tree.topLevelItem(1)->child(0)->data(0, SidebarRole::Id).toString(), c1);
        store.collapsed.insert(a); // shared with the ordinary tree
        tree.rebuild();
        QVERIFY(!tree.topLevelItem(0)->isExpanded());
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
        QTest::mouseClick(tree.viewport(), Qt::LeftButton, Qt::ControlModifier, tree.visualItemRect(tree.topLevelItem(0)->child(0)).center());
        QVERIFY(shown());
        QTest::mouseClick(tree.viewport(), Qt::LeftButton, {}, tree.visualItemRect(tree.topLevelItem(0)).topLeft() + QPoint(5, 5));
        QVERIFY(shown());
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
                              Sidebar::closeButtonRect(tree.visualItemRect(tree.topLevelItem(0)->child(row))).center());
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
