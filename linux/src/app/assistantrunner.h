#pragma once

#include "assistant.h"

#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QProcess>
#include <QStringList>

class WindowLibrary;

// The provider behind the Elis chat: a stream provider is one long-lived process, a per-input one a process per input.
// One input per turn, the rest queued here, since the chat counts one turn end per input. Starts on the first input,
// again after it dies, and stops with the app.
class AssistantRunner : public QObject, public AssistantSink
{
    Q_OBJECT
public:
    AssistantRunner(WindowLibrary &library, const QString &stateDir);
    ~AssistantRunner() override;
    void enqueue(const QString &streamText) override;
    void providerChanged(const QString &provider) override;

private:
    void pump();
    bool launch();
    void spawn(QStringList argv);
    void decoded(const QString &line);
    void endTurn(const QString &error);
    void fail(const QString &message);
    void stop();

    WindowLibrary &m_library;
    QString m_dir;
    QPointer<QProcess> m_proc;
    QString m_provider; // the launched one; empty until the next input launches it
    bool m_perInput = false;
    QJsonObject m_environment;
    QString m_preamble, m_recap; // for the first input after a launch; the recap only after a switch
    bool m_fresh = false;
    QStringList m_queue;
    bool m_busy = false; // an input awaits its turn's end
    QString m_current;   // that input
    QStringList m_text;
    bool m_ended = false; // a per-input turn's end arrived before its process exit
    QString m_turnError, m_lastError;
};
