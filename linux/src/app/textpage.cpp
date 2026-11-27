#include "textpage.h"
#include "control.h"
#include "elis_bridge.h"
#include "pagecontent.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QPointer>
#include <QWebEnginePage>
#include <QWebEngineScript>
#include <QWebEngineScriptCollection>

static const QJsonObject &constants()
{
    static const QJsonObject c = bridgeReply(elis_text_page_constants());
    return c;
}

static QString message(const char *key)
{
    return constants().value(QLatin1String(key)).toString();
}

static QJsonObject failed(const QString &error)
{
    return {{"ok", false}, {"error", error}};
}

TextPageHost::TextPageHost(QWebEnginePage *page, const QJsonObject &source, std::function<void(const QByteArray &)> show,
                           std::function<void(const QString &)> fail, QObject *parent)
    : QObject(parent)
    , m_page(page)
    , m_show(std::move(show))
    , m_fail(std::move(fail))
    , m_path(source.value("path").toString())
    , m_language(source.value("language").toString())
    , m_line(source.value("line").toInt())
    , m_diff(source.value("diff").toBool())
{
    const QJsonObject log = source.value("log").toObject();
    m_log = !log.isEmpty();
    m_tail = log.value("tail").toInt();
    m_following = log.value("follow").toBool();
    m_messages = new PageMessages(page, {QStringLiteral("elisTextPage")}, [this](const QString &, const QJsonObject &body) { receive(body); }, this);
    QWebEngineScript renderer;
    renderer.setName(QStringLiteral("elis-text"));
    renderer.setSourceCode(markdownAssets().value("textScript").toString());
    renderer.setInjectionPoint(QWebEngineScript::DocumentReady);
    renderer.setWorldId(QWebEngineScript::ApplicationWorld);
    page->scripts().insert(renderer);
    m_ticks.setInterval(1000);
    connect(&m_ticks, &QTimer::timeout, this, &TextPageHost::tick);
}

void TextPageHost::js(const QString &fn, const QJsonArray &args, std::function<void(const QVariant &)> done, bool answer)
{
    const QByteArray list = QJsonDocument(args).toJson(QJsonDocument::Compact);
    const QString call = fn + QLatin1Char('(') + QString::fromUtf8(list.mid(1, list.size() - 2)) + QLatin1Char(')');
    if (!done)
        return m_page->runJavaScript(call, QWebEngineScript::ApplicationWorld);
    // the host can go first: a command's answer still runs, with no value, so a waiting caller never hangs
    m_page->runJavaScript(call, QWebEngineScript::ApplicationWorld, [self = QPointer<TextPageHost>(this), done, answer](const QVariant &v) {
        if (self && !self->m_stopped)
            done(v);
        else if (answer)
            done(QVariant());
    });
}

void TextPageHost::build(const QJsonObject &request)
{
    const int load = m_documentLoad;
    const bool read = !request.contains("text");
    offThread(
        this,
        [request, read] {
            QJsonObject full = request;
            if (read) {
                const QJsonObject loaded = bridgeReply(elis_text_load(compactJson({{"path", request.value("path")}}).constData()));
                if (!loaded.contains("text"))
                    return loaded;
                full.insert("text", loaded.value("text"));
            }
            QJsonObject built = bridgeReply(elis_text_page(compactJson(full).constData()));
            if (read)
                built.insert("text", full.value("text"));
            return built;
        },
        [this, load, read](const QJsonObject &built) {
            if (m_stopped || load != m_documentLoad)
                return;
            if (!built.contains("html"))
                return m_fail(built.value("error").toString());
            if (read) {
                m_text = built.value("text").toString();
                m_change = 0;
            }
            m_show(built.value("html").toString().toUtf8());
        });
}

