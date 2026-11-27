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
class PolicyPage;

class PageOverlay : public QWidget
{
    Q_OBJECT
public:
    // source {"kind":"file","path","cwd"?} | {"kind":"url","url"}; flags {navigation,javascript,chromeless,persistent,browse};
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

    static double zoom(); // the one app-wide factor every page shows at
    static void setZoom(double factor);
    static bool stepZoom(const QString &fontAction); // increase_font_size:1 | decrease_font_size:1 | reset_font_size
    // the saved store every --persistent page shares, built on first use: why it cannot be used, empty when it can
    static QString persistentStoreFailure();
    static bool clearPersistentStore(const QString &target, const QJsonObject &args, QString *error); // browser.clear
    // where Open in Browser and Show in Folder go; tests replace it
    static inline std::function<void(const QUrl &)> openExternally;

Q_SIGNALS:
    void closeRequested(); // the strip's close button or the page's window.close()
    void changed();        // load state, address, title or history moved
    void zoomChanged(double factor);

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;
    void hideEvent(QHideEvent *event) override;

private:
    friend class PolicyPage;
    bool decide(const QUrl &url, const QString &target, bool userActivated);
    void ask(const QUrl &url);
    void fail(const QString &error);
    void loadOriginal();
    void syncStrip();
    bool syncShown();
    QUrl pageUrl() const;
    QUrl browserUrl() const;
    QString identity() const;

    QJsonObject m_source, m_flags;
    QString m_pageID;
    QWebEngineProfile *m_profile = nullptr;
    PolicyPage *m_page = nullptr;
    QWebEngineView *m_view = nullptr;
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
};
