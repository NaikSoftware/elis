#pragma once

// A page overlay (session.overlay.open --html/--url): a web view under an identity strip, every navigation judged by
// ElisCore's HtmlNavigationPolicy through the bridge. Qt WebEngine only; the slot code in overlay.cpp owns placement.
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
    // "language" and "diff"; flags {navigation,javascript,chromeless};
    // theme: the terminal's {background, foreground, dark, palette}, which every page reads and a file page wears
    PageOverlay(const QJsonObject &source, const QJsonObject &flags, const QString &pageID, const QJsonObject &theme, QWidget *parent = nullptr);
    ~PageOverlay() override;

    QString pageID() const { return m_pageID; }
    QJsonObject source() const { return m_source; }
    QJsonObject flags() const { return m_flags; }
    QWebEngineView *view() const { return m_view; }
    // ControlHtmlOverlayNode's page fields: source, state, error, page, title, history, flags, zoom, id
    QJsonObject readBack() const;
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
    // where Open in Browser and Show in Folder go; tests replace it
    static inline std::function<void(const QUrl &)> openExternally;

Q_SIGNALS:
    void closeRequested(); // the strip's close button or the page's window.close()
    void changed();        // load state, address, title or history moved
    void zoomChanged(double factor);

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;
    void hideEvent(QHideEvent *event) override;
    void showEvent(QShowEvent *event) override;

private:
    friend class PolicyPage;
    void showBuilt(const QByteArray &html);
    void installTheme(const QJsonObject &theme);
    QString kind() const { return m_source.value("kind").toString(); }
    bool decide(const QUrl &url, const QString &target, bool userActivated);
    void ask(const QUrl &url);
    void fail(const QString &error);
    void loadOriginal();
    void syncStrip();
    QUrl pageUrl() const;
    QUrl browserUrl() const;
    QString identity() const;

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
    QUrl m_shown;              // the committed document's address, never a pending one
    QUrl m_promptUrl;          // the hand-off waiting on the prompt
    bool m_textLoaded = false; // a file page without a grant shows its text, not its URL
    bool m_loadPending = false, m_clickedLoad = false, m_silenced = false, m_failed = false;
    bool m_contentShown = false; // a load finished once: later loads keep that document on screen while they run
};