void TextPageHost::loadDocument(bool fresh)
{
    const int load = ++m_documentLoad;
    m_documentPending = true;
    QJsonObject request{{"path", m_path},
                        {"style", markdownAssets().value("textStyle")},
                        {"search", QJsonObject{{"query", m_query}, {"revision", m_revision}, {"current", m_current}}},
                        {"wrap", m_wrap}};
    if (m_log) {
        auto shown = [this, load, request]() mutable {
            if (m_stopped || load != m_documentLoad)
                return;
            m_pageSnapshot = m_snapshot;
            m_pageStamp = m_stamp;
            request.insert("text", m_snapshot.value("text").toString());
            request.insert("log", QJsonObject{{"following", m_following},
                                              {"lines", m_report.lines},
                                              {"clipped", m_report.clipped},
                                              {"waiting", m_report.waiting},
                                              {"unreadable", m_report.unreadable}});
            if (!m_following && m_anchor)
                request.insert("anchor", *m_anchor);
            build(request);
        };
        if (fresh || m_snapshot.isEmpty())
            return readLog(true, shown);
        return shown();
    }
    if (m_line > 0)
        request.insert("line", m_line);
    // a shown page reopens where it was, so a theme change or a reload never moves the view
    auto placed = [this, load, fresh, request](const QVariantMap &place) mutable {
        if (m_stopped || load != m_documentLoad)
            return;
        if (place.value("top").canConvert<double>() && place.contains("top"))
            request.insert("anchor", place.value("top").toDouble());
        if (fresh || !m_text) {
            // the file may now hold other changes
            m_changes.reset();
            m_files.reset();
            return build(request);
        }
        request.insert("text", *m_text);
        request.insert("change", m_change);
        if (!place.isEmpty()) {
            request.insert("entered", place.value("entered").toBool());
            request.insert("file", place.value("file").toInt());
        }
        build(request);
    };
    if (!m_text)
        return placed({});
    js(QStringLiteral("elisTextNavigation"), {}, [placed](const QVariant &v) mutable { placed(v.toMap()); });
}

void TextPageHost::stop()
{
    m_stopped = true;
    ++m_documentLoad;
    ++m_readSequence;
    ++m_pauseEpoch;
    m_ticks.stop();
}

void TextPageHost::setOnScreen(bool onScreen)
{
    if (onScreen == m_onScreen)
        return;
    m_onScreen = onScreen;
    updateLoop();
}

void TextPageHost::focusSearch()
{
    js(QStringLiteral("elisTextFocusSearch"), {});
}

void TextPageHost::receive(const QJsonObject &body)
{
    if (m_stopped)
        return;
    if (body.value("ready").toBool())
        return rendererReady();
    if (body.value("search").isString()) {
        if (const int revision = setSearch(body.value("search").toString())) {
            m_typed.insert(revision);
            if (!m_documentPending)
                pushSearch();
        }
        return;
    }
    if (body.value("report").isObject()) { // counts under another query or revision never land
        const QJsonObject r = body.value("report").toObject();
        if (r.value("revision").toInt() == m_revision && !m_query.isEmpty() && r.value("query").toString() == m_query) {
            m_matches = r.value("matches").toInt();
            m_current = r.value("current").toInt();
        }
        return;
    }
    if (body.value("changes").isObject()) {
        const QJsonObject c = body.value("changes").toObject();
        if (c.value("count").isDouble() && c.value("current").isDouble()) {
            m_change = c.value("current").toInt();
            m_changes = QJsonObject{{"count", c.value("count").toInt()}, {"current", m_change}};
        }
        return;
    }
    if (body.value("files").isObject()) { // the page being replaced can still report its scroll
        const QJsonObject f = body.value("files").toObject();
        if (!m_documentPending && f.value("count").toInt() > 0 && f.value("current").isDouble() && f.value("path").isString())
            m_files = QJsonObject{{"count", f.value("count").toInt()}, {"current", f.value("current").toInt()}, {"path", f.value("path")}};
        return;
    }
    if (body.value("wrap").isBool()) { // the page shows its own toggle already
        if (body.value("wrap").toBool() != m_wrap) {
            m_wrap = body.value("wrap").toBool();
            Q_EMIT changed();
        }
        return;
    }
    if (!body.value("following").isBool() || !m_log)
        return;
    // a user scroll: its offset, and whether it now sits at the bottom
    const QJsonValue top = body.value("top");
    m_anchor = top.isDouble() ? std::optional<double>(top.toDouble()) : std::nullopt;
    if (body.value("following").toBool() == m_following)
        return;
    applyFollowing(body.value("following").toBool());
    Q_EMIT changed();
}

void TextPageHost::rendererReady()
{
    if (!m_documentPending)
        return;
    m_documentPending = false;
    if (m_log) {
        push();
        js(QStringLiteral("elisTextSetFollowing"), {m_following});
    }
    pushSearch();
    pushWrap();
}

int TextPageHost::setSearch(const QString &raw)
{
    const QList<uint> scalars = raw.toUcs4();
    const QString query = QString::fromUcs4(reinterpret_cast<const char32_t *>(scalars.constData()), qMin(scalars.size(), qsizetype(constants().value("maxQuery").toInt())));
    if (query == m_query)
        return 0;
    m_query = query;
    ++m_revision;
    m_matches = m_current = 0;
    Q_EMIT changed();
    return m_revision;
}

