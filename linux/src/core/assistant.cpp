#include "assistant.h"

#include "elis_bridge.h"

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
