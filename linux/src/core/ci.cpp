#include "ci.h"

#include "elis_bridge.h"

#include <QJsonArray>
#include <QJsonDocument>

QList<CiStatus> ciStatuses(const QStringList &cwds)
{
    char *reply = elis_ci_statuses(QJsonDocument(QJsonArray::fromStringList(cwds)).toJson(QJsonDocument::Compact).constData());
    const QJsonArray replies = QJsonDocument::fromJson(reply ? QByteArray(reply) : QByteArray()).array();
    elis_free(reply);
    QList<CiStatus> out;
    for (int i = 0; i < cwds.size(); ++i) {
        const QJsonObject r = replies.at(i).toObject();
        CiStatus status{r.value("ci").toObject(), {}};
        for (const QJsonValue &v : r.value("spans").toArray()) {
            const QJsonObject o = v.toObject();
            status.spans.append({o.value("text").toString(), o.value("bold").toBool(), o.value("italic").toBool(),
                                 o.value("code").toBool(), o.value("dim").toBool(), o.value("color").toString()});
        }
        out.append(status);
    }
    return out;
}
