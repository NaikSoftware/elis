#pragma once

// A page overlay (session.overlay.open --html/--url): a web view under an identity strip, every navigation judged by
// ElisCore's HtmlNavigationPolicy through the bridge. Qt WebEngine only; the slot code in overlay.cpp owns placement.
#include "pagecontent.h"

#include <QJsonObject>
#include <QPointer>
#include <QUrl>
#include <QWidget>

class QLabel;
class QToolButton;
class QWebEngineProfile;
class QWebEngineView;
class PageScheme;
class PolicyPage;
class TextPageHost;

class PageOverlay : public QWidget
{
    Q_OBJECT
public:
    // source {"kind":"file","path","cwd"?} | {"kind":"url","url"} | {"kind":"image|markdown|text|document","path"}, a built
    // page, with what the open check found: a markdown page's link grant "links", a text page's "line", "log",
    // "language" and "diff"; flags {navigation,javascript,chromeless,persistent,browse};
    // theme: the terminal's {background, foreground, dark, palette}, which every page reads and a file page wears
    PageOverlay(const QJsonObject &source, const QJsonObject &flags, const QString &pageID, const QJsonObject &theme, QWidget *parent = nullptr);
    ~PageOverlay() override;

    QString pageID() const { return m_pageID; }
    QJsonObject source() const { return m_source; }
    QJsonObject flags() const { return m_flags; }
    QWebEngineView *view() const { return m_view; }
    // ControlHtmlOverlayNode's page fields: source, state, error, page, title, history, flags, zoom, id
    QJsonObject readBack() const;
    QString identity() const; // what the strip names: the file shown or the origin
    void reload(bool current);
    bool navigate(const QString &to, QString *error); // back | forward | browser | finder
    QString pendingPrompt() const { return m_promptUrl.toString(); }
    void answerPrompt(bool open);
    void applyTheme(const QJsonObject &theme); // a page Elis styles wears it and redraws; any other gets it at its next load
    // session.overlay.search|follow|wrap|changes|files on a text page, the action as the dispatcher shaped it
    bool textCommand(const QJsonObject &action, const QString &sessionId, QJsonObject *result, QString *error);

    static double zoom(); // the one app-wide factor every page shows at
    static void setZoom(double factor);
    static bool stepZoom(const QString &fontAction); // increase_font_size:1 | decrease_font_size:1 | reset_font_size
    // the saved store every --persistent page shares, built on first use: why it cannot be used, empty when it can
    static QString persistentStoreFailure();
    static bool clearPersistentStore(const QString &target, const QJsonObject &args, QString *error); // browser.clear
    static void releasePersistentStore(); // at quit, after every page and before WebEngine shuts down
    // where Open in Browser goes; tests replace it
    static inline std::function<void(const QUrl &)> openExternally;
    // shows a file or folder selected in the file manager, as Finder's reveal (Show in Folder, a clicked path's reveal)
    static void reveal(const QString &path);
    static inline std::function<void(const QString &)> revealExternally; // tests replace it

Q_SIGNALS:
    void closeRequested(); // the strip's close button or the page's window.close()
    void changed();        // load state, address, title or history moved
    void zoomChanged(double factor);
    // a file page's message to the control API, from its data-elis tags or, with --js, elis.request; reply answers it once
    void bridgeRequest(const QJsonObject &body, const PageMessages::Reply &reply);

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;
    void hideEvent(QHideEvent *event) override;
    void showEvent(QShowEvent *event) override;

private:
    friend class PolicyPage;
    void showBuilt(const QByteArray &html);
    void reloadShown(); // what the page shows now, leaving its prompt and focus alone
    void installTheme(const QJsonObject &theme);
    void installBridge();
    QString kind() const { return m_source.value("kind").toString(); }
    bool decide(const QUrl &url, const QString &target, bool userActivated);
    void ask(const QUrl &url);
    void fail(const QString &error);
    void loadOriginal();
    void syncStrip();
    bool syncShown();
    QUrl pageUrl() const;
    QUrl browserUrl() const;

    QJsonObject m_source, m_flags;
    QString m_pageID;
    QWebEngineProfile *m_profile = nullptr;
    PolicyPage *m_page = nullptr;
    QWebEngineView *m_view = nullptr;
    PageScheme *m_scheme = nullptr; // a built page's documents
    TextPageHost *m_text = nullptr;
    QJsonObject m_theme;
    int m_build = 0; // bumped by every build, so a slow one cannot replace a newer one
    QWidget *m_strip = nullptr, *m_errorPanel = nullptr, *m_prompt = nullptr;
    QLabel *m_identity = nullptr, *m_title = nullptr, *m_error = nullptr, *m_promptText = nullptr;
    QToolButton *m_back = nullptr, *m_forward = nullptr;
    QString m_state = QStringLiteral("loading"), m_errorText;
    QString m_storeFailure; // a persistent page without its saved store loads nothing
    QUrl m_shown;              // the committed document's address, never a pending one
    QUrl m_promptUrl;          // the hand-off waiting on the prompt
    bool m_textLoaded = false; // a file page without a grant shows its text, not its URL
    bool m_loadPending = false, m_clickedLoad = false, m_silenced = false, m_failed = false;
    bool m_contentShown = false; // a load finished once: later loads keep that document on screen while they run
    bool m_originalPending = false; // loadOriginal's load has neither committed nor failed
};
