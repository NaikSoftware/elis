#include "pagecontent.h"
#include "elis_bridge.h"
#include "help.h"

#include <QApplication>
#include <QBuffer>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QPointer>
#include <QThreadPool>
#include <QWebChannel>
#include <QWebEnginePage>
#include <QWebEngineScript>
#include <QWebEngineScriptCollection>
#include <QWebEngineUrlRequestJob>
#include <QWebEngineUrlScheme>

#include <memory>
#include <utility>

static const QByteArray s_scheme = QByteArrayLiteral("elis-page"); // HtmlSource.replicaScheme

QJsonObject bridgeReply(char *raw)
{
    const QJsonObject reply = QJsonDocument::fromJson(raw ? QByteArray(raw) : QByteArray()).object();
    elis_free(raw);
    return reply;
}

QByteArray compactJson(const QJsonObject &o)
{
    return QJsonDocument(o).toJson(QJsonDocument::Compact);
}

void registerPageScheme()
{
    QWebEngineUrlScheme scheme(s_scheme);
    scheme.setSyntax(QWebEngineUrlScheme::Syntax::Host);
    scheme.setFlags(QWebEngineUrlScheme::SecureScheme);
    QWebEngineUrlScheme::registerScheme(scheme);
}

const QJsonObject &markdownAssets()
{
    static const QJsonObject assets = bridgeReply(elis_markdown_assets(QFile::encodeName(bundled(QStringLiteral("markdown"))).constData()));
    return assets;
}

void offThread(QObject *guard, std::function<QJsonObject()> job, std::function<void(const QJsonObject &)> done)
{
    // not the global pool, where a deferred control reply can wait on the GUI
    static QThreadPool pool;
    pool.start([alive = QPointer<QObject>(guard), job = std::move(job), done = std::move(done)] {
        const QJsonObject result = job();
        QMetaObject::invokeMethod(qApp, [alive, done, result] {
            if (alive)
                done(result);
        });
    });
}

PageScheme::PageScheme(const QString &pageID, const QJsonObject &links, QObject *parent)
    : QWebEngineUrlSchemeHandler(parent)
    , m_host(pageID.toLower())
    , m_links(links)
{
}

QUrl PageScheme::url(const QString &pageID, const QString &path)
{
    QUrl u;
    u.setScheme(QString::fromLatin1(s_scheme));
    u.setHost(pageID.toLower());
    u.setPath(path.startsWith(QLatin1Char('/')) ? path : QLatin1Char('/') + path);
    return u;
}

static void answer(QWebEngineUrlRequestJob *job, const QByteArray &html)
{
    auto *body = new QBuffer(job);
    body->setData(html);
    job->reply(QByteArrayLiteral("text/html;charset=utf-8"), body); // a clicked file need not declare it
}

void PageScheme::requestStarted(QWebEngineUrlRequestJob *job)
{
    const QUrl url = job->requestUrl();
    if (url.host() != m_host)
        return job->fail(QWebEngineUrlRequestJob::RequestDenied);
    const QString path = url.path(QUrl::FullyDecoded);
    if (path == QLatin1String("/") && !m_document.isEmpty())
        return answer(job, m_document);
    const QString file =
        m_links.isEmpty() ? QString() : bridgeReply(elis_markdown_linked_document(compactJson({{"path", path}, {"links", m_links}}).constData())).value("path").toString();
    if (file.isEmpty())
        return job->fail(QWebEngineUrlRequestJob::RequestDenied);
    const QString style = markdownAssets().value("style").toString();
    offThread(
        job,
        [file, style] { return bridgeReply(elis_markdown_page(compactJson({{"path", file}, {"links", true}, {"style", style}}).constData())); },
        [job](const QJsonObject &built) {
            if (built.contains("html"))
                answer(job, built.value("html").toString().toUtf8());
            else
                job->fail(QWebEngineUrlRequestJob::RequestFailed); // Chromium shows its error page, where WebKit keeps the shown one
        });
}

PageMessages::PageMessages(QWebEnginePage *page, const QStringList &handlers, Receive receive, QObject *parent)
    : QObject(parent)
    , m_handlers(handlers)
    , m_receive(std::move(receive))
{
    auto *channel = new QWebChannel(this);
    channel->registerObject(QStringLiteral("elisMessages"), this);
    page->setWebChannel(channel, QWebEngineScript::ApplicationWorld);
    QFile client(QStringLiteral(":/qtwebchannel/qwebchannel.js"));
    client.open(QIODevice::ReadOnly);
    // the renderers post their ready report as they load, before the channel connects, so posts queue until it does
    const QString shim = QStringLiteral(R"JS(
(() => {
  const queue = [];
  const waiting = new Map();
  let host = null;
  let sent = 0;
  // every document of the page shares the one channel and hears every answer, so ids carry this document's own tag
  const tag = Math.random().toString(36).slice(2) + Date.now().toString(36);
  const handler = (name) => ({
    postMessage: (body) => new Promise((resolve, reject) => {
      const id = `${tag}:${++sent}`;
      waiting.set(id, { resolve, reject });
      host ? host.post(name, body, id) : queue.push([name, body, id]);
    }),
  });
  window.webkit = { messageHandlers: Object.fromEntries(%1.map((name) => [name, handler(name)])) };
  new QWebChannel(qt.webChannelTransport, (channel) => {
    host = channel.objects.elisMessages;
    host.answered.connect((id, result, error) => {
      const settle = waiting.get(id);
      waiting.delete(id);
      if (settle) error ? settle.reject(new Error(error)) : settle.resolve(JSON.parse(result)[0]);
    });
    for (const [name, body, id] of queue.splice(0)) host.post(name, body, id);
  });
})();
)JS")
                             .arg(QString::fromUtf8(QJsonDocument(QJsonArray::fromStringList(handlers)).toJson(QJsonDocument::Compact)));
    QWebEngineScript script;
    script.setName(QStringLiteral("elis-messages"));
    script.setSourceCode(QString::fromUtf8(client.readAll()) + shim);
    script.setInjectionPoint(QWebEngineScript::DocumentCreation);
    script.setWorldId(QWebEngineScript::ApplicationWorld);
    page->scripts().insert(script);
}

void PageMessages::post(const QString &handler, const QJsonObject &body, const QString &id)
{
    if (!m_handlers.contains(handler))
        return;
    m_receive(handler, body, [self = QPointer<PageMessages>(this), id, once = std::make_shared<bool>()](const QJsonValue &result, const QString &error) {
        if (self && !std::exchange(*once, true))
            Q_EMIT self->answered(id, QString::fromUtf8(QJsonDocument(QJsonArray{result}).toJson(QJsonDocument::Compact)), error);
    });
}
