#pragma once

#include "assistant.h"

#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QProcess>
#include <QStringList>
#include <QTimer>

class DetectedLaunchers;
class WindowLibrary;

// The provider behind the Elis chat: a stream provider is one long-lived process, a per-input one a process per input.
// One input per turn, the rest queued here, since the chat counts one turn end per input. Starts on the first input
// once the agents are detected, again after it dies, and stops with the app.
class AssistantRunner : public QObject, public AssistantSink
{
    Q_OBJECT
public:
    AssistantRunner(WindowLibrary &library, const QString &stateDir); // runs what the library's launchers found
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
    void stop(bool wait); // a switch need not wait for the old provider; a quit must

    WindowLibrary &m_library;
    QString m_stateDir;
    DetectedLaunchers &m_launchers;
    QPointer<QProcess> m_proc;
    QString m_provider; // the launched one; empty until the next input launches it
    bool m_perInput = false;
    QJsonObject m_environment;
    QString m_preamble;  // for the first input after a launch
    bool m_fresh = false;
    bool m_recap = false; // after a switch, until a provider has started with the recap
    QStringList m_queue;
    bool m_busy = false; // an input awaits its turn's end
    QString m_current;   // that input
    QStringList m_text;
    bool m_ended = false; // a per-input turn's end arrived before its process exit
    bool m_resumed = false;   // the running process resumes a stored conversation
    bool m_conversed = false; // and it has named its conversation since it started
    QString m_turnError, m_lastError;
    QTimer m_watchdog;
};
