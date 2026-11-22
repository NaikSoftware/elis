#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QJsonValue>
#include <QString>
#include <QStringList>

// The assistant through ElisBridge (bridge Sources/ElisBridge/Chat.swift): ElisCore's chat and commands, shared with
// the Mac. elis_bridge.h owns each shape. Call every function on the GUI thread.
namespace AssistantBridge {
void open(const QString &stateDir);
// peers and providers: null when the host cannot list them; a scalar is refused
QJsonObject run(const QJsonObject &request, const QJsonValue &peers, const QJsonValue &providers);
QJsonObject finishSend(const QJsonObject &plan, const QJsonObject &failures);
QJsonObject stamp(const QJsonObject &tree, const QJsonValue &peers, const QJsonValue &providers);
void turnEnded();
QJsonObject providerFailed(const QString &message);
void markSeen();
QJsonObject appendAssistant(const QString &text);
QJsonObject launch(const QString &provider, const QJsonArray &peers);
// turnArgv and decode: an array, or {"error"}
QJsonValue turnArgv(const QString &provider, const QString &input, const QJsonArray &peers);
QString encode(const QString &provider, const QString &text);
QJsonValue decode(const QString &provider, const QString &line);
QString recap();
}
