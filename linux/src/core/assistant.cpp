#include "assistant.h"

#include "control.h"
#include "elis_bridge.h"
#include "store.h"

#include <QJsonDocument>

static QByteArray json(const QJsonValue &value)
{
    // no argument is a scalar: anything but null, an object or an array goes as non-JSON, which the bridge refuses
    return value.isObject() ? QJsonDocument(value.toObject()).toJson(QJsonDocument::Compact)
         : value.isArray()  ? QJsonDocument(value.toArray()).toJson(QJsonDocument::Compact)
         : value.isNull()   ? QByteArrayLiteral("null")
                            : QByteArrayLiteral("invalid");
}

static QByteArray taken(char *reply)
{
    const QByteArray out(reply ? reply : "");
    elis_free(reply);
    return out;
}

static QJsonObject object(char *reply)
{
    return QJsonDocument::fromJson(taken(reply)).object();
}

// an array, or the bridge's {"error"}
static QJsonValue arrayOrError(char *reply)
{
    const QJsonDocument doc = QJsonDocument::fromJson(taken(reply));
    return doc.isArray() ? QJsonValue(doc.array()) : QJsonValue(doc.object());
}

namespace AssistantBridge {

void open(const QString &stateDir)
{
    elis_free(elis_assistant_open(stateDir.toUtf8().constData()));
}

QJsonObject run(const QJsonObject &request, const QJsonValue &peers, const QJsonValue &providers)
{
    return object(elis_assistant_run(json(request).constData(), json(peers).constData(), json(providers).constData()));
}

QJsonObject finishSend(const QJsonObject &plan, const QJsonObject &failures)
{
    return object(elis_assistant_finish_send(json(plan).constData(), json(failures).constData()));
}

QJsonObject stamp(const QJsonObject &tree, const QJsonValue &peers, const QJsonValue &providers)
{
    return object(elis_assistant_stamp(json(tree).constData(), json(peers).constData(), json(providers).constData()));
}

void turnEnded()
{
    elis_assistant_turn_ended();
}

QJsonObject providerFailed(const QString &message)
{
    return object(elis_assistant_provider_failed(message.toUtf8().constData()));
}

void markSeen()
{
    elis_assistant_mark_seen();
}

QJsonObject appendAssistant(const QString &text)
{
    return object(elis_assistant_append_assistant(text.toUtf8().constData()));
}

QJsonObject launch(const QString &provider, const QJsonArray &peers)
{
    return object(elis_assistant_launch(provider.toUtf8().constData(), json(peers).constData()));
}

QJsonValue turnArgv(const QString &provider, const QString &input, const QJsonArray &peers)
{
    return arrayOrError(elis_assistant_turn_argv(provider.toUtf8().constData(), input.toUtf8().constData(), json(peers).constData()));
}

QString encode(const QString &provider, const QString &text)
{
    return QString::fromUtf8(taken(elis_assistant_encode(provider.toUtf8().constData(), text.toUtf8().constData())));
}

QJsonValue decode(const QString &provider, const QString &line)
{
    return arrayOrError(elis_assistant_decode(provider.toUtf8().constData(), line.toUtf8().constData()));
}

QString recap()
{
    return QString::fromUtf8(taken(elis_assistant_recap()));
}

}

namespace Assistant {

QJsonArray peers(const QList<Window> &windows)
{
    QJsonArray out;
    for (const Window &w : windows)
        for (const Workspace &ws : std::as_const(w.store->workspaces))
            for (const Session &s : ws.sessions) {
                QJsonObject peer{{"sessionID", s.id}, {"window", w.id}, {"workspaceID", ws.id}, {"workspaceName", ws.name}, {"name", s.displayName()},
                                 {"status", s.status}};
                if (!s.agent.isEmpty()) // the core counts any agent, "" too, as one
                    peer.insert("agent", s.agent);
                out << peer;
            }
    return out;
}

static QString typeInto(const QJsonObject &peer, const QString &text, const QList<Window> &windows)
{
    const QString id = peer.value("sessionID").toString();
    for (const Window &w : windows)
        if (w.id == peer.value("window").toString()) {
            QJsonObject args{{"text", text}};
            if (const Session *s = w.store->session(id); s && !s->agentPane.isEmpty())
                args.insert("pane", s->agentPane);
            const QJsonObject r = ::dispatch(*w.store, *w.terminals, {{"cmd", "session.type"}, {"target", id}, {"args", args}});
            return r.value("ok").toBool() ? QString() : r.value("error").toString();
        }
    return QStringLiteral("window not open");
}

QJsonObject dispatch(const QJsonObject &request, const QList<Window> &windows, const QStringList &providers, AssistantSink *sink)
{
    QJsonObject step = AssistantBridge::run(request, peers(windows), QJsonArray::fromStringList(providers));
    if (step.contains("plan")) {
        const QJsonObject plan = step.value("plan").toObject();
        QJsonObject failures;
        for (const QJsonValue &target : plan.value("targets").toArray())
            if (const QString error = typeInto(target.toObject(), plan.value("line").toString() + QLatin1Char('\n'), windows); !error.isEmpty())
                failures.insert(target.toObject().value("sessionID").toString(), error);
        step = AssistantBridge::finishSend(plan, failures);
    }
    for (const QJsonValue &v : step.value("effects").toArray()) {
        const QJsonObject effect = v.toObject();
        const QString type = effect.value("type").toString();
        if (type == QLatin1String("input") || type == QLatin1String("sent"))
            emitMessage(effect.value("entry").toObject(), windows);
        if (type == QLatin1String("input") && sink)
            sink->enqueue(effect.value("streamText").toString());
        else if (type == QLatin1String("input")) // the input has no turn to end, so the failure clears running
            emitMessage(AssistantBridge::providerFailed(QStringLiteral("no assistant provider is running")), windows);
        else if (type == QLatin1String("providerChanged") && sink)
            sink->providerChanged(effect.value("provider").toString());
        else if (type == QLatin1String("show"))
            AssistantBridge::markSeen(); // shortcut: no chat view yet, so a show always succeeds; the Elis row's selection replaces it
    }
    return step.value("reply").toObject();
}

QJsonObject stamp(const QJsonObject &treeReply, const QList<Window> &windows, const QStringList &providers)
{
    if (!treeReply.value("ok").toBool())
        return treeReply;
    const QJsonObject tree = AssistantBridge::stamp(treeReply["result"]["tree"].toObject(), peers(windows), QJsonArray::fromStringList(providers));
    if (tree.contains("error"))
        return treeReply; // the tree without handles beats no tree
    return {{"ok", true}, {"result", QJsonObject{{"tree", tree}}}};
}

void emitMessage(const QJsonObject &entry, const QList<Window> &windows)
{
    if (windows.isEmpty())
        return;
    const QString from = entry.value("from").toString();
    QJsonObject payload{{"kind", entry.value("kind")}, {"text", entry.value("text")}};
    Terminals *via = windows.first().terminals;
    if (!from.isEmpty()) {
        payload.insert("from", from);
        const QJsonObject probe{{"workspaces", QJsonArray{QJsonObject{{"sessions", QJsonArray{QJsonObject{{"id", from}}}}}}}};
        const QString handle = AssistantBridge::stamp(probe, peers(windows), QJsonValue::Null)["workspaces"][0]["sessions"][0]["handle"].toString();
        if (!handle.isEmpty())
            payload.insert("handle", handle);
        for (const Window &w : windows)
            if (w.store->session(from))
                via = w.terminals;
    }
    via->emitEvent(QStringLiteral("assistant.message"), from, payload);
}

}
