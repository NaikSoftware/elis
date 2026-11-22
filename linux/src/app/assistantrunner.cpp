#include "assistantrunner.h"

#include "library.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QProcessEnvironment>

#include <memory>
#include <signal.h>
#include <sys/prctl.h>

static QStringList strings(const QJsonValue &array)
{
    QStringList out;
    for (const QJsonValue &v : array.toArray())
        out << v.toString();
    return out;
}

AssistantRunner::AssistantRunner(WindowLibrary &library, const QString &stateDir)
    : m_library(library)
    , m_dir(stateDir + QStringLiteral("/assistant"))
{
    connect(qApp, &QCoreApplication::aboutToQuit, this, &AssistantRunner::stop);
}

AssistantRunner::~AssistantRunner()
{
    stop();
}

void AssistantRunner::enqueue(const QString &streamText)
{
    m_queue << streamText;
    pump();
}

void AssistantRunner::providerChanged(const QString &)
{
    stop();
    m_recap = AssistantBridge::recap(); // now, before the next input joins the chat it recaps
    if (m_busy) // the new provider takes the cut turn over
        m_queue.prepend(m_current), m_busy = false;
    pump();
}

void AssistantRunner::pump()
{
    if (m_busy || m_queue.isEmpty() || (m_provider.isEmpty() && !launch()))
        return;
    m_current = m_queue.takeFirst();
    m_busy = true;
    m_ended = false;
    m_text.clear();
    m_turnError.clear();
    QString input = m_current;
    if (m_fresh) {
        input = m_preamble + (m_recap.isEmpty() ? QString() : m_recap + QStringLiteral("\n\n")) + input;
        m_fresh = false;
        m_recap.clear();
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
    const QJsonObject read = AssistantBridge::run({{"cmd", "assistant.provider"}}, QJsonValue::Null, QJsonArray::fromStringList(available));
    const QString provider = read["reply"]["result"]["assistant"]["provider"].toString(available.value(0)); // the choice, else the first detected
    if (provider.isEmpty()) {
        fail(QStringLiteral("no assistant provider installed"));
        return false;
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
    for (const QString &key : env.keys())
        if (key.startsWith(QLatin1String("ELIS_")) || key.startsWith(QLatin1String("CLAUDE")))
            env.remove(key);
    // except the app's own state dir: without it the provider's elisctl would reach the default socket, not this app
    if (qEnvironmentVariableIsSet("ELIS_STATE_DIR"))
        env.insert(QStringLiteral("ELIS_STATE_DIR"), qEnvironmentVariable("ELIS_STATE_DIR"));
    for (auto it = m_environment.begin(); it != m_environment.end(); ++it)
        env.insert(it.key(), it.value().toString());
    QDir().mkpath(m_dir);
    auto *p = new QProcess(this);
    m_proc = p;
    m_lastError.clear();
    p->setProcessEnvironment(env);
    p->setWorkingDirectory(m_dir);
    p->setChildProcessModifier([] { ::prctl(PR_SET_PDEATHSIG, SIGTERM); }); // a crashed app leaves no provider running
    if (m_perInput)
        p->setStandardInputFile(QProcess::nullDevice());
    auto out = std::make_shared<QByteArray>();
    auto read = [this, p, out] {
        *out += p->readAllStandardOutput();
        for (qsizetype i; (i = out->indexOf('\n')) >= 0; out->remove(0, i + 1))
            decoded(QString::fromUtf8(out->left(i)));
    };
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
    if (!m_text.isEmpty())
        Assistant::emitMessage(AssistantBridge::appendAssistant(m_text.join(QStringLiteral("\n\n"))), m_library.assistantWindows());
    m_text.clear();
    m_busy = false;
    if (!error.isEmpty())
        return fail(error); // the chat stores an error only through providerFailed, which drops the queue
    AssistantBridge::turnEnded();
    pump();
}

void AssistantRunner::fail(const QString &message)
{
    m_queue.clear(); // as the chat's count was
    m_busy = false;
    m_text.clear();
    Assistant::emitMessage(AssistantBridge::providerFailed(message), m_library.assistantWindows());
}

void AssistantRunner::stop()
{
    m_provider.clear();
    if (!m_proc)
        return;
    m_proc->disconnect(this);
    m_proc->terminate(); // SIGTERM first, so the provider can end what it started
    if (!m_proc->waitForFinished(2000)) {
        m_proc->kill();
        m_proc->waitForFinished(1000);
    }
    delete m_proc;
}
