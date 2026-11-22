#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QJsonValue>
#include <QString>
#include <QStringList>

#include <functional>

class Store;
class Terminals;

// The assistant through ElisBridge (bridge Sources/ElisBridge/Chat.swift): ElisCore's chat and commands, shared with
// the Mac. elis_bridge.h owns each shape. Call every function on the GUI thread.
namespace AssistantBridge {
void open(const QString &stateDir);
// peers and providers: null when the host cannot list them; a scalar is refused
QJsonObject run(const QJsonObject &request, const QJsonValue &peers, const QJsonValue &providers);
QJsonObject finishSend(const QJsonObject &plan, const QJsonObject &failures);
QJsonObject stamp(const QJsonObject &tree, const QJsonValue &peers, const QJsonValue &providers);
void turnEnded();
QJsonObject turnFailed(const QString &message); // the error entry; the queue behind it still runs
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

// Where the commands' inputs and provider switches go: the provider process (app AssistantRunner)
class AssistantSink
{
public:
    virtual ~AssistantSink() = default;
    virtual void enqueue(const QString &streamText) = 0;
    virtual void providerChanged(const QString &provider) = 0;
};

// assistant.* for a host of windows; their order sets the handles, so keep it stable (the library's)
namespace Assistant {
struct Window {
    QString id;
    Store *store;
    Terminals *terminals;
};
QJsonArray peers(const QList<Window> &windows); // the core's peers: every session, in sidebar order
// performs assistant.show in a window selector ("" for the active window): its error, "" once the chat shows
using Show = std::function<QString(const QString &window)>;
// a send types through the target window's session.type; sink may be null
QJsonObject dispatch(const QJsonObject &request, const QList<Window> &windows, const QStringList &providers, AssistantSink *sink,
                     const Show &show = {});
// every window's workspaces (id, name, window, tint) and sessions (id, name, agent, status, tint), stamped as tree is
QJsonObject directory(const QList<Window> &windows, const QStringList &providers);
QJsonObject stamp(const QJsonObject &treeReply, const QList<Window> &windows, const QStringList &providers);
// an entry as assistant.message {kind, from?, handle?, text}, through the sender's window, else the first
void emitMessage(const QJsonObject &entry, const QList<Window> &windows);
}
