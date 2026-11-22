#include "detectedlaunchers.h"

#include "launcher.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QProcess>
#include <QTimer>

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

void DetectedLaunchers::refresh()
{
    if (m_at.isValid() && m_at.secsTo(QDateTime::currentDateTime()) < 300)
        return;
    m_at = QDateTime::currentDateTime();
    auto *proc = new QProcess(this);
    const QString marker = QStringLiteral("elis-launcher-path");
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.remove(QStringLiteral("ELIS_SESSION_ID"));
    proc->setProcessEnvironment(env);
    proc->setStandardInputFile(QProcess::nullDevice());
    auto settle = [this, proc, marker] {
        const QString out = QString::fromUtf8(proc->readAllStandardOutput());
        const int at = out.lastIndexOf(marker + QLatin1Char('\n'));
        const QString shellPath = at < 0 ? QString() : out.mid(at + marker.size() + 1).trimmed();
        const QString path = QStringList{shellPath, qEnvironmentVariable("PATH"), QDir::homePath() + QStringLiteral("/.local/bin")}.join(QLatin1Char(':'));
        found(::availableLaunchers(path, [](const QString &f) { return QFileInfo(f).isExecutable() && QFileInfo(f).isFile(); }), path);
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