void TextPageHost::pushSearch()
{
    const bool typed = m_typed.contains(m_revision);
    m_typed.removeIf([this](int r) { return r <= m_revision; });
    js(QStringLiteral("elisTextSearchSet"), {m_query, m_revision, typed});
}

void TextPageHost::pushWrap()
{
    js(QStringLiteral("elisTextSetWrap"), {m_wrap});
}

void TextPageHost::setWrap(bool wrap)
{
    if (wrap == m_wrap)
        return;
    m_wrap = wrap;
    Q_EMIT changed();
    if (!m_documentPending)
        pushWrap();
}

bool TextPageHost::command(const QJsonObject &action, const QString &sessionId, QJsonObject *result, QString *error)
{
    const QString kind = action.value("kind").toString();
    auto desired = [mode = action.value("mode").toString()](bool current) {
        return mode == QLatin1String("on") || (mode != QLatin1String("off") && !current);
    };
    if (kind == QLatin1String("follow")) {
        if (!m_log)
            return *error = message("notLog"), false;
        const bool following = desired(m_following);
        if (following != m_following) {
            setFollowing(following);
            Q_EMIT changed();
        }
        result->insert("text", following ? QStringLiteral("following") : QStringLiteral("paused"));
        return true;
    }
    if (kind == QLatin1String("wrap")) {
        setWrap(desired(m_wrap));
        result->insert("text", m_wrap ? QStringLiteral("wrapped") : QStringLiteral("unwrapped"));
        return true;
    }
    const QString search = action.value("search").toString();
    if (kind == QLatin1String("search") && (search == QLatin1String("query") || search == QLatin1String("close"))) {
        if (setSearch(search == QLatin1String("query") ? action.value("query").toString() : QString()) && !m_documentPending)
            pushSearch();
        return true;
    }
    if (kind == QLatin1String("search") && m_query.isEmpty())
        return *error = message("noQuery"), false;
    if (kind != QLatin1String("search") && (m_log || !m_diff))
        return *error = message("notDiff"), false;
    if (m_documentPending)
        return *error = message("notLoaded"), false;
    // the page answers the step; the model takes it before the reply, so a read right after never lags the page
    const auto reply = deferReply(message("notLoaded"));
    auto answered = [reply, sessionId](const QString &text) {
        reply({{"ok", true}, {"result", QJsonObject{{"id", sessionId}, {"text", text}}}});
    };
    if (kind == QLatin1String("search")) {
        const QString query = m_query;
        const int revision = m_revision;
        js(QStringLiteral("elisTextSearchStep"), {search == QLatin1String("next"), query, revision}, [this, reply, answered, query, revision](const QVariant &v) {
            const QVariantMap body = v.toMap();
            if (!body.contains("matches") || !body.contains("current"))
                return reply(failed(message("notLoaded")));
            const int matches = body.value("matches").toInt(), current = body.value("current").toInt();
            if (revision == m_revision && query == m_query) {
                m_matches = matches;
                m_current = current;
            }
            if (matches > 0 && m_log && m_following) { // a move pauses a following log, as the page does
                setFollowing(false);
                Q_EMIT changed();
            }
            answered(QStringLiteral("%1 of %2").arg(current).arg(matches));
        }, true);
    } else if (kind == QLatin1String("changes")) {
        js(QStringLiteral("elisTextChangeStep"), {action.value("forward").toBool()}, [this, reply, answered](const QVariant &v) {
            const QVariantMap body = v.toMap();
            if (!body.contains("count") || !body.contains("current"))
                return reply(failed(message("notLoaded")));
            const int count = body.value("count").toInt(), current = body.value("current").toInt();
            if (count == 0)
                return reply(failed(message("noChanges")));
            m_change = current;
            m_changes = QJsonObject{{"count", count}, {"current", current}};
            answered(QStringLiteral("%1 of %2").arg(current).arg(count));
        }, true);
    } else {
        const QString to = action.value("to").toString();
        js(QStringLiteral("elisTextFileGo"), {to}, [this, reply, answered, to](const QVariant &v) {
            if (!v.isValid())
                return reply(failed(message("notLoaded")));
            const QVariantMap body = v.toMap();
            if (body.value("count").toInt() <= 0 || !body.contains("current") || body.value("path").typeId() != QMetaType::QString)
                return reply(failed(message("noFile").arg(to)));
            m_files = QJsonObject{{"count", body.value("count").toInt()}, {"current", body.value("current").toInt()}, {"path", body.value("path").toString()}};
            answered(QStringLiteral("%1 of %2: %3").arg(body.value("current").toInt()).arg(body.value("count").toInt()).arg(body.value("path").toString()));
        }, true);
    }
    result->insert("deferred", true);
    return true;
}

