#include "assistantrunner.h"

#include "detectedlaunchers.h"
#include "library.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QProcessEnvironment>
#include <QStandardPaths>

#include <memory>
#include <signal.h>
#include <sys/prctl.h>

using namespace std::chrono_literals;

static QStringList strings(const QJsonValue &array)
{
    QStringList out;
    for (const QJsonValue &v : array.toArray())
        out << v.toString();
    return out;
}

AssistantRunner::AssistantRunner(WindowLibrary &library, const QString &stateDir)
    : m_library(library)
    , m_stateDir(stateDir)
    , m_launchers(*library.launchers)
{
    connect(qApp, &QCoreApplication::aboutToQuit, this, [this] { stop(true); });
    connect(&m_launchers, &DetectedLaunchers::changed, this, &AssistantRunner::pump); // inputs wait for the first detection
    m_watchdog.setSingleShot(true);
    m_watchdog.setInterval(10min);
    connect(&m_watchdog, &QTimer::timeout, this, [this] {
        stop(false);
        fail(tr("the assistant stopped responding"));
    });
}

AssistantRunner::~AssistantRunner()
{
    stop(true);
}

void AssistantRunner::enqueue(const QString &streamText)
{
    m_queue << streamText;
    pump();
}

void AssistantRunner::providerChanged(const QString &provider)
{
    if (provider == m_provider)
        return;
    stop(false);
    m_recap = true;
    if (m_busy) // the new provider takes the cut turn over
        m_queue.prepend(m_current), m_busy = false;
    pump();
}

void AssistantRunner::pump()
{
    if (m_busy || m_queue.isEmpty() || !m_launchers.detected() || (m_provider.isEmpty() && !launch()))
        return;
    m_current = m_queue.takeFirst();
    m_busy = true;
    m_ended = false;
    m_text.clear();
    m_turnError.clear();
    m_lastError.clear();
    m_watchdog.start();
    QString input = m_current;
    if (m_fresh) {
        const QString recap = m_recap ? AssistantBridge::recap() : QString(); // without the queued inputs, sent anyway
        input = m_preamble + (recap.isEmpty() ? QString() : recap + QStringLiteral("\n\n")) + input;
        m_fresh = false;
    }
    if (!m_perInput) {
        m_proc->write(AssistantBridge::encode(m_provider, input).toUtf8() + '\n');
        return;
    }
    const QJsonValue argv = AssistantBridge::turnArgv(m_provider, input, Assistant::peers(m_library.assistantWindows()));
    if (!argv.isArray())
        return fail(argv["error"].toString());
    spawn(strings(argv));
}

bool AssistantRunner::launch()
{
    const QStringList available = m_library.assistantProviders();
    const QJsonArray providers = QJsonArray::fromStringList(available);
    const QJsonObject saved = AssistantBridge::run({{"cmd", "assistant.provider"}}, QJsonValue::Null, providers);
    QString provider = saved["reply"]["result"]["assistant"]["provider"].toString();
    if (provider.isEmpty()) {
        provider = available.value(0);
        if (provider.isEmpty()) {
            fail(QStringLiteral("no assistant provider installed"));
            return false;
        }
        // saved, so the tree reads it back and a later detection never swaps it; its providerChanged is this launch
        AssistantBridge::run({{"cmd", "assistant.provider"}, {"args", QJsonObject{{"provider", provider}}}}, QJsonValue::Null, providers);
    }
    const QJsonObject launch = AssistantBridge::launch(provider, Assistant::peers(m_library.assistantWindows()));
    if (launch.contains("error")) {
        fail(launch["error"].toString());
        return false;
    }
    m_provider = provider;
    m_perInput = launch["mode"].toString() == QLatin1String("perInput");
    m_environment = launch["environment"].toObject();
    m_preamble = launch["preamble"].toString();
    m_fresh = true;
    if (!m_perInput)
        spawn(strings(launch["argv"]));
    return !m_provider.isEmpty(); // a process that could not start has failed the queue already
}

