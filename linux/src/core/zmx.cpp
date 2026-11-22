#include "zmx.h"

#include "elis_bridge.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QProcess>
#include <QTimer>

#include <csignal>
#include <unistd.h>

namespace {

QJsonObject taken(char *reply)
{
    const QJsonObject out = QJsonDocument::fromJson(reply ? QByteArray(reply) : QByteArray()).object();
    elis_free(reply);
    return out;
}

QByteArray json(const QJsonObject &o) { return QJsonDocument(o).toJson(QJsonDocument::Compact); }

QJsonObject names(const QString &stateDir, const QStringList &paneIds)
{
    return taken(elis_zmx_names(json({{"stateDir", stateDir}, {"runtimeDir", qEnvironmentVariable("XDG_RUNTIME_DIR")},
                                      {"panes", QJsonArray::fromStringList(paneIds)}}).constData()));
}

// zmx <args> in the state dir's namespace; nullopt when it did not finish in time
std::optional<QByteArray> run(const QString &stateDir, const QStringList &args, const QByteArray &input = {})
{
    const QJsonObject n = names(stateDir, {});
    if (!QFileInfo::exists(n.value("socketDir").toString()))
        return QByteArray(); // no daemon was ever started here, and zmx would make the directory
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    const QJsonObject set = n.value("env").toObject();
    for (auto it = set.begin(); it != set.end(); ++it)
        env.insert(it.key(), it.value().toString());
    QProcess p;
    p.setProcessEnvironment(env);
    p.start(Zmx::executable(), args);
    if (!input.isEmpty() && p.waitForStarted(10000))
        p.write(input);
    p.closeWriteChannel();
    if (!p.waitForFinished(10000)) {
        p.kill();
        p.waitForFinished(1000);
        return std::nullopt;
    }
    if (p.exitStatus() != QProcess::NormalExit || p.exitCode() != 0)
        return std::nullopt;
    return p.readAllStandardOutput();
}

std::optional<double> s_buildCutoff; // recordBuild's, in seconds since the epoch
QHash<QString, int> s_shells; // daemon name -> its shell, from the last listing
qint64 s_listedAt = 0;

} // namespace

