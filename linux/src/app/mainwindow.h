#pragma once

#include "assistant.h"
#include "control.h"
#include "keymap.h"

#include <QDateTime>
#include <QElapsedTimer>
#include <QSet>
#include <QHash>
#include <QMainWindow>
#include <QPointer>
#include <QTimer>

class QDialog;
class QFrame;
class QKeyEvent;
class QLabel;
class QMenu;
class QSplitter;
class QStackedLayout;
class QStackedWidget;
class QToolButton;
class Sidebar;
class Store;
struct Session;
class TerminalInterface;
class PartBridge;
namespace KParts { class ReadOnlyPart; }

QWidget *terminalDisplay(KParts::ReadOnlyPart *part); // the part's Konsole::TerminalDisplay
void retirePart(KParts::ReadOnlyPart *part); // drops a part whose pane lives on in another one
void zoomFontTo(QWidget *display, double points);
Qt::KeyboardModifiers linkClickModifiers(Qt::KeyboardModifiers modifiers, bool tracking, bool release);

class MainWindow : public QMainWindow, public Terminals
{
    Q_OBJECT
public:
    MainWindow(Store &store, const QString &statePath);
    ~MainWindow() override;
    void restore(const QJsonObject &window); // one terminal per stored session, plus saved geometry
    class WindowLibrary *library = nullptr; // null for a lone window (tests)
    QString windowId;

    bool type(const QString &sessionId, const QString &pane, const QString &text, QString *error) override;
    // runs then once no plain pane has a paced Return still to send, so a control reply follows the Return as zmx's does
    static void whenTyped(QObject *context, const std::function<void()> &then);
    // sends a dispatched request's response as the control socket does: a deferred one's job run on a worker, after
    // whenTyped; nothing once context is gone
    static void answer(QObject *context, const QJsonObject &response, const std::function<void(const QJsonObject &)> &send);
    QString text(const QString &sessionId, const QString &pane, bool scrollback, QString *error) override;
    QSize gridSize(const QString &sessionId, const QString &pane) override;
    bool setGrid(const QString &sessionId, const QString &pane, const QSize &grid, QString *error) override;
    bool scroll(const QString &sessionId, const QString &pane, int lines, QString *error) override;
    QStringList paneIds(const QString &sessionId) const override;
    Backing backing(const QString &sessionId, const QString &pane) const override;
    bool holdsPane(const QString &paneId) const; // one of its sessions' panes has this ELIS_PANE_ID
    void emitEvent(const QString &kind, const QString &sessionId, const QJsonObject &payload) override;
    QJsonObject info(const QString &sessionId) override;

    bool save();
    bool saveNow(QString *error) override;
    QStringList foregroundArgv(const QString &sessionId, const QString &pane) override;
    bool isOwnShortcut(QKeyEvent *event) const;
    void paneTitle(const QString &id, QObject *part, const QString &title); // an OSC 0/2 title, or the caption
    void setSocketStatus(bool ok, const QString &error);
    QStringList availableLaunchers() const; // the app-wide DetectedLaunchers
    bool filePanel(const QString &mode, int width, QString *error) override;
    QJsonObject chromeState() const override;
    QJsonObject sessionExtras(const QString &sessionId) const override;
    // overlay.cpp: a program in a temporary terminal over the session (pane "") or one pane, and the HUD
    bool openOverlay(const QString &id, const QString &pane, const QString &command, const QString &cwd, int sizePercent, double width,
                     double height, const QString &color, bool wait, std::function<void()> onClose, QString *error);
    bool openHud(const QString &id, const QJsonObject &spec, QString *error);
    bool panePlan(const QString &sessionId, const QString &pane, PanePlan *out, QString *error) override;
    bool font(const QString &sessionId, const QString &pane, const QString &op, QString *error) override;
    bool appCommand(const QString &cmd, const QString &sessionId, const QJsonObject &args, QJsonObject *result, QString *error) override;