void AssistantRunner::spawn(QStringList argv)
{
    if (const QStringList standIn = QProcess::splitCommand(qEnvironmentVariable("ELIS_ASSISTANT_PROVIDER_CMD")); !standIn.isEmpty())
        argv = standIn + argv.mid(1); // tests run a fake in the provider binary's place
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    // a parent Claude Code session's markers, which would make the provider its child; CLAUDE_CONFIG_DIR and the rest stay
    static const QStringList markers{"CLAUDECODE",
                                     "CLAUDE_PID",
                                     "CLAUDE_CODE_ENTRYPOINT",
                                     "CLAUDE_CODE_EXECPATH",
                                     "CLAUDE_CODE_CHILD_SESSION",
                                     "CLAUDE_CODE_CHILD_NOTES_DIR",
                                     "CLAUDE_CODE_SESSION_ID",
                                     "CLAUDE_CODE_SESSION_ATTENDED",
                                     "CLAUDE_CODE_SSE_PORT",
                                     "CLAUDE_CODE_MESSAGING_SOCKET",
                                     "CLAUDE_CODE_MESSAGING_TOKEN"};
    for (const QString &key : env.keys())
        if (key.startsWith(QLatin1String("ELIS_")) || markers.contains(key))
            env.remove(key);
    env.insert(QStringLiteral("ELIS_STATE_DIR"), m_stateDir); // the provider's elisctl reaches this app, not the default socket
    // its tools on the PATH that found it, this build's elisctl first, as in every pane
    const QString path = QCoreApplication::applicationDirPath() + QLatin1Char(':') + m_launchers.path();
    env.insert(QStringLiteral("PATH"), path);
    for (auto it = m_environment.begin(); it != m_environment.end(); ++it)
        env.insert(it.key(), it.value().toString());
    if (const QString found = QStandardPaths::findExecutable(argv.value(0), path.split(QLatin1Char(':'), Qt::SkipEmptyParts)); !found.isEmpty())
        argv[0] = found; // QProcess would search the app's PATH
    const QString dir = m_stateDir + QStringLiteral("/assistant");
    QDir().mkpath(dir);
    auto *p = new QProcess(this);
    m_proc = p;
    p->setProcessEnvironment(env);
    p->setWorkingDirectory(dir);
    p->setChildProcessModifier([] { ::prctl(PR_SET_PDEATHSIG, SIGTERM); }); // a crashed app leaves no provider running
    if (m_perInput)
        p->setStandardInputFile(QProcess::nullDevice());
    auto out = std::make_shared<QByteArray>();
    auto read = [this, p, out] {
        *out += p->readAllStandardOutput();
        if (m_busy)
            m_watchdog.start();
        for (qsizetype i; (i = out->indexOf('\n')) >= 0; out->remove(0, i + 1))
            decoded(QString::fromUtf8(out->left(i)));
    };
    connect(p, &QProcess::started, this, [this] { m_recap = false; });
    connect(p, &QProcess::readyReadStandardOutput, this, read);
    connect(p, &QProcess::readyReadStandardError, this, [this, p] {
        if (const QByteArray line = p->readAllStandardError().trimmed().split('\n').last().trimmed(); !line.isEmpty())
            m_lastError = QString::fromUtf8(line);
    });
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError e) {
        if (e != QProcess::FailedToStart) // a crash finishes too, which reports it
            return;
        p->deleteLater();
        m_provider.clear();
        fail(tr("Cannot run %1: %2").arg(p->program(), p->errorString()));
    });
    connect(p, &QProcess::finished, this, [this, p, read](int code, QProcess::ExitStatus status) {
        read();
        p->deleteLater();
        if (!m_perInput)
            m_provider.clear(); // the next input starts it again, resuming its conversation
        if (!m_busy)
            return;
        if (m_perInput && (m_ended || (status == QProcess::NormalExit && code == 0)))
            return endTurn(m_turnError);
        const QString name = QFileInfo(p->program()).fileName();
        const QString why = status == QProcess::CrashExit ? tr("%1 crashed").arg(name) : tr("%1 exited with status %2").arg(name).arg(code);
        fail(m_lastError.isEmpty() ? why : why + QStringLiteral(": ") + m_lastError);
    });
    p->start(argv.value(0), argv.mid(1));
}

void AssistantRunner::decoded(const QString &line)
{
    for (const QJsonValue &e : AssistantBridge::decode(m_provider, line).toArray()) {
        if (!m_busy) // output outside a turn joins no reply
            return;
        if (e["text"].isString())
            m_text << e["text"].toString();
        if (!e["turnEnded"].toBool())
            continue;
        if (m_perInput) // its process exit ends the turn, so no two ever overlap
            m_ended = true, m_turnError = e["error"].toString();
        else
            endTurn(e["error"].toString());
    }
}

void AssistantRunner::endTurn(const QString &error)
{
    const QList<Assistant::Window> windows = m_library.assistantWindows();
    if (!m_text.isEmpty())
        Assistant::emitMessage(AssistantBridge::appendAssistant(m_text.join(QStringLiteral("\n\n"))), windows);
    m_text.clear();
    m_busy = false;
    m_watchdog.stop();
    if (error.isEmpty())
        AssistantBridge::turnEnded();
    else
        Assistant::emitMessage(AssistantBridge::turnFailed(error), windows);
    pump();
}

void AssistantRunner::fail(const QString &message)
{
    m_queue.clear(); // as the chat's count was
    m_busy = false;
    m_text.clear();
    m_watchdog.stop();
    Assistant::emitMessage(AssistantBridge::providerFailed(message), m_library.assistantWindows());
}

void AssistantRunner::stop(bool wait)
{
    m_provider.clear();
    m_watchdog.stop();
    QProcess *p = m_proc;
    if (!p)
        return;
    m_proc = nullptr;
    p->disconnect(this);
    if (p->state() == QProcess::NotRunning) {
        p->deleteLater();
        return;
    }
    p->terminate(); // SIGTERM first, so the provider can end what it started
    if (wait) {
        if (!p->waitForFinished(2000)) {
            p->kill();
            p->waitForFinished(1000);
        }
        delete p;
        return;
    }
    QTimer::singleShot(3000, p, [p] { p->kill(); });
    connect(p, &QProcess::finished, p, &QObject::deleteLater);
}
