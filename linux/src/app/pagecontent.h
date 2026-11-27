#pragma once

// What built pages (markdown, image, text, document) share: the elis-page scheme that serves their documents, the
// page-to-app message shim the shared renderers post through, the bundled renderers, and off-thread builds.
// Qt WebEngine only.
#include <QJsonObject>
#include <QObject>
#include <QUrl>
#include <QWebEngineUrlSchemeHandler>

#include <functional>

class QWebEnginePage;

QJsonObject bridgeReply(char *raw); // a bridge export's JSON reply, freed
QByteArray compactJson(const QJsonObject &o);
void registerPageScheme();           // before QApplication exists
const QJsonObject &markdownAssets(); // the bundled renderers: {script, style, textScript, textStyle}, read once
// runs job on a worker thread and hands its result to done on the GUI thread, unless guard is gone by then
void offThread(QObject *guard, std::function<QJsonObject()> job, std::function<void(const QJsonObject &)> done);

// elis-page://<pageID>/: "/" answers the page's built document; with a link grant, an absolute markdown path answers
// that file once ElisCore's linkedDocument allows it after symlink resolution. Anything else fails unread.
class PageScheme : public QWebEngineUrlSchemeHandler
{
public:
    PageScheme(const QString &pageID, const QJsonObject &links, QObject *parent);
    static QUrl url(const QString &pageID, const QString &path = QStringLiteral("/"));
    void setDocument(const QByteArray &html) { m_document = html; }
    void requestStarted(QWebEngineUrlRequestJob *job) override;

private:
    QString m_host;
    QJsonObject m_links;
    QByteArray m_document;
};

// window.webkit.messageHandlers[name].postMessage for the page's ApplicationWorld scripts, carried over QWebChannel,
// so the renderers shared with the Mac and the phone post unchanged. Main frame only. postMessage's promise settles with
// the reply: the result, or an Error carrying the error; a reply after this object is gone is dropped.
class PageMessages : public QObject
{
    Q_OBJECT
public:
    using Reply = std::function<void(const QJsonValue &result, const QString &error)>;
    using Receive = std::function<void(const QString &handler, const QJsonObject &body, const Reply &reply)>;
    PageMessages(QWebEnginePage *page, const QStringList &handlers, Receive receive, QObject *parent);
    Q_INVOKABLE void post(const QString &handler, const QJsonObject &body, const QString &id);

Q_SIGNALS:
    void answered(const QString &id, const QString &result, const QString &error); // result: a one-element JSON array, which keeps {} an object

private:
    QStringList m_handlers;
    Receive m_receive;
};