namespace Zmx {

QString executable()
{
    // the build tree keeps it beside elis; an install keeps it off PATH, in libexec, as the Mac keeps it in its bundle
    const QString dir = QCoreApplication::applicationDirPath();
    const QString beside = dir + QStringLiteral("/zmx");
    return QFileInfo(beside).isExecutable() ? beside : QDir::cleanPath(dir + QStringLiteral("/" ELIS_LIBEXEC_FROM_BIN "/zmx"));
}

Attach attach(const QString &stateDir, const QString &paneId, const QString &shell, const QString &line, const QString &command, bool claim,
              bool reattaching)
{
    const QJsonObject r = taken(elis_zmx_attach(json({{"zmx", executable()},
                                                      {"stateDir", stateDir},
                                                      {"runtimeDir", qEnvironmentVariable("XDG_RUNTIME_DIR")},
                                                      {"pane", paneId},
                                                      {"shell", shell},
                                                      {"line", line},
                                                      {"command", command},
                                                      {"claim", claim},
                                                      {"reattaching", reattaching}})
                                                     .constData()));
    Attach a;
    a.error = r.value("error").toString();
    a.daemon = r.value("daemon").toString();
    for (const auto &v : r.value("argv").toArray())
        a.argv << v.toString();
    for (const auto &v : r.value("unset").toArray())
        a.unset << v.toString();
    const QJsonObject set = r.value("set").toObject();
    for (auto it = set.begin(); it != set.end(); ++it)
        a.set.insert(it.key(), it.value().toString());
    if (const QString dir = r.value("socketDir").toString(); !dir.isEmpty() && QDir().mkpath(dir))
        QFile::setPermissions(dir, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
    return a;
}

std::optional<QList<Record>> list(const QString &stateDir)
{
    const std::optional<QByteArray> out = run(stateDir, {QStringLiteral("list")});
    if (!out)
        return std::nullopt;
    const QJsonObject r = taken(elis_zmx_list(out->constData()));
    if (!r.value("ok").toBool())
        return std::nullopt;
    QList<Record> records;
    for (const auto &v : r.value("sessions").toArray()) {
        const QJsonObject o = v.toObject();
        records << Record{o.value("name").toString(), o.value("clients").toInt(-1), o.value("pid").toInt(-1)};
    }
    s_shells.clear();
    for (const Record &rec : std::as_const(records))
        if (rec.pid > 0)
            s_shells.insert(rec.name, rec.pid);
    s_listedAt = QDateTime::currentMSecsSinceEpoch();
    return records;
}

QString daemonName(const QString &stateDir, const QString &paneId)
{
    static QHash<QString, QString> cache;
    if (const auto it = cache.constFind(paneId); it != cache.constEnd())
        return *it;
    const QString name = names(stateDir, {paneId}).value("names").toArray().first().toString();
    if (!name.isEmpty())
        cache.insert(paneId, name);
    return name;
}

int shellPid(const QString &stateDir, const QString &paneId)
{
    const QString name = daemonName(stateDir, paneId);
    int pid = s_shells.value(name, -1);
    // a pane that just attached is listed once its daemon is up; one listing a second serves every pane
    if ((pid <= 0 || ::kill(pid, 0) != 0) && QDateTime::currentMSecsSinceEpoch() - s_listedAt > 1000) {
        list(stateDir);
        pid = s_shells.value(name, -1);
    }
    return pid > 0 && ::kill(pid, 0) == 0 ? pid : -1;
}

int foregroundPid(int shellPid)
{
    QFile f(QStringLiteral("/proc/%1/stat").arg(shellPid));
    if (shellPid <= 0 || !f.open(QIODevice::ReadOnly))
        return -1;
    const QByteArray line = f.readAll();
    const QList<QByteArray> fields = line.mid(line.lastIndexOf(')') + 2).split(' '); // state ppid pgrp session tty tpgid
    const int tpgid = fields.size() > 5 ? fields[5].toInt() : -1;
    return tpgid > 0 ? tpgid : shellPid;
}

// ends the named daemons; `zmx kill` signals only each shell's process group, so a foreground job in another group
// gets the hangup a closed terminal sends, then what ignores it ends too
static void end(const QString &stateDir, const QStringList &daemons)
{
    if (daemons.isEmpty())
        return;
    QList<int> jobs;
    list(stateDir); // read before the kill ends their shells
    for (const QString &name : daemons) {
        const int shell = s_shells.value(name, -1), job = foregroundPid(shell);
        if (job > 0 && job != shell)
            jobs << job;
        s_shells.remove(name);
    }
    if (!run(stateDir, QStringList{QStringLiteral("kill")} << daemons << QStringLiteral("--force")))
        qWarning("zmx kill %s failed", qPrintable(daemons.join(QLatin1Char(' '))));
    for (const int job : std::as_const(jobs)) {
        ::kill(-job, SIGHUP);
        QTimer::singleShot(2000, [job] { ::kill(-job, SIGKILL); });
    }
}

void kill(const QString &stateDir, const QStringList &paneIds)
{
    QStringList daemons;
    for (const QString &id : paneIds) {
        daemons << daemonName(stateDir, id);
        forget(id);
    }
    end(stateDir, daemons);
}

void reap(const QString &stateDir, const QString &requestedMode, const std::optional<QStringList> &known)
{
    const std::optional<QByteArray> out = run(stateDir, {QStringLiteral("list")});
    if (!out)
        return; // an unreadable listing kills nothing
    const QJsonObject r = taken(elis_zmx_reap(json({{"list", QString::fromUtf8(*out)},
                                                    {"mode", requestedMode},
                                                    {"known", known ? QJsonValue(QJsonArray::fromStringList(*known)) : QJsonValue()}})
                                                   .constData()));
    QStringList daemons;
    for (const auto &v : r.value("kill").toArray())
        daemons << v.toString();
    end(stateDir, daemons);
}

bool type(const QString &stateDir, const QString &paneId, const QString &text, QString *error)
{
    const QJsonObject paced = taken(elis_zmx_type_bytes(text.toUtf8().constData()));
    const QByteArray head = QByteArray::fromBase64(paced.value("head").toString().toLatin1());
    const QStringList args{QStringLiteral("type"), daemonName(stateDir, paneId)};
    if (!head.isEmpty() && !run(stateDir, args, head))
        return *error = QStringLiteral("the pane's zmx daemon did not accept the input"), false;
    if (paced.value("pacedReturn").toBool()) {
        ::usleep(useconds_t(paced.value("gapMs").toInt() * 1000)); // blocking, so nothing overtakes the Return
        // a failed call does not prove the Return was dropped: the daemon queues before it answers
        if (!run(stateDir, args, QByteArray("\r")))
            return *error = QStringLiteral("text typed, but its final Return could not be confirmed; do not retype the text"), false;
    }
    return true;
}

std::optional<QString> screen(const QString &stateDir, const QString &paneId, bool all, int lines)
{
    QStringList args{QStringLiteral("screen"), daemonName(stateDir, paneId)};
    if (all)
        args << QStringLiteral("--all");
    const std::optional<QByteArray> out = run(stateDir, args);
    const QJsonObject r = out ? taken(elis_zmx_screen(out->constData(), lines)) : QJsonObject();
    if (!r.value("ok").toBool())
        return std::nullopt;
    return r.value("text").toString();
}

static Lead leadFrom(const QJsonObject &o)
{
    return {o.value("report").toBool(), o.value("changed").toBool(), o.value("covered").toBool(), o.value("reattaching").toBool(),
            o.value("role").toString()};
}

Lead report(const QString &paneId, const QString &title)
{
    if (!title.startsWith(QLatin1String("zmx-role;")))
        return {}; // the common case, without a bridge call
    return leadFrom(taken(elis_zmx_lead_report(json({{"pane", paneId}, {"title", title}}).constData())));
}

Lead lead(const QString &paneId)
{
    return leadFrom(taken(elis_zmx_lead_state(paneId.toUtf8().constData())));
}

void forget(const QString &paneId)
{
    elis_zmx_lead_forget(paneId.toUtf8().constData());
}

QJsonObject surface(const QJsonObject &fields)
{
    return taken(elis_zmx_surface(json(fields).constData()));
}

void recordBuild(const QString &stateDir)
{
    QFile stamp(executable() + QStringLiteral(".BUILD"));
    if (!stamp.open(QIODevice::ReadOnly))
        return;
    const QJsonObject r = taken(elis_zmx_build_cutoff(json({{"stateDir", stateDir}, {"buildID", QString::fromUtf8(stamp.readAll())}}).constData()));
    if (r.contains("cutoff"))
        s_buildCutoff = r.value("cutoff").toDouble();
}

QJsonObject phoneAttach(const QString &stateDir, const QString &paneId, bool claim)
{
    QJsonObject args{{"zmx", executable()}, {"stateDir", stateDir}, {"runtimeDir", qEnvironmentVariable("XDG_RUNTIME_DIR")}, {"pane", paneId}, {"claim", claim}};
    if (s_buildCutoff) {
        args.insert("cutoff", *s_buildCutoff);
        if (const std::optional<QByteArray> out = run(stateDir, {QStringLiteral("list")}))
            args.insert("list", QString::fromUtf8(*out));
    }
    return taken(elis_session_attach(json(args).constData()));
}

} // namespace Zmx

