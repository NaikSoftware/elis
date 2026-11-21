#pragma once

#include <QJsonObject>
#include <QList>
#include <QMap>
#include <QString>
#include <QStringList>

#include <optional>

// Live restore mode: each main/right pane runs under a zmx daemon (the Mac's patched zmx, staged beside elis) that
// keeps its shell across app restarts. Naming, the attach line, listing, the launch reap and the lead roles are
// ElisCore's, through the bridge; this runs the processes.
namespace Zmx {
QString executable(); // zmx beside the running binary
struct Attach {
    QString daemon, error;
    QStringList argv, unset;     // zmx attach <daemon> [create-only payload]; the variables to drop first
    QMap<QString, QString> set;  // the namespace, the lead nonce and claim, SHELL
};
// `line` runs and returns to the shell, `command` ends the pane; both only when the attach creates the daemon
Attach attach(const QString &stateDir, const QString &paneId, const QString &shell, const QString &line, const QString &command,
              bool claim, bool reattaching = false);
struct Record {
    QString name;
    int clients = -1, pid = -1; // -1: zmx reported none
};
std::optional<QList<Record>> list(const QString &stateDir); // nullopt when the listing cannot be trusted
QString daemonName(const QString &stateDir, const QString &paneId);
int shellPid(const QString &stateDir, const QString &paneId); // the daemon's shell; -1 until zmx lists it
int foregroundPid(int shellPid); // the shell's terminal foreground group (tpgid), the shell itself when idle
// ends each pane's daemon, then hangs up its foreground job; the launch reap ends its daemons the same way
void kill(const QString &stateDir, const QStringList &paneIds);
// the launch reap: zero-client daemons not in `known` (every pane id of every window), or all of them off live;
// `known` nullopt (an unreadable window file) skips a live reap
void reap(const QString &stateDir, const QString &requestedMode, const std::optional<QStringList> &known);

struct Lead {
    bool report = false, changed = false, covered = false, reattaching = false;
    QString role; // leader | follower | unowned; "" before the first report
};
Lead report(const QString &paneId, const QString &title); // report false: an ordinary title
Lead lead(const QString &paneId);
void forget(const QString &paneId);
QJsonObject surface(const QJsonObject &fields); // a tree surfaces[] entry, encoded as the Mac's
}