QJsonObject TextPageHost::readBack() const
{
    QJsonObject node{{"file", m_path}};
    if (!m_language.isEmpty())
        node.insert("language", m_language);
    if (m_line > 0)
        node.insert("line", m_line);
    if (m_log) {
        node.insert("tail", m_tail);
        node.insert("following", m_following);
        node.insert("lines", m_report.lines);
        node.insert("clipped", m_report.clipped);
        node.insert("waiting", m_report.waiting);
        node.insert("unreadable", m_report.unreadable);
    }
    if (!m_query.isEmpty())
        node.insert("search", QJsonObject{{"query", m_query}, {"matches", m_matches}, {"current", m_current}});
    if (m_changes)
        node.insert("changes", *m_changes);
    if (m_files)
        node.insert("files", *m_files);
    if (m_wrap)
        node.insert("wrap", true);
    return node;
}

void TextPageHost::setFollowing(bool following)
{
    if (following == m_following)
        return;
    if (!following)
        m_anchor.reset(); // a pause from control freezes the view where it is, not where an earlier scroll left it
    applyFollowing(following);
    if (!m_documentPending)
        js(QStringLiteral("elisTextSetFollowing"), {following});
}

void TextPageHost::applyFollowing(bool following)
{
    m_following = following;
    if (!following)
        ++m_pauseEpoch; // no read in flight lands on the view a user scrolled into
    updateLoop();
}

void TextPageHost::updateLoop()
{
    const bool run = m_log && m_following && m_onScreen && !m_stopped;
    if (run == m_ticks.isActive())
        return;
    if (!run)
        return m_ticks.stop();
    m_ticks.start();
    tick();
}

void TextPageHost::tick()
{
    if (!m_documentPending && !m_reading)
        readLog(false);
}

void TextPageHost::readLog(bool forced, std::function<void()> then)
{
    const int mine = ++m_readSequence, epoch = m_pauseEpoch;
    m_reading = true;
    QJsonObject request{{"path", m_path}, {"tail", m_tail}};
    if (!forced && !m_stamp.isEmpty())
        request.insert("stamp", m_stamp); // a file that keeps it costs one fstat and no read
    offThread(
        this, [request] { return bridgeReply(elis_text_log_read(compactJson(request).constData())); },
        [this, mine, epoch, forced, then](const QJsonObject &read) {
            m_reading = false;
            if (m_stopped || mine != m_readSequence || (!forced && epoch != m_pauseEpoch))
                return;
            applyRead(read);
            if (then)
                then();
        });
}

void TextPageHost::applyRead(const QJsonObject &read)
{
    if (read.value("unchanged").toBool())
        return;
    Report next = m_report;
    if (read.contains("error")) { // a missing file: waiting, the last good text still shown
        m_stamp.clear();
        next.waiting = true;
        next.unreadable = false;
        return publish(next, !(next == m_report));
    }
    m_stamp = read.value("stamp").toString(); // a binary end keeps its stamp, so it is not read again unchanged
    if (!read.value("snapshot").isObject()) {
        next.unreadable = true;
        next.waiting = false;
        return publish(next, !(next == m_report));
    }
    m_snapshot = read.value("snapshot").toObject();
    publish({m_snapshot.value("lines").toInt(), m_snapshot.value("clipped").toBool(), false, false}, true);
}

void TextPageHost::publish(const Report &next, bool push)
{
    m_report = next; // read back, never emitted, so a follower's ticks wake no hook
    if (push && !m_documentPending)
        this->push();
}

void TextPageHost::push()
{
    const QString text = m_snapshot.value("text").toString();
    QJsonObject request{{"new", m_snapshot}, {"newStamp", m_stamp}, {"oldStamp", m_pageStamp}};
    if (!m_pageSnapshot.isEmpty())
        request.insert("old", m_pageSnapshot);
    if (m_snapshot.isEmpty())
        request.remove("new");
    const QJsonObject shift = bridgeReply(elis_text_log_shift(compactJson(request).constData()));
    m_pageSnapshot = m_snapshot;
    m_pageStamp = m_stamp;
    // highlighting stops past the limit, as the first document drops it
    const bool highlight = !m_language.isEmpty() && text.toUtf8().size() <= constants().value("maxHighlightBytes").toInt();
    js(QStringLiteral("elisTextUpdate"),
       {text, m_report.clipped, m_report.waiting, m_report.unreadable, highlight ? QJsonValue(m_language) : QJsonValue(), shift});
}
