#pragma once

// The app side of a text or log page, the Mac's TextPageBridge with its LogFollower: it builds the document from the
// file, takes the renderer's reports, holds the page's search, wrap, diff and follow state, and answers the
// session.overlay.search|follow|wrap|changes|files commands. Qt WebEngine only.
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QTimer>

#include <functional>
#include <optional>

class PageMessages;
class QWebEnginePage;

class TextPageHost : public QObject
{
    Q_OBJECT
public:
    // source {path, line?, log?:{tail, follow}, language?, diff}; show loads a built document, fail fails the page
    TextPageHost(QWebEnginePage *page, const QJsonObject &source, std::function<void(const QByteArray &)> show,
                 std::function<void(const QString &)> fail, QObject *parent);
    void loadDocument(bool fresh); // a fresh read, or a redraw of the text in hand (a theme change)
    void stop();                   // drops every build, read and answer in flight
    void setOnScreen(bool onScreen);
    void focusSearch();
    QJsonObject readBack() const; // ControlTextOverlayNode
    // one session.overlay text command, its action as elis_overlay_text_action shaped it; a page step answers late
    bool command(const QJsonObject &action, const QString &sessionId, QJsonObject *result, QString *error);

Q_SIGNALS:
    void changed(); // state the tree reads moved

private:
    struct Report {
        int lines = 0;
        bool clipped = false, waiting = false, unreadable = false;
        bool operator==(const Report &) const = default;
    };
    void receive(const QJsonObject &body);
    void js(const QString &fn, const QJsonArray &args, std::function<void(const QVariant &)> done = {}, bool answer = false);
    void build(const QJsonObject &request);
    void rendererReady();
    int setSearch(const QString &query); // the new revision, 0 for no change
    void pushSearch();
    void pushWrap();
    void setWrap(bool wrap);
    // the log follower
    void setFollowing(bool following); // the model's value: a pause freezes where the page is
    void applyFollowing(bool following);
    void updateLoop();
    void tick();
    void readLog(bool forced, std::function<void()> then = {});
    void applyRead(const QJsonObject &read);
    void publish(const Report &next, bool push);
    void push();

    QWebEnginePage *m_page;
    PageMessages *m_messages;
    std::function<void(const QByteArray &)> m_show;
    std::function<void(const QString &)> m_fail;
    QString m_path, m_language;
    int m_line = 0;
    bool m_diff = false, m_stopped = false, m_onScreen = false; // shown: the page's showEvent says so
    // the search: query, its revision and the page's last count; typed revisions came from the page's own field
    QString m_query;
    int m_revision = 0, m_matches = 0, m_current = 0;
    QSet<int> m_typed;
    std::optional<QString> m_text; // a static page's text, so a redraw reads nothing
    int m_documentLoad = 0;
    bool m_documentPending = false; // from a build until the renderer reports ready
    int m_change = 0;
    bool m_wrap = false;
    std::optional<QJsonObject> m_changes, m_files;
    // a log page
    bool m_log = false, m_following = false, m_reading = false;
    int m_tail = 0, m_readSequence = 0, m_pauseEpoch = 0;
    Report m_report;
    std::optional<double> m_anchor;
    QJsonObject m_snapshot, m_pageSnapshot; // empty: none
    QString m_stamp, m_pageStamp;
    QTimer m_ticks;
};