    // config.cpp: keymap.conf, hooks.conf, appearance, the theme picker
    QString configDir() const;
    void loadConfig(); // reads both files, writing the commented starters where they are missing
    int reloadKeymap();
    int reloadHooks();
    const Keymap &keymap() const { return m_keymap; }
    class HookRunner *hooks() const { return m_hooks; }
    class EventSource *events() const { return m_events; }
    QStringList themes() const; // Konsole colour schemes: the bundled ones and the user's
    QJsonObject terminalTheme() const; // the active scheme as {background, foreground, dark, palette[16]}
    void selectTheme();
    void previewTheme(const QString &name); // "" ends the preview
    void runCustomCommand(const QString &name, const QString &sessionId);
    void showSettings();
    void applySettings(); // live: appearance, chrome visibility, sidebar
    QAction *namedAction(const QString &name) const { return m_actions.value(name); }
    // attention.cpp
    void editFlaggedSessions();
    void editFocusedWorkspaces();
    qint64 autoFollowMs() const; // 0 = disabled
    QString autoFollowTick(qint64 idleMs); // selects the oldest blocked session not yet shown once idle long enough; its id
    // the Elis row: its chat replaces the shown session, which leaves no session selected until one is picked
    void showAssistant();
    bool assistantShown() const { return m_assistantShown; }
    QList<Assistant::Window> assistantWindows() const; // the library's, else this window alone
    QStringList assistantProviders() const;
    class DetectedLaunchers *assistantLaunchers() const; // the library's, whose detection the provider list waits for
    QJsonObject assistantRequest(const QJsonObject &request); // an assistant.* request, as the control socket sends it
    void goToSession(const QString &id);                      // in whichever window holds it, raised

protected:
    void closeEvent(QCloseEvent *event) override;
    void showEvent(QShowEvent *event) override;
    void paintEvent(QPaintEvent *event) override;
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    void writeTyped(KParts::ReadOnlyPart *part, const QString &text);
    QHash<QObject *, QStringList> m_typed; // a plain pane with a paced Return pending -> the texts typed behind it, in order
    static inline int s_returnsPending = 0;
    QAction *action(const QString &name, const QString &text, const QString &icon, const QKeySequence &key, std::function<void()> slot);
    void createMenus();
    void createTerminal(const QString &id);
    // takeover: a fresh attach of a live pane's daemon that never creates one, claiming the lead or taking it if unowned
    KParts::ReadOnlyPart *spawnPart(const QString &id, const QString &pane, const QString &cwd, const QString &command, QWidget *parent,
                                    const QStringList &env = {}, bool takeover = false, bool claim = false);
    struct Overlay {
        QPointer<QWidget> frame;
        KParts::ReadOnlyPart *part = nullptr;
        QPointer<QWidget> page; // a PageOverlay in place of the part (pageoverlay.h)
        QString pageID;
        bool chromeless = false;
        bool themedFrame = false; // a page's frame paints the terminal background behind it
        QString command, codeFile;
        int sizePercent = 0; // 0 = full
        double width = 0, height = 0; // points overriding the percent per axis
        bool hidden = false;
        std::function<void()> onClose;
    };
    QHash<QString, Overlay> m_overlays;   // "<session>|session|left|right" -> the running cover
    QHash<QString, int> m_overlayResults; // same key -> the exit status of the last program that closed there
    QHash<QString, QPointer<QWidget>> m_huds;
    bool overlayCommand(const QString &cmd, const QString &id, const QJsonObject &args, QJsonObject *result, QString *error);
    bool openPage(const QString &id, const QString &pane, const QJsonObject &args, QJsonObject *result, QString *error);
    void refreshPageThemes(); // every open page and its frame take the current terminal theme
    // a file page's bridge message, run from the slot the page holds now; reply gets its result or error once
    void pageRequest(QWidget *page, const QJsonObject &body, const std::function<void(const QJsonValue &, const QString &)> &reply);
    QWidget *coverWidget(const QString &id) const; // what takes the keyboard: a shown page or program, else the main pane
    bool closeFrontCover(const QString &id);       // the HUD or shown session cover, else the focused pane's; false with none
    bool pageCovers(const QString &id, const QString &pane) const; // a shown page hides that pane's terminal
    void overlayExited(const QString &key, KParts::ReadOnlyPart *part);
    void closeOverlay(const QString &key);
    bool closeHud(const QString &id);
    void layoutOverlays(const QString &id);
    void forgetOverlays(const QString &id);
    void toggleOverlays();
    bool hasHideableOverlay(const QString &id, bool *anyShown) const;
    QWidget *paneWidget(const QString &id, const QString &pane) const;
    QRect overlayTarget(const QString &id, const QString &pane) const;
    // dashboard.cpp
    struct DashCell {
        QString ref; // "<session>:left|right"
        QPointer<QWidget> widget;
        QPointer<QSplitter> home; // the session's splitter it returns to, at index
        int index = 0;
        bool wasVisible = true;
        QFrame *frame = nullptr;
        QLabel *chip = nullptr;
        double font = 0; // the pane's size before the grid's transient one
    };
    QWidget *m_dashboard = nullptr;
    QList<DashCell> m_dashCells;
    int m_dashHighlight = 0;
    QString m_dashFontMode;
    double m_dashFontSize = 0;
    QTimer m_dashBlink;
    bool m_dashBlinkOn = false;
    bool openDashboard(const QStringList &cells, const QString &fontMode, double fontSize, QString *error);
    void closeDashboard();
    void toggleDashboard();
    void activateDashboardCell(int i);
    void refreshDashboard();
    void dashboardForget(const QString &id);
    bool dashboardEvent(QObject *watched, QEvent *event);
    bool dashboardCommand(const QJsonObject &args, QJsonObject *result, QString *error);
    QJsonObject dashboardState() const;
    void applyLayout(const QString &id);
    void trackBlocked(const QString &id, const QString &status);
    // controlui.cpp
    bool uiCommand(const QString &cmd, const QString &id, const QJsonObject &args, QJsonObject *result, QString *error, bool *handled);
    bool pickCommand(const QString &cmd, const QString &id, const QJsonObject &args, QJsonObject *result, QString *error);
    bool askCommand(const QString &cmd, const QString &id, const QJsonObject &args, QJsonObject *result, QString *error);
    void finishAsk(const QString &id, const QJsonObject &outcome);
    KParts::ReadOnlyPart *panePart(const QString &id, const QString &pane) const; // left | right
    QJsonObject controlExtras(const QString &id) const; // splitFocused, ask
    QJsonObject controlChrome() const;                  // sidebarWidth, zoomedSurface, pickPending, askPending
    QHash<QString, bool> m_splitFocused;
    QHash<QString, QSize> m_phoneGrids; // "session/pane" → the grid a phone set (session grid)
    bool hasPhoneGrid(const QString &id) const;
    void restoreTerminalSize(const QString &id);
    QString m_zoomSurface, m_pickId;
    struct Ask {
        QPointer<QDialog> dialog;
        QString session, pane;
        bool gui = false;
    };
    QHash<QString, Ask> m_asks;
    QLabel *m_context = nullptr;
    QHash<QString, QString> m_shellTitle;   // session -> the last title its shell's prompt set
    QHash<QString, int> m_titlePid;          // session -> the foreground pid that set or named its title
    QHash<QString, QString> m_commandTitle; // session -> the command name the sampler gave it, cleared when it ends
    QHash<QString, qint64> m_blockedSince; // when each blocked session entered blocked
    QSet<QString> m_followShown;           // blocks already shown once this episode
    QElapsedTimer m_idle;                  // since the last key or click in this window
    QTimer m_followTimer;
    void syncDashboardButton();
    void paneExited(const QString &id, KParts::ReadOnlyPart *part);
    void leadReport(const QString &id, KParts::ReadOnlyPart *part, const QString &title); // a zmx role report
    void takeOver(const QString &id, KParts::ReadOnlyPart *part, bool claim); // a fresh attach in the pane's slot
    void captionFromProgram(const QString &id); // the main part's caption is its program's title
    void swapPanes(const QString &id);
    void newCompanion(const QString &parentId);
    void duplicateCompanion(const QString &id);
    void recordFontSizes(Session *s) const;
    void focusPane(bool right);
    void toggleZoom();
    void showSelected();
    void sidebarMenu(const QPoint &pos);
    void launcherMenu(const QString &workspaceId, const QPoint &globalPos);
    void launch(const QString &launcherId, const QString &workspaceId);
    QString currentWorkspace();
    void newSession(const QString &workspaceId);
    void newWorkspace();
    QString askName(const QString &title, bool *ok);
    void openDirectory();
    void closeSessions(const QStringList &ids);
    void deleteWorkspace(const QString &id);
    void fillMoveMenu(QMenu *menu, const QStringList &ids);
    void fillTintMenu(QMenu *menu, const QStringList &ids); // ids: sessions, or one workspace
    void go(const QString &direction);
    void profileDialog(const char *slot);
    void editConfigFile(const QString &path);
    void applyAppearance(KParts::ReadOnlyPart *part);
    void applyGlass(); // the window's see-through surfaces and the blur behind them
    void watchTerminalNotifications(KParts::ReadOnlyPart *part, PartBridge *bridge);
    void stripPartShortcuts();
    void notifyFailure(const QString &title, const QString &body);
    void playSound(const QString &name) const; // a freedesktop sound-theme name; "" plays nothing
    void customCommandPalette();
    QObject *sessionOf(KParts::ReadOnlyPart *part) const;
    QList<KParts::ReadOnlyPart *> parts() const;
    QMap<QString, QStringList> m_defaultKeys; // each built-in's shipped shortcuts, portable text
    Keymap m_keymap;
    QList<QAction *> m_customActions;
    class HookRunner *m_hooks;
    class EventSource *m_events;
    mutable QList<QKeyCombination> m_chordPrefix; // a leader sequence in progress
    QString m_previewTheme, m_appliedAppearance;
    QLabel *m_workspaceLabel;
    QHash<QString, QAction *> m_chrome; // interface element -> its title-strip action
    QHash<QString, QWidget *> m_footer; // interface element -> its footer button
    void sampleAgents();
    TerminalInterface *terminal(const QString &id) const;
    QString liveCwd(const QString &id) const;
    // the focused pane's agent's cwd (session.status --cwd), else `fallback`: what the CI line and file panel show
    QString workingCwd(const Session &s, const QString &fallback) const;
    QString panelRoot() const;
    void prime(QWidget *page, QWidget *pane = nullptr); // pane: mark that one terminal as sized, not the whole page
    QObject *konsoleSession(const QString &id);

