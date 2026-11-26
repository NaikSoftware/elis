#include "upload.h"

#include "elis_bridge.h"

#include <QJsonArray>
#include <QJsonDocument>

QJsonObject uploadReserve(const QString &stateDir, const QString &sessionId, const QJsonObject &args)
{
    char *reply = elis_upload_reserve(stateDir.toUtf8().constData(), sessionId.toUtf8().constData(),
                                      QJsonDocument(args).toJson(QJsonDocument::Compact).constData());
    const QJsonObject response = QJsonDocument::fromJson(reply ? QByteArray(reply) : QByteArray()).object();
    elis_free(reply);
    return response.isEmpty() ? QJsonObject{{"ok", false}, {"error", QStringLiteral("the upload reserver gave no answer")}} : response;
}

void uploadSweep(const QString &stateDir, const std::optional<QStringList> &keep)
{
    const QByteArray ids = keep ? QJsonDocument(QJsonArray::fromStringList(*keep)).toJson(QJsonDocument::Compact) : QByteArray("null");
    elis_upload_sweep(stateDir.toUtf8().constData(), ids.constData());
}
