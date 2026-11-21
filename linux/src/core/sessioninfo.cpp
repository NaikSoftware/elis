#include "sessioninfo.h"

#include "elis_bridge.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

static QJsonObject bridged(char *reply)
{
    const QJsonObject response = QJsonDocument::fromJson(reply ? QByteArray(reply) : QByteArray()).object();
    elis_free(reply);
    return response;
}

SessionInfo SessionInfo::make(const QString &source, bool markdown, double hideAfter, QString *error)
{
    const QJsonObject request{{"source", source}, {"markdown", markdown}, {"hideAfter", hideAfter}};
    const QJsonObject reply = bridged(elis_session_info(QJsonDocument(request).toJson(QJsonDocument::Compact).constData()));
    if (!reply.value("ok").toBool()) {
        *error = reply.value("error").toString(QStringLiteral("the info parser gave no answer"));
        return {};
    }
    QList<InfoSpan> spans;
    for (const QJsonValue &v : reply.value("spans").toArray()) {
        const QJsonObject o = v.toObject();
        spans << InfoSpan{o.value("text").toString(), o.value("bold").toBool(), o.value("italic").toBool(), o.value("code").toBool(),
                          o.value("dim").toBool(), o.value("color").toString()};
    }
    return {source, markdown, hideAfter, spans};
}

QString sidebarDensity(const QString &mode, const QString &current, QString *error)
{
    QJsonObject request{{"current", current}};
    if (!mode.isEmpty())
        request.insert("mode", mode);
    const QJsonObject reply = bridged(elis_sidebar_density(QJsonDocument(request).toJson(QJsonDocument::Compact).constData()));
    if (!reply.value("ok").toBool())
        *error = reply.value("error").toString(QStringLiteral("the density check gave no answer"));
    return reply.value("density").toString();
}
