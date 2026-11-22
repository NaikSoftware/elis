#include "detectedlaunchers.h"

#include "launcher.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QProcess>
#include <QTimer>

static const QString marker = QStringLiteral("elis-launcher-path");

DetectedLaunchers *DetectedLaunchers::instance()
{
    static auto *launchers = new DetectedLaunchers(qApp);
    return launchers;
}

void DetectedLaunchers::found(const QStringList &ids, const QString &path)
{
    m_ids = ids;
    m_path = path;
    m_detected = true;
    Q_EMIT changed();
}

void DetectedLaunchers::probed(const QString &shellOutput)
{
    const int at = shellOutput.lastIndexOf(marker + QLatin1Char('\n'));
    if (at < 0 && m_fromShell) // a failed or timed-out probe keeps the PATH an earlier one found
        return;
    m_fromShell = at >= 0;
    const QString shellPath = at < 0 ? QString() : shellOutput.mid(at + marker.size() + 1).trimmed();
    // an empty element would put the current directory on the agents' PATH
    const QString path = QStringList{shellPath, qEnvironmentVariable("PATH"), QDir::homePath() + QStringLiteral("/.local/bin")}
                             .join(QLatin1Char(':'))
                             .split(QLatin1Char(':'), Qt::SkipEmptyParts)
                             .join(QLatin1Char(':'));
    found(::availableLaunchers(path, [](const QString &f) { return QFileInfo(f).isExecutable() && QFileInfo(f).isFile(); }), path);
}

void DetectedLaunchers::refresh()
{
    if (m_at.isValid() && m_at.secsTo(QDateTime::currentDateTime()) < 300)
        return;
    m_at = QDateTime::currentDateTime();
    auto *proc = new QProcess(this);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.remove(QStringLiteral("ELIS_SESSION_ID"));
    proc->setProcessEnvironment(env);
    proc->setStandardInputFile(QProcess::nullDevice());
    auto settle = [this, proc] {
        probed(QString::fromUtf8(proc->readAllStandardOutput()));
        proc->deleteLater();
    };
    connect(proc, &QProcess::finished, this, settle);
    connect(proc, &QProcess::errorOccurred, this, [settle](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart) // no finished follows, and the app's own PATH is still worth a look
            settle();
    });
    QTimer::singleShot(3000, proc, [proc] { proc->kill(); });
    proc->start(qEnvironmentVariable("SHELL", QStringLiteral("/bin/bash")),
                {QStringLiteral("-l"), QStringLiteral("-i"), QStringLiteral("-c"), QStringLiteral("printf '\\n%s\\n' %1; printenv PATH").arg(marker)});
}