    Store &m_store;
    QString m_statePath;
    QSplitter *m_split;
    QWidget *m_sidebarPanel;
    Sidebar *m_tree;
    QToolButton *m_flagButton;
    QToolButton *m_filterButton;
    void syncChrome();
    QAction *m_sidebarAction;
    QAction *m_recentAction; // the session pill's
    QWidget *m_pill;
    QLabel *m_title;
    QStackedWidget *m_stack;
    QWidget *m_empty;
    class AssistantView *m_assistantView;
    bool m_assistantShown = false;
    QWidget *m_wash; // a TintWash over the terminal
    QHash<QString, QAction *> m_actions;
    struct Panes {
        QWidget *view = nullptr;          // the session's page in m_stack
        QStackedLayout *layers = nullptr; // the split view; overlays will stack above it
        QSplitter *split = nullptr;
        KParts::ReadOnlyPart *main = nullptr, *right = nullptr;
    };
    QHash<QString, Panes> m_panes;
    QWidget *m_strip = nullptr;
    class FilePanel *m_filePanel = nullptr;
    int m_filePanelWidth = 240; // elis's default; clamped to 160..560
    void applyFilePanelWidth();
    class Palette *m_palette = nullptr;
    bool m_zoomed = false;
    QString m_shownId;
    QHash<QString, QDateTime> m_respawned;
    bool m_zoomRestoreSidebar = true, m_zoomRestoreMenu = true;
    bool m_dashHidFiles = false; // the dashboard hid the file panel and gives it back on close
    QHash<QString, QPointer<QObject>> m_sessions;
    QStringList m_denylist; // restore-denylist.conf, read at launch
    void replay(const QString &id, KParts::ReadOnlyPart *part, bool split);
    QTimer m_saveTimer, m_agentTimer;
    bool m_quitting = false;
};

// Receives the Konsole part's string-only signals for one session.
class PartBridge : public QObject
{
    Q_OBJECT
public:
    PartBridge(MainWindow *window, Store &store, const QString &id, QObject *parent);
    QPointer<QObject> session; // Konsole's Session, for forwarding the OSC 777 forms we do not take

public Q_SLOTS:
    void currentDirectoryChanged(const QString &dir);
    void overrideShortcut(QKeyEvent *event, bool &override);
    void sessionAttribute(int what, const QString &text); // OSC 9 from the emulation
    void osc777(const QStringList &params);
    void ptyData(const char *data, int length); // Konsole::Pty's raw output, for zmx role reports

private:
    MainWindow *m_window;
    Store &m_store;
    QString m_id;
    QByteArray m_reportCarry;
};
