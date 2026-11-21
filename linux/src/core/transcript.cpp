#include "transcript.h"

#include "elis_bridge.h"

#include <QDir>
#include <QJsonDocument>

QString claudeHome(const QString &configDir, const QString &home)
{
    return configDir.startsWith(QLatin1Char('/')) ? configDir : QDir(home).filePath(QStringLiteral(".claude"));
}

static QJsonObject taken(char *reply)
{
    const QJsonObject response = QJsonDocument::fromJson(reply ? QByteArray(reply) : QByteArray()).object();
    elis_free(reply);
    return response.isEmpty() ? QJsonObject{{"ok", false}, {"error", QStringLiteral("the transcript reader gave no answer")}} : response;
}

static QByteArray json(const QJsonObject &args)
{
    return QJsonDocument(args).toJson(QJsonDocument::Compact);
}

QJsonObject transcriptArguments(const QJsonObject &args)
{
    return taken(elis_transcript_arguments(json(args).constData()));
}

QJsonObject transcriptPage(const QJsonObject &args, const QString &claudeDirectory, const QString &sessionId, const QString &pane)
{
    return taken(elis_transcript_read(json(args).constData(), claudeDirectory.toUtf8().constData(), sessionId.toUtf8().constData(),
                                      pane.toUtf8().constData()));
}
