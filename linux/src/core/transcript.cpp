#include "transcript.h"

#include <QDir>

QString claudeHome(const QString &configDir, const QString &home)
{
    return configDir.startsWith(QLatin1Char('/')) ? configDir : QDir(home).filePath(QStringLiteral(".claude"));
}

// shortcut: no reader yet; the shared Swift ElisCore reader fills this in (Linux phase 2 plan). Until then a valid read
// answers the Mac's refusal for a host without the reader, which the phone reads as "Chat unavailable here".
QJsonObject transcriptPage(const QString &claudeDirectory, const TranscriptRequest &request)
{
    Q_UNUSED(claudeDirectory);
    Q_UNUSED(request);
    return {{"ok", false}, {"error", QStringLiteral("the Elis on this host is too old for session.transcript")}};
}
