// elisctl: drive a running elis over its control socket.
#include "paths.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalSocket>
#include <QLocale>
#include <QSet>
#include <QThread>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <vector>

static const char *usage = R"(usage: elisctl <command> [args] [--target T] [--socket PATH] [--window W] [--json]

  tree                                  workspaces and sessions
  version
  workspace new [name] [--name N] [--collapsed] [--tint COLOR] [--folder DIR]
  workspace rename <name>               (--target: workspace id/prefix/name, default active)
  workspace folder <set DIR|clear>      pin a project folder so session new --cwd under it routes here
  workspace tint <color|clear>          the row, the band around its sessions and their terminals
  session tint <color|clear>            red|orange|yellow|green|blue|purple|gray|teal|pink|brown|indigo|mint, or #rrggbb
  workspace delete | select
  workspace go --to next|prev            the next or previous visible workspace's first session
  workspace collapse | expand
  workspace flag [on|off|toggle]         flag or unflag every session in it
  workspace focus [on|off|toggle|add]   on: mark this one alone and apply the filter; add: mark without narrowing
  workspace filter [on|off|toggle]      apply or suspend the marked set (off keeps it)
  session new [--name N] [--cwd DIR] [--workspace W | --workspace-name N [--create-workspace]]
              [--command CMD] [--no-select] [--parent SESSION]   (--parent makes a companion: session.companion.new)
              [--tint COLOR]
  session close [--undoable]           with the GUI's undo grace when Settings allow it; prints (undoable)|(not undoable)
                                        --target repeats for session close and session move
  session close | select | get          (--target: session id/prefix/name, default $ELIS_SESSION_ID, then active);
                                        get prints the node with its live process details
  session rename <name>                 an empty name unpins it (the running program's title, else "New session")
  session context <text> | --clear      a short line of what the session is about, shown in the title bar
  session reveal                        open the session's folder in the file manager
  session collapse | expand             fold or unfold a parent's companions
  session duplicate [--no-select]
  session duplicate --companion [--no-select]   a companion copying the split layout and each pane's program
  session flag [on|off|toggle]
  session move <workspace> | --to up|down|top|bottom | --after SID | --before SID
  session focus [left|right|other]      move keyboard focus between the split panes
  session scroll <lines> [--pane left|right]   wheel the pane like a mouse over it; negative = up (older)
  session grid <cols>x<rows> | --reset [--pane left|right]   the program's grid apart from the window (a phone's) | back
  session attach [--pane left|right] [--claim] [--json]   mirror a Live pane here; --claim takes its lead
  session resize --split-ratio R | --grow-left D | --grow-right D   (also --grow-top/-bottom/-primary/-split)
  workspace move --to up|down|top|bottom
  session split [on|off|toggle] [--axis vertical|horizontal]
  session split close
  session swap
  font inc|dec|reset [--pane left|right]   the session's terminal font size
  recent list | clear
  recent open [id]                      reopen a closed session (default: the most recent)
  filepanel [show|hide|toggle]          the session folder tree beside the sidebar
  filepanel width <points>              160...560
  notify <body> [--title T]             desktop notification + unseen badge on the session
  session seen                          clear the unseen badge and an --auto-reset status without focusing
  session type <text> | --stdin [--pane left|right]
  session text [--all | --lines N] [--pane left|right]   the visible screen; --all adds the scrollback;
                                        --lines: the last N non-blank rows of screen + scrollback
  session transcript [--pane left|right] [--pane-id ID] [--after N | --before N] [--transcript ID] [--max-bytes N]
                                        a page of the Claude Code conversation the pane runs; pass next as --after
                                        for what was appended, start as --before for older items
  session copy                          the pane's selected text
  session paste [--pane left|right]     paste the clipboard into the pane
  session select-all
  session search [needle] [--next | --prev | --close]   Konsole's search bar; prints the match count
  surface zoom [show|hide|toggle] [--target active|surface:<session>:left|right]
  session status <idle|active|completed|blocked> [--auto-reset] [--blink] [--if-idle]
  session go --to next|prev|first|last|next-attention|prev-attention
  sidebar [show|hide|toggle]
  sidebar mode [tree|flagged|toggle]
  sidebar flagged-layout [flat|plain|tree|toggle]
  sidebar density [default|compact|toggle]
  sidebar expand | collapse              every workspace (collapse keeps the current one open)
  sidebar width <points>                160...560
  settings keep-awake [on|off|toggle]   no idle sleep while an agent's status is active
  events [--kind K]... [--run ID --after SEQ] [--limit N]   follow control events (--json: one event per line)
  pick [open] [--prompt T] [--query T] [--select ID] [--allow-custom] [--follow] [--no-block]
                                        items from stdin: lines, or a JSON array of {id,label,subtitle};
                                        waits and prints the outcome JSON (exit 0 picked/custom, 2 cancelled)
  pick result <id> | cancel <id>
  ask [open] <title> [--message T] [--button ID=LABEL]... [--hotkey ID=LETTER]... [--default ID]
             [--destructive ID] [--cancel ID] [--style terminal|gui] [--align left|center|right] [--width N]
             [--input line|multiline [--value T] [--placeholder T]]
             [--choice ID=LABEL... [--choice-subtitle ID=TEXT]... [--multiple] [--checked ID]... [--other PH]]
             [--pane left|right] [--follow] [--no-block]   exit 0 answered, 2 cancelled, 3 escaped
  ask result <id> | cancel <id>
  msg send <text>|--stdin (--to SESSION:PANE... | --all [--workspace W]) [--as SESSION:PANE-ID]
  msg read [--ack] [--wait [--timeout S]] [--as SESSION:PANE-ID]   identity defaults to $ELIS_SESSION_ID:$ELIS_PANE_ID
  msg ack <id>... [--as SESSION:PANE-ID]
  assistant ask <text> [--wait [--timeout N]]
  assistant send --to TAG... <text>|--stdin
  assistant read [--last N]
  assistant provider [NAME]
  assistant show [--window W]
  assistant seen
  reply <text>|--stdin                   reply to the assistant from inside an Elis session ($ELIS_SESSION_ID)
  keymap reload | list                  re-read keymap.conf; show what each built-in and custom command is bound to
  keymap run <name>                     start a custom command for the target session
  hooks reload | list                   re-read hooks.conf; show each hook's live state
  theme list                            Konsole colour schemes (* = current)
  theme set [name]                      no name: back to the Konsole profile's own scheme
  session overlay open <command> [--cwd DIR] [--wait | --block] [--size-percent N [--width PT] [--height PT]]
                       [--background-color #rrggbb] [--follow] [--pane left|right]
                                        a program over the session (full, floating, or one pane); closes when it exits
  session overlay close | result | copy | text [--lines N] [--pane left|right]
  session overlay hide | show | toggle [--pane left|right]
  session overlay resize (--size-percent N [--width PT] [--height PT] | --width PT | --height PT | --full)
  session hud [open] <message> | --file F [--markdown] [--font-size PT] [--detail T] [--spinner] [--spinner-style S]
              [--position P] [--background-color #rrggbb] [--text-color #rrggbb] [--size-percent N] [--sticky] [--no-frame]
              [--hide-after SECONDS] [--pane left|right]      a passive panel; the session stays typable
  session hud update <message> ...      replaces the whole panel (font size and background stay)
  session hud close
  dashboard <id[:left|:right]>… | --mru [--font-size N | --auto-size]   up to 9 live panes in a view-only grid
  dashboard --close
  window new [name] [--minimized] | list
  window select | close | delete | zoom | fullscreen [id]    (id, unique prefix, or active)
  window rename <id> <name>
  window go --to next|prev
  window resize [id] --width W --height H
  window move [id] --x X --y Y [--display N]   refused on Wayland, which does not let apps place windows
  window minimize [id] [on|off|toggle]
  --window W                            address a session/workspace/tree command to that window (default: frontmost)
  mobile serve [--port N] [--bind ADDR] [--host NAME] [--no-qr] [--no-bluetooth]
                                        let the elis Mobile app drive this elis over TLS (default port 8765) or Bluetooth;
                                        prints a pairing QR code and link (--host: the address put in it)
  mobile reset                          new pairing token: phones paired before are cut off
  phone status | link [--qr]            the app's phone relay: on/listening/port/address; link prints the pairing link
  phone on | off | toggle               start or stop it (answers once it listens or fails)
  phone port <N> | host <HOST> | host --auto   its port (1024-65535), the address its link names, or the best guess
  phone revoke                          new pairing token, the relay restarts while on
  restore mode [none|rerun|live]        bare: configured / at launch / active; a mode applies from the next launch
  restore capture                       record each pane's foreground command now (rerun mode)
  restore clear                         forget every captured command
  session restore <command> | --none | --clear [--pane left|right]   pin what this pane re-runs (rerun mode)

Not in elis (the app answers "<cmd> is not supported on this platform"): zmx, session restart/lead/background/page,
surface cursor, config reload, browser, page overlays and companions, quick terminal, scratch terminal.
)";

static QByteArray roundTrip(const QString &path, const QJsonObject &request, QString *error)
{
    QLocalSocket socket;
    socket.connectToServer(path);
    if (!socket.waitForConnected(3000))
        return *error = QStringLiteral("cannot connect to %1: %2 (is Elis running?)").arg(path, socket.errorString()), QByteArray();
    socket.write(QJsonDocument(request).toJson(QJsonDocument::Compact) + '\n');
    QByteArray line;
    while (!line.endsWith('\n') && socket.waitForReadyRead(30000))
        line += socket.readAll();
    line += socket.readAll();
    if (line.trimmed().isEmpty())
        *error = QStringLiteral("no response from %1").arg(path);
    return line.trimmed().isEmpty() ? QByteArray() : line;
}

static int die(const QString &message)
{
    fprintf(stderr, "elisctl: %s\n", qPrintable(message));
    return 1;
}

static QJsonObject exchange(const QString &path, const QJsonObject &req, QString *error)
{
    const QByteArray line = roundTrip(path, req, error);
    return line.isEmpty() ? QJsonObject() : QJsonDocument::fromJson(line).object();
}

// pick / ask without --no-block: poll the result by id, print it as bare JSON, exit by outcome; an abandoned wait cancels
static int awaitOutcome(const QString &path, const QString &kind, const QString &id)
{
    static const QHash<QString, int> codes{{"picked", 0}, {"custom", 0}, {"answered", 0}, {"cancelled", 2}, {"escaped", 3}};
    for (int polls = 0;; ++polls) {
        QString error;
        const QJsonObject r = exchange(path, {{"cmd", kind + QStringLiteral(".result")}, {"target", id}}, &error);
        const QJsonObject outcome = r.value("result").toObject().value(kind).toObject();
        if (!r.value("ok").toBool() || outcome.isEmpty()) {
            exchange(path, {{"cmd", kind + QStringLiteral(".cancel")}, {"target", id}}, &error);
            return die(r.value("error").toString(error));
        }
        if (outcome.value("result").toString() != QLatin1String("pending")) {
            printf("%s\n", QJsonDocument(outcome).toJson(QJsonDocument::Compact).constData());
            return codes.value(outcome.value("result").toString(), 1);
        }
        QThread::msleep(polls < 10 ? 100 : 500);
    }
}

static QString foldLine(const QString &text)
{
    QString out;
    bool pendingSpace = false;
    for (const QChar ch : text) {
        if (ch.isSpace() || ch.category() == QChar::Other_Control) {
            pendingSpace = true;
        } else {
            if (pendingSpace && !out.isEmpty())
                out.append(QLatin1Char(' '));
            pendingSpace = false;
            out.append(ch);
        }
    }
    return out;
}

static QString formatAssistantEntry(const QJsonObject &entry)
{
    const QDateTime dt = QDateTime::fromMSecsSinceEpoch(qint64(entry.value("ts").toDouble() * 1000));
    const QString time = QLocale::c().toString(dt, QStringLiteral("HH:mm"));
    const QString from = entry.value("from").toString();
    const QString sender = from.isEmpty() ? QString() : QStringLiteral(" @") + from;
    return QStringLiteral("%1 %2%3: %4").arg(time, entry.value("kind").toString(), sender, entry.value("text").toString());
}

static QString readStdinUtf8(QString *error)
{
    QFile f;
    if (!f.open(stdin, QIODevice::ReadOnly))
        return *error = QStringLiteral("cannot read stdin"), QString();
    const QByteArray raw = f.readAll();
    const QString text = QString::fromUtf8(raw);
    if (text.toUtf8() != raw)
        return *error = QStringLiteral("stdin must be valid UTF-8"), QString();
    return text;
}

static QString canonicalSocket(const QString &p)
{
    const QFileInfo fi(QFileInfo(p).absoluteFilePath());
    const QString dir = fi.dir().canonicalPath();
    return (dir.isEmpty() ? fi.absolutePath() : dir) + QLatin1Char('/') + fi.fileName();
}

static int emitAssistantReply(const QByteArray &line, const QJsonObject &response, bool json)
{
    const bool ok = response.value("ok").toBool();
    if (json) {
        fputs(line.constData(), stdout);
        if (!line.endsWith('\n'))
            putchar('\n');
        return ok ? 0 : 1;
    }
    if (!ok)
        return die(response.value("error").toString());
    return -1;
}

static int runAssistant(const QString &cmd, const QStringList &pos, const QHash<QString, QString> &opt, const QHash<QString, QStringList> &multi)
{
    const QString path = opt.value(QStringLiteral("socket"), socketPath());
    const bool json = opt.contains(QStringLiteral("json"));
    QString error;

    if (cmd == QLatin1String("assistant.ask")) {
        if (pos.isEmpty())
            return die(QStringLiteral("provide message text"));
        const bool wait = opt.contains(QStringLiteral("wait"));
        const bool hasTimeout = opt.contains(QStringLiteral("timeout"));
        double timeoutSec = 0;
        if (hasTimeout) {
            if (!wait)
                return die(QStringLiteral("--timeout needs --wait"));
            bool ok = false;
            timeoutSec = opt.value(QStringLiteral("timeout")).toDouble(&ok);
            if (!ok || !std::isfinite(timeoutSec) || timeoutSec <= 0)
                return die(QStringLiteral("--timeout must be a positive number of seconds"));
        }
        const QByteArray line = roundTrip(path, {{"cmd", "assistant.ask"}, {"args", QJsonObject{{"text", pos.first()}}}}, &error);
        if (line.isEmpty())
            return die(error);
        const QJsonObject posted = QJsonDocument::fromJson(line).object();
        if (!posted.value("ok").toBool() || !wait) {
            if (const int rc = emitAssistantReply(line, posted, json); rc >= 0)
                return rc;
            return puts("ok"), 0;
        }
        const QString postedId = posted["result"]["assistant"]["entries"].toArray().first().toObject().value("id").toString();
        QElapsedTimer timer;
        timer.start();
        const qint64 timeoutMs = hasTimeout ? qMax<qint64>(1, qRound64(timeoutSec * 1000.0)) : -1;
        for (int pendingPolls = 0;;) {
            if (timeoutMs >= 0 && timer.elapsed() >= timeoutMs)
                return fputs("timed out\n", stderr), 124;
            const QByteArray treeLine = roundTrip(path, {{"cmd", "tree"}}, &error);
            if (treeLine.isEmpty())
                return die(error);
            const QJsonObject treeResp = QJsonDocument::fromJson(treeLine).object();
            if (!treeResp.value("ok").toBool())
                return emitAssistantReply(treeLine, treeResp, json);
            if (!treeResp["result"]["tree"]["assistant"]["running"].toBool())
                break;
            ++pendingPolls;
            const qint64 delayMs = pendingPolls <= 10 ? 100 : 500;
            if (timeoutMs >= 0) {
                const qint64 left = timeoutMs - timer.elapsed();
                if (left <= 0)
                    return fputs("timed out\n", stderr), 124;
                QThread::msleep(qMin(delayMs, left));
            } else {
                QThread::msleep(delayMs);
            }
        }
        const QByteArray readLine = roundTrip(path, {{"cmd", "assistant.read"}}, &error);
        if (readLine.isEmpty())
            return die(error);
        const QJsonObject readResp = QJsonDocument::fromJson(readLine).object();
        if (const int rc = emitAssistantReply(readLine, readResp, json); rc >= 0)
            return rc;
        if (postedId.isEmpty())
            return puts("ok"), 0;
        const QJsonArray all = readResp["result"]["assistant"]["entries"].toArray();
        qsizetype start = 0;
        for (qsizetype i = all.size() - 1; i >= 0; --i)
            if (all[i].toObject().value("id").toString() == postedId) {
                start = i + 1;
                break;
            }
        if (start >= all.size())
            return puts("ok"), 0;
        for (qsizetype i = start; i < all.size(); ++i)
            printf("%s\n", qPrintable(formatAssistantEntry(all[i].toObject())));
        return 0;
    }

    if (cmd == QLatin1String("assistant.send")) {
        const QStringList recipients = multi.value(QStringLiteral("to"));
        if (recipients.isEmpty())
            return die(QStringLiteral("provide at least one --to tag"));
        const bool hasStdin = opt.contains(QStringLiteral("stdin"));
        if (pos.isEmpty() == !hasStdin)
            return die(QStringLiteral("provide the message as TEXT or --stdin, exactly one"));
        const QString body = hasStdin ? readStdinUtf8(&error) : pos.first();
        if (hasStdin && !error.isEmpty())
            return die(error);
        const QJsonObject req{{"cmd", "assistant.send"}, {"args", QJsonObject{{"text", body}, {"recipients", QJsonArray::fromStringList(recipients)}}}};
        const QByteArray line = roundTrip(path, req, &error);
        if (line.isEmpty())
            return die(error);
        const QJsonObject resp = QJsonDocument::fromJson(line).object();
        const QJsonObject a = resp["result"]["assistant"].toObject();
        const QJsonArray deliveredArr = a["delivered"].toArray();
        if (json) {
            fputs(line.constData(), stdout);
            if (!line.endsWith('\n'))
                putchar('\n');
            return (!resp.value("ok").toBool() || deliveredArr.isEmpty()) ? 1 : 0;
        }
        if (!resp.value("ok").toBool())
            return die(resp.value("error").toString());
        for (const auto &v : a["skipped"].toArray()) {
            const QJsonObject s = v.toObject();
            fprintf(stderr, "skipped %s: %s\n", qPrintable(s["handle"].toString()), qPrintable(s["reason"].toString()));
        }
        if (deliveredArr.isEmpty())
            return fputs("nothing was delivered\n", stderr), 1;
        QStringList delivered;
        for (const auto &v : deliveredArr)
            delivered << v.toString();
        return printf("delivered: %s\n", qPrintable(delivered.join(QStringLiteral(", ")))), 0;
    }

    if (cmd == QLatin1String("assistant.read")) {
        QJsonObject args;
        if (opt.contains(QStringLiteral("last"))) {
            bool ok = false;
            const int last = opt.value(QStringLiteral("last")).toInt(&ok);
            if (!ok || last < 1)
                return die(QStringLiteral("--last must be a positive integer"));
            args.insert("last", last);
        }
        const QJsonObject req = args.isEmpty() ? QJsonObject{{"cmd", "assistant.read"}} : QJsonObject{{"cmd", "assistant.read"}, {"args", args}};
        const QByteArray line = roundTrip(path, req, &error);
        if (line.isEmpty())
            return die(error);
        const QJsonObject resp = QJsonDocument::fromJson(line).object();
        if (const int rc = emitAssistantReply(line, resp, json); rc >= 0)
            return rc;
        for (const auto &v : resp["result"]["assistant"]["entries"].toArray())
            printf("%s\n", qPrintable(formatAssistantEntry(v.toObject())));
        return 0;
    }

    if (cmd == QLatin1String("assistant.provider")) {
        QJsonObject args;
        if (!pos.isEmpty())
            args.insert("provider", pos.first());
        const QJsonObject req = args.isEmpty() ? QJsonObject{{"cmd", "assistant.provider"}} : QJsonObject{{"cmd", "assistant.provider"}, {"args", args}};
        const QByteArray line = roundTrip(path, req, &error);
        if (line.isEmpty())
            return die(error);
        const QJsonObject resp = QJsonDocument::fromJson(line).object();
        if (const int rc = emitAssistantReply(line, resp, json); rc >= 0)
            return rc;
        const QJsonObject a = resp["result"]["assistant"].toObject();
        const QString current = a["provider"].toString();
        printf("current: %s\n", qPrintable(current.isEmpty() ? QStringLiteral("none") : current));
        QStringList providers;
        for (const auto &v : a["providers"].toArray())
            providers << v.toString();
        if (!providers.isEmpty())
            printf("available: %s\n", qPrintable(providers.join(QStringLiteral(", "))));
        return 0;
    }

    if (cmd == QLatin1String("assistant.show")) {
        QJsonObject args;
        if (opt.contains(QStringLiteral("window")))
            args.insert("window", opt.value(QStringLiteral("window")));
        const QJsonObject req = args.isEmpty() ? QJsonObject{{"cmd", "assistant.show"}} : QJsonObject{{"cmd", "assistant.show"}, {"args", args}};
        const QByteArray line = roundTrip(path, req, &error);
        if (line.isEmpty())
            return die(error);
        const QJsonObject resp = QJsonDocument::fromJson(line).object();
        if (const int rc = emitAssistantReply(line, resp, json); rc >= 0)
            return rc;
        return puts("ok"), 0;
    }

    if (cmd == QLatin1String("assistant.seen")) {
        const QByteArray line = roundTrip(path, {{"cmd", "assistant.seen"}}, &error);
        if (line.isEmpty())
            return die(error);
        if (const int rc = emitAssistantReply(line, QJsonDocument::fromJson(line).object(), json); rc >= 0)
            return rc;
        return puts("ok"), 0;
    }

    if (cmd == QLatin1String("assistant.reply")) {
        const bool hasStdin = opt.contains(QStringLiteral("stdin"));
        if (pos.isEmpty() == !hasStdin)
            return die(QStringLiteral("provide the reply as TEXT or --stdin, exactly one"));
        QString session = qEnvironmentVariable("ELIS_SESSION_ID");
        const QString paneSocket = qEnvironmentVariable("ELIS_SOCKET");
        if (!paneSocket.isEmpty() && canonicalSocket(paneSocket) != canonicalSocket(path))
            session.clear();
        if (session.isEmpty())
            return fputs("elisctl reply runs inside an Elis session\n", stderr), 1;
        const QString body = hasStdin ? readStdinUtf8(&error) : pos.first();
        if (hasStdin && !error.isEmpty())
            return die(error);
        const QByteArray line = roundTrip(path, {{"cmd", "assistant.reply"}, {"target", session}, {"args", QJsonObject{{"text", body}}}}, &error);
        if (line.isEmpty())
            return die(error);
        const QJsonObject resp = QJsonDocument::fromJson(line).object();
        if (const int rc = emitAssistantReply(line, resp, json); rc >= 0)
            return rc;
        return puts("ok"), 0;
    }

    return die(QStringLiteral("unknown assistant command '%1'").arg(cmd));
}

static QString eventLine(const QJsonObject &e)
{
    const QJsonObject p = e.value("payload").toObject();
    const QString kind = e.value("kind").toString(), name = p.value("name").toString(e.value("window").toString(QStringLiteral("-")));
    QString line = QDateTime::fromMSecsSinceEpoch(qint64(e.value("ts").toDouble() * 1000)).toString(QStringLiteral("HH:mm:ss ")) + kind;
    if (kind == QLatin1String("app.launched"))
        return line;
    if (kind == QLatin1String("assistant.message")) {
        const QString msgKind = p.value("kind").toString();
        const QString handle = p.value("handle").toString();
        const QString from = p.value("from").toString();
        const QString sender = !handle.isEmpty() ? handle : !from.isEmpty() ? from : QStringLiteral("-");
        return line + QStringLiteral(" kind=%1 from=%2 %3").arg(msgKind.isEmpty() ? QStringLiteral("-") : msgKind, sender, foldLine(p.value("text").toString()).left(80));
    }
    if (kind.startsWith(QLatin1String("phone."))) { // app-wide: no window or session to name
        line += QStringLiteral(" ip=") + p.value("ip").toString(QStringLiteral("-"));
        return QStringList{"phone.connected", "phone.disconnected", "phone.refused"}.contains(kind)
                   ? line
                   : line + QStringLiteral(" pane-id=") + p.value("paneID").toString(QStringLiteral("-"));
    }
    line += QLatin1Char(' ') + name;
    if (kind == QLatin1String("status")) {
        line += QLatin1Char(' ') + p.value("status").toString();
        for (const char *k : {"previous", "pane", "color", "shape"})
            if (p.contains(QLatin1String(k)))
                line += QStringLiteral(" %1=%2").arg(QLatin1String(k), p.value(QLatin1String(k)).toString());
        if (p.value("blink").toBool())
            line += QStringLiteral(" blink");
    } else if (kind == QLatin1String("notify")) {
        line += QStringLiteral(" %1: %2").arg(p.value("title").toString(), p.value("body").toString());
    } else if (kind == QLatin1String("session.created") && p.contains("parent")) {
        line += QStringLiteral(" parent=") + p.value("parent").toString();
    } else if (kind == QLatin1String("session.selected")) {
        line += QStringLiteral(" previous=") + p.value("previous").toString(QStringLiteral("-"));
    } else if (kind.startsWith(QLatin1String("pane.")) && kind != QLatin1String("pane.focused")) {
        line += QLatin1Char(' ') + p.value("status").toString();
    } else if (kind == QLatin1String("pane.focused")) {
        line += QStringLiteral(" %1 pane-id=%2").arg(p.value("pane").toString(), p.value("paneID").toString(QStringLiteral("-")));
    } else if (kind == QLatin1String("message")) {
        line += QStringLiteral(" pane-id=%1 from=%2 id=%3").arg(p.value("paneID").toString(QStringLiteral("-")), p.value("from").toString(QStringLiteral("-")),
                                                              p.value("messageID").toString(QStringLiteral("-")));
    }
    return line;
}

// elisctl events: polls events.read, keeping the cursor; a restart of the app ends the stream with its error
static int followEvents(const QString &path, QJsonObject args, bool json)
{
    int backoff = 250, waited = 0;
    for (;;) {
        QString error;
        const QJsonObject r = exchange(path, {{"cmd", "events.read"}, {"args", args}}, &error);
        if (r.isEmpty()) {
            if (!args.contains("run") || waited >= 30000) // reconnect only while holding a cursor
                return die(error);
            QThread::msleep(backoff);
            waited += backoff;
            backoff = qMin(backoff * 2, 4000);
            continue;
        }
        backoff = 250, waited = 0;
        if (!r.value("ok").toBool())
            return die(r.value("error").toString());
        const QJsonObject events = r.value("result").toObject().value("events").toObject();
        const QJsonArray items = events.value("items").toArray();
        for (const auto &v : items)
            printf("%s\n", json ? QJsonDocument(v.toObject()).toJson(QJsonDocument::Compact).constData() : qPrintable(eventLine(v.toObject())));
        fflush(stdout);
        args.insert("run", events.value("run"));
        args.insert("after", QString::number(events.value("next").toInteger()));
        if (items.isEmpty())
            QThread::msleep(250);
    }
}

// ID=VALUE, or a bare token used as both
static std::pair<QString, QString> pairOf(const QString &token)
{
    const qsizetype eq = token.indexOf(QLatin1Char('='));
    return eq < 0 ? std::pair{token, token} : std::pair{token.left(eq), token.mid(eq + 1)};
}

// relative paths resolve against the caller's cwd before crossing the socket
static QString callerPath(const QString &path)
{
    if (path.trimmed().isEmpty() || path.startsWith(QLatin1Char('/')) || path.startsWith(QLatin1Char('~')))
        return path;
    return QDir::cleanPath(QDir::current().absoluteFilePath(path));
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    const bool attach = argc >= 3 && std::strcmp(argv[1], "session") == 0 && std::strcmp(argv[2], "attach") == 0;
    const bool phone = argc >= 2 && std::strcmp(argv[1], "phone") == 0;
    if (attach || phone || (argc >= 2 && std::strcmp(argv[1], "mobile") == 0)) {
        // the Swift elisctl owns attach, mobile and phone (the Mac's parsing, output and `link --qr`); both sides get
        // the state dir explicitly (paths.h and ControlResolve differ)
        const QString dir = QCoreApplication::applicationDirPath();
        const QString buildHelper = dir + QStringLiteral("/helper/elisctl");
        const QString helper = QFileInfo(buildHelper).isExecutable()
            ? buildHelper
            : QDir::cleanPath(dir + QStringLiteral("/" ELIS_LIBEXEC_FROM_BIN "/elisctl"));
        const QByteArray helperPath = QFile::encodeName(helper);
        const QByteArray state = QFile::encodeName(stateDir());
        const QByteArray sock = QFile::encodeName(socketPath());
        ::setenv("ELIS_STATE_DIR", state.constData(), 1);
        std::vector<char *> execArgs{const_cast<char *>(helperPath.constData())};
        bool hasSocket = false;
        for (int i = 1; i < argc; ++i) {
            hasSocket = hasSocket || std::strcmp(argv[i], "--socket") == 0 || std::strncmp(argv[i], "--socket=", 9) == 0;
            execArgs.push_back(argv[i]);
        }
        // only the commands that reach the app take --socket; mobile reset touches the state dir alone
        if (!hasSocket && (attach || (argc >= 3 && (phone || std::strcmp(argv[2], "serve") == 0)))) {
            execArgs.push_back(const_cast<char *>("--socket"));
            execArgs.push_back(const_cast<char *>(sock.constData()));
        }
        execArgs.push_back(nullptr);
        ::execv(helperPath.constData(), execArgs.data());
        fprintf(stderr, "elisctl: cannot run %s: %s\n", helperPath.constData(), std::strerror(errno));
        return 1;
    }
    const QStringList flags{"json", "stdin", "all", "no-select", "create-workspace", "auto-reset", "blink", "if-idle", "undoable", "companion",
                            "wait", "block", "follow", "full", "markdown", "sticky", "no-frame", "spinner", "none", "clear", "mru", "auto-size", "close", "minimized",
                            "next", "prev", "allow-custom", "no-block", "multiple", "ack", "reset", "collapsed", "page"};
    QStringList pos;
    QHash<QString, QString> opt;
    QHash<QString, QStringList> multi; // every value of a repeatable option, in order
    const QStringList in = app.arguments().mid(1);
    for (int i = 0; i < in.size(); ++i) {
        if (!in[i].startsWith(QLatin1String("--"))) {
            pos << in[i];
            continue;
        }
        const QString name = in[i].mid(2);
        if (name == QLatin1String("help"))
            return fputs(usage, stdout), 0;
        if (flags.contains(name))
            opt.insert(name, QStringLiteral("1"));
        else if (i + 1 < in.size())
            opt.insert(name, in[++i]), multi[name] << in[i];
        else
            return die(QStringLiteral("--%1 needs a value").arg(name));
    }
    if (pos.isEmpty())
        return fputs(usage, stderr), 1;

    QString cmd = pos.takeFirst();
    if (cmd == QLatin1String("reply"))
        cmd = QStringLiteral("assistant.reply");
    else if (QStringList{"workspace", "session", "recent", "font", "keymap", "hooks", "theme", "restore", "window", "surface", "config", "msg", "assistant", "zmx", "browser", "quick", "settings"}
                 .contains(cmd)
             && !pos.isEmpty())
        cmd += QLatin1Char('.') + pos.takeFirst();
    if (cmd == QLatin1String("assistant"))
        return die(QStringLiteral("missing assistant subcommand"));
    if (cmd.startsWith(QLatin1String("assistant.")))
        return runAssistant(cmd, pos, opt, multi);
    // a verb whose bare form is a command of its own takes only its known subcommands
    static const QHash<QString, QStringList> subs{{"pick", {"open", "result", "cancel"}}, {"ask", {"open", "result", "cancel"}},
                                                   {"sidebar", {"mode", "flagged-layout", "density", "expand", "collapse", "width"}}};
    if (subs.contains(cmd))
        cmd += subs[cmd].contains(pos.value(0)) ? QLatin1Char('.') + pos.takeFirst() : cmd == QLatin1String("sidebar") ? QString() : QStringLiteral(".open");
    if (cmd == QLatin1String("events"))
        cmd = QStringLiteral("events.read");
    if (cmd == QLatin1String("session.select-all"))
        cmd = QStringLiteral("session.selectall");
    if (cmd == QLatin1String("session.new") && opt.contains(QStringLiteral("parent")))
        cmd = QStringLiteral("session.companion.new");
    if (cmd == QLatin1String("filepanel") && pos.value(0) == QLatin1String("width"))
        cmd = QStringLiteral("filepanel.width"), pos.removeFirst();
    if (cmd == QLatin1String("session.duplicate") && opt.contains(QStringLiteral("companion")))
        cmd = QStringLiteral("session.companion.duplicate");
    if (cmd == QLatin1String("session.overlay") && !pos.isEmpty())
        cmd += QLatin1Char('.') + pos.takeFirst();
    if (cmd == QLatin1String("session.overlay.open") && opt.contains(QStringLiteral("page")))
        cmd = QStringLiteral("session.page");
    else if (cmd == QLatin1String("session.overlay.open") && opt.contains(QStringLiteral("companion")))
        cmd = QStringLiteral("session.companion.page");
    if (cmd == QLatin1String("session.hud"))
        cmd += QStringList{"open", "update", "close"}.contains(pos.value(0)) ? QLatin1Char('.') + pos.takeFirst() : QStringLiteral(".open");
    if (cmd == QLatin1String("session.split") && pos.value(0) == QLatin1String("close"))
        cmd = QStringLiteral("session.split.close"), pos.removeFirst();
    const QString arg = pos.value(0);

    QJsonObject args;
    auto copy = [&](const char *from, const char *to) {
        if (opt.contains(QLatin1String(from)))
            args.insert(QLatin1String(to), opt.value(QLatin1String(from)));
    };
    auto flag = [&](const char *from, const char *to) {
        if (opt.contains(QLatin1String(from)))
            args.insert(QLatin1String(to), true);
    };
    copy("name", "name");
    copy("cwd", "cwd");
    copy("workspace", "workspace");
    copy("workspace-name", "workspaceName");
    copy("command", "command");
    copy("to", "to");
    copy("after", "after");
    copy("before", "before");
    copy("title", "title");
    copy("parent", "parent");
    copy("body", "body");
    copy("pane", "pane");
    flag("create-workspace", "createWorkspace");
    flag("no-select", "noSelect");
    flag("auto-reset", "autoReset");
    flag("blink", "blink");
    flag("if-idle", "ifIdle");
    flag("undoable", "undoable");
    if (opt.contains(QStringLiteral("lines")))
        args.insert("lines", opt.value(QStringLiteral("lines")).toInt());
    if (cmd == QLatin1String("filepanel.width")) {
        bool number = false;
        const double w = arg.toDouble(&number);
        if (!number)
            return die(QStringLiteral("points must be a number"));
        args.insert("filePanelWidth", w);
    }
    if (cmd == QLatin1String("session.scroll"))
        args.insert("lines", arg.toInt());
    if (cmd == QLatin1String("session.grid")) {
        if (opt.contains(QStringLiteral("reset")))
            args.insert("reset", true);
        else if (const QStringList cr = arg.split(QLatin1Char('x')); cr.size() == 2)
            args.insert("columns", cr[0].toInt()), args.insert("rows", cr[1].toInt());
    }
    if (cmd == QLatin1String("filepanel"))
        args.insert("mode", arg.isEmpty() ? QStringLiteral("toggle") : arg);
    if (QStringList{"session.flag", "session.split", "workspace.focus", "workspace.filter"}.contains(cmd))
        args.insert("mode", arg.isEmpty() ? QStringLiteral("toggle") : arg);
    copy("axis", "axis");
    if (cmd == QLatin1String("workspace.new")) {
        if (!args.contains("name") && !arg.isEmpty())
            args.insert("name", arg);
        flag("collapsed", "collapsed");
        if (opt.contains(QStringLiteral("folder")))
            args.insert("folder", callerPath(opt.value(QStringLiteral("folder"))));
    }
    if (cmd == QLatin1String("workspace.folder")) {
        if (arg != QLatin1String("set") && arg != QLatin1String("clear"))
            return die(QStringLiteral("mode must be set or clear"));
        args.insert("mode", arg);
        if (!pos.value(1).isEmpty())
            args.insert("folder", callerPath(pos.value(1)));
        else if (opt.contains(QStringLiteral("folder")))
            args.insert("folder", callerPath(opt.value(QStringLiteral("folder"))));
    }
    if (cmd == QLatin1String("session.move") && !arg.isEmpty())
        args.insert("workspace", arg);
    if (cmd == QLatin1String("keymap.run") || cmd == QLatin1String("theme.set"))
        args.insert("name", arg);
    if (cmd.endsWith(QLatin1String(".rename")))
        args.insert("name", arg);
    if (cmd == QLatin1String("session.status"))
        args.insert("status", arg);
    if (cmd.endsWith(QLatin1String(".tint"))) {
        args.insert("mode", arg == QLatin1String("clear") ? QStringLiteral("clear") : QStringLiteral("set"));
        if (arg != QLatin1String("clear"))
            args.insert("tint", arg);
    }
    if (cmd.endsWith(QLatin1String(".new")) && opt.contains(QStringLiteral("tint")))
        args.insert("tint", opt.value(QStringLiteral("tint")));
    if (cmd.startsWith(QLatin1String("session.overlay.")) || cmd.startsWith(QLatin1String("session.hud."))) {
        copy("background-color", "color");
        copy("text-color", "textColor");
        copy("detail", "detail");
        copy("position", "position");
        copy("spinner-style", "spinner");
        copy("html", "html");
        copy("url", "url");
        flag("wait", "wait");
        flag("follow", "follow");
        flag("full", "full");
        flag("markdown", "markdown");
        flag("sticky", "sticky");
        if (opt.contains(QStringLiteral("spinner")) && !args.contains("spinner"))
            args.insert("spinner", true);
        if (opt.contains(QStringLiteral("no-frame")))
            args.insert("frame", false);
        for (const auto &[from, to] : {std::pair{"size-percent", "sizePercent"}})
            if (opt.contains(QLatin1String(from)))
                args.insert(QLatin1String(to), opt.value(QLatin1String(from)).toInt());
        for (const auto &[from, to] : {std::pair{"width", "width"}, {"height", "height"}, {"hide-after", "hideAfter"}, {"font-size", "fontSize"}})
            if (opt.contains(QLatin1String(from)))
                args.insert(QLatin1String(to), opt.value(QLatin1String(from)).toDouble());
        if (cmd == QLatin1String("session.overlay.open")) {
            copy("image", "image");
            copy("text", "textFile");
            if (opt.contains(QStringLiteral("markdown"))) // a flag for the HUD; with overlay open the file is the positional
                args.insert("markdownFile", arg);
            else if (!arg.isEmpty())
                args.insert("command", arg);
        }
        if (cmd == QLatin1String("session.hud.open") || cmd == QLatin1String("session.hud.update")) {
            if (opt.contains(QStringLiteral("file"))) {
                QFile f(opt.value(QStringLiteral("file")));
                if (!f.open(QIODevice::ReadOnly))
                    return die(QStringLiteral("cannot read %1").arg(f.fileName()));
                args.insert("message", QString::fromUtf8(f.readAll()).trimmed());
            } else {
                args.insert("message", arg);
            }
        }
        if (opt.contains(QStringLiteral("block")) && opt.contains(QStringLiteral("wait")))
            return die(QStringLiteral("--block is mutually exclusive with --wait"));
    }
    copy("window", "window");
    QString windowTarget;
    if (cmd.startsWith(QLatin1String("window."))) {
        static const QStringList modes{"on", "off", "toggle"};
        if (cmd == QLatin1String("window.new")) {
            if (!arg.isEmpty())
                args.insert("name", arg);
            flag("minimized", "minimized");
        } else if (cmd == QLatin1String("window.minimize")) {
            const bool idFirst = !pos.isEmpty() && !modes.contains(pos[0]);
            windowTarget = idFirst ? pos[0] : QString();
            if (const QString m = pos.value(idFirst ? 1 : 0); !m.isEmpty())
                args.insert("mode", m);
        } else {
            windowTarget = arg;
            if (cmd == QLatin1String("window.rename"))
                args.insert("name", pos.value(1));
        }
        args.remove("window");
        for (const char *k : {"width", "height", "x", "y", "display"})
            if (opt.contains(QLatin1String(k)))
                args.insert(QLatin1String(k), opt.value(QLatin1String(k)).toInt());
    }
    if (cmd == QLatin1String("dashboard")) {
        args.insert("targets", QJsonArray::fromStringList(pos));
        flag("mru", "mru");
        flag("auto-size", "autoSize");
        flag("close", "close");
        if (opt.contains(QStringLiteral("font-size")))
            args.insert("fontSize", opt.value(QStringLiteral("font-size")).toDouble());
    }
    if (cmd == QLatin1String("restore.mode") && !arg.isEmpty())
        args.insert("mode", arg);
    if (cmd == QLatin1String("session.restore")) {
        args.insert("mode", opt.contains(QStringLiteral("none")) ? QStringLiteral("none") : opt.contains(QStringLiteral("clear")) ? QStringLiteral("clear") : QStringLiteral("set"));
        if (!arg.isEmpty())
            args.insert("command", arg);
    }
    if (cmd == QLatin1String("msg.send") && opt.contains(QStringLiteral("stdin"))) {
        QFile f;
        if (!f.open(stdin, QIODevice::ReadOnly))
            return die(QStringLiteral("cannot read stdin"));
        args.insert("body", QString::fromUtf8(f.readAll()));
    }
    if (cmd == QLatin1String("session.type")) {
        if (opt.contains(QStringLiteral("stdin"))) {
            QFile f;
            if (!f.open(stdin, QIODevice::ReadOnly))
                return die(QStringLiteral("cannot read stdin"));
            args.insert("text", QString::fromUtf8(f.readAll()));
        } else {
            args.insert("text", arg);
        }
    }


    // commands added for master's catalog
    QString idTarget; // pick/ask/recent ids travel as the target
    if (cmd == QLatin1String("events.read")) {
        if (opt.contains(QStringLiteral("run")) != opt.contains(QStringLiteral("after")))
            return die(QStringLiteral("events.read requires --run and --after together"));
        copy("run", "run");
        copy("after", "after");
        if (multi.contains(QStringLiteral("kind")))
            args.insert("kinds", QJsonArray::fromStringList(multi.value(QStringLiteral("kind"))));
        if (opt.contains(QStringLiteral("limit")))
            args.insert("limit", opt.value(QStringLiteral("limit")).toInt());
        return followEvents(opt.value(QStringLiteral("socket"), socketPath()), args, opt.contains(QStringLiteral("json")));
    }
    if (cmd == QLatin1String("workspace.flag") || cmd == QLatin1String("sidebar.mode") || cmd == QLatin1String("sidebar.flagged-layout")
        || cmd == QLatin1String("sidebar.density") || cmd == QLatin1String("sidebar") || cmd == QLatin1String("surface.zoom")
        || cmd == QLatin1String("settings.keep-awake"))
        args.insert("mode", arg.isEmpty() ? QStringLiteral("toggle") : arg);
    if (cmd == QLatin1String("sidebar.width")) {
        bool number = false;
        const double w = arg.toDouble(&number);
        if (!number)
            return die(QStringLiteral("points must be a number"));
        args.insert("sidebarWidth", w);
    }
    if (cmd == QLatin1String("session.context")) {
        if (arg.isEmpty() == !opt.contains(QStringLiteral("clear")))
            return die(QStringLiteral("provide exactly one of a TEXT or --clear"));
        args.insert("mode", arg.isEmpty() ? QStringLiteral("clear") : QStringLiteral("set"));
        if (!arg.isEmpty())
            args.insert("text", arg);
    }
    if (cmd == QLatin1String("session.focus"))
        args.insert("pane", arg.isEmpty() ? QStringLiteral("other") : arg);
    if (cmd == QLatin1String("session.resize")) {
        static const QList<std::pair<const char *, double>> grow{{"grow-primary", 1}, {"grow-left", 1}, {"grow-top", 1}, {"grow-split", -1}, {"grow-right", -1}, {"grow-bottom", -1}};
        int given = opt.contains(QStringLiteral("split-ratio")) ? 1 : 0;
        for (const auto &[name, sign] : grow)
            if (opt.contains(QLatin1String(name)))
                ++given, args.insert("ratioDelta", sign * opt.value(QLatin1String(name)).toDouble());
        if (given != 1)
            return die(QStringLiteral("provide exactly one split ratio or grow option"));
        if (opt.contains(QStringLiteral("split-ratio")))
            args.insert("ratio", opt.value(QStringLiteral("split-ratio")).toDouble());
    }
    if (cmd == QLatin1String("session.text"))
        flag("all", "all");
    if (cmd == QLatin1String("session.transcript")) {
        if (opt.contains(QStringLiteral("after")) && opt.contains(QStringLiteral("before")))
            return die(QStringLiteral("use either --after or --before, not both"));
        for (const char *k : {"after", "before"}) // sent as text, as the Mac's ControlArgs
            if (opt.contains(QLatin1String(k))) {
                bool number = false;
                const qint64 at = opt.value(QLatin1String(k)).toLongLong(&number);
                if (!number || at < 0)
                    return die(QStringLiteral("--after and --before must be 0 or greater"));
                args.insert(QLatin1String(k), QString::number(at));
            }
        if (opt.contains(QStringLiteral("max-bytes"))) {
            const int max = opt.value(QStringLiteral("max-bytes")).toInt();
            if (max <= 0)
                return die(QStringLiteral("--max-bytes must be greater than 0"));
            args.insert("maxBytes", max);
        }
        copy("transcript", "transcript");
        copy("pane-id", "paneID");
    }
    if (cmd == QLatin1String("session.search")) {
        if (int(opt.contains(QStringLiteral("next"))) + opt.contains(QStringLiteral("prev")) + opt.contains(QStringLiteral("close")) > 1)
            return die(QStringLiteral("--next, --prev, and --close are mutually exclusive"));
        if (opt.contains(QStringLiteral("close")) && !arg.isEmpty())
            return die(QStringLiteral("--close cannot be combined with a needle"));
        if (!arg.isEmpty())
            args.insert("text", arg);
        for (const char *to : {"next", "prev", "close"})
            if (opt.contains(QLatin1String(to)))
                args.insert("to", QLatin1String(to));
    }
    if (cmd == QLatin1String("workspace.go"))
        copy("to", "to");
    if (cmd == QLatin1String("notify") && !arg.isEmpty())
        args.insert("body", arg);
    if (cmd == QLatin1String("recent.open") || cmd == QLatin1String("pick.result") || cmd == QLatin1String("pick.cancel") || cmd == QLatin1String("ask.result")
        || cmd == QLatin1String("ask.cancel"))
        idTarget = arg;
    if (cmd == QLatin1String("pick.open")) {
        QFile f;
        if (!f.open(stdin, QIODevice::ReadOnly))
            return die(QStringLiteral("cannot read stdin"));
        const QByteArray raw = f.readAll();
        const QString text = QString::fromUtf8(raw);
        if (text.toUtf8() != raw)
            return die(QStringLiteral("stdin must be UTF-8 text or a JSON item array"));
        QJsonArray items;
        if (text.trimmed().startsWith(QLatin1Char('['))) {
            items = QJsonDocument::fromJson(raw).array();
        } else {
            for (const QString &l : text.split(QLatin1Char('\n')))
                if (!l.trimmed().isEmpty())
                    items << QJsonObject{{"id", l}, {"label", l}};
        }
        args.insert("items", items);
        copy("prompt", "prompt");
        copy("query", "query");
        copy("select", "selection");
        flag("allow-custom", "allowCustom");
        flag("follow", "follow");
    }
    if (cmd == QLatin1String("ask.open")) {
        args.insert("title", arg);
        copy("message", "message");
        copy("style", "style");
        copy("align", "align");
        copy("input", "input");
        copy("value", "value");
        copy("placeholder", "placeholder");
        copy("other", "other");
        copy("default", "defaultButton");
        copy("destructive", "destructiveButton");
        copy("cancel", "cancelButton");
        flag("multiple", "multiple");
        flag("follow", "follow");
        if (opt.contains(QStringLiteral("width")))
            args.insert("width", opt.value(QStringLiteral("width")).toInt());
        if (!multi.contains(QStringLiteral("button")) && !opt.contains(QStringLiteral("input")) && !multi.contains(QStringLiteral("choice")))
            return die(QStringLiteral("ask requires at least one --button"));
        QJsonArray buttons, choices;
        QStringList ids;
        for (const QString &b : multi.value(QStringLiteral("button"))) {
            const auto [id, label] = pairOf(b);
            buttons << QJsonObject{{"id", id}, {"label", label}};
            ids << id;
        }
        if (multi.contains(QStringLiteral("hotkey")) && buttons.isEmpty())
            return die(QStringLiteral("--hotkey requires --button"));
        for (const QString &h : multi.value(QStringLiteral("hotkey"))) {
            if (!h.contains(QLatin1Char('=')))
                return die(QStringLiteral("--hotkey requires ID=LETTER"));
            const auto [id, key] = pairOf(h);
            if (!ids.contains(id))
                return die(QStringLiteral("unknown hotkey button: %1").arg(id));
            QJsonObject b = buttons[ids.indexOf(id)].toObject();
            if (b.contains("hotkey"))
                return die(QStringLiteral("hotkey already assigned to button: %1").arg(id));
            b.insert("hotkey", key);
            buttons[ids.indexOf(id)] = b;
        }
        if (!buttons.isEmpty())
            args.insert("buttons", buttons);
        QStringList choiceIds;
        for (const QString &c : multi.value(QStringLiteral("choice"))) {
            const auto [id, label] = pairOf(c);
            choices << QJsonObject{{"id", id}, {"label", label}};
            choiceIds << id;
        }
        if ((multi.contains(QStringLiteral("choice-subtitle")) || opt.contains(QStringLiteral("other"))) && choices.isEmpty())
            return die(multi.contains(QStringLiteral("choice-subtitle")) ? QStringLiteral("--choice-subtitle requires --choice") : QStringLiteral("--other requires --choice"));
        for (const QString &c : multi.value(QStringLiteral("choice-subtitle"))) {
            if (!c.contains(QLatin1Char('=')))
                return die(QStringLiteral("--choice-subtitle requires ID=TEXT"));
            const auto [id, text] = pairOf(c);
            if (!choiceIds.contains(id))
                return die(QStringLiteral("unknown subtitle choice: %1").arg(id));
            QJsonObject o = choices[choiceIds.indexOf(id)].toObject();
            if (o.contains("subtitle"))
                return die(QStringLiteral("subtitle already set for choice: %1").arg(id));
            o.insert("subtitle", text);
            choices[choiceIds.indexOf(id)] = o;
        }
        if (!choices.isEmpty())
            args.insert("choices", choices);
        if (multi.contains(QStringLiteral("checked")))
            args.insert("checked", QJsonArray::fromStringList(multi.value(QStringLiteral("checked"))));
    }
    if (cmd.startsWith(QLatin1String("msg."))) {
        QString identity = opt.value(QStringLiteral("as"));
        const QString sid = qEnvironmentVariable("ELIS_SESSION_ID"), pid = qEnvironmentVariable("ELIS_PANE_ID");
        if (identity.isEmpty() && sid.isEmpty() != pid.isEmpty())
            return die(QStringLiteral("incomplete pane identity: ELIS_SESSION_ID and ELIS_PANE_ID must both be set; pass --as SESSION:PANE-ID"));
        if (identity.isEmpty() && !sid.isEmpty())
            identity = sid + QLatin1Char(':') + pid;
        if (!identity.isEmpty())
            args.insert("identity", identity);
        if (cmd == QLatin1String("msg.send")) {
            if (arg.isEmpty() == !opt.contains(QStringLiteral("stdin")))
                return die(QStringLiteral("provide the body as TEXT or --stdin, exactly one"));
            if (!arg.isEmpty())
                args.insert("body", arg);
            if (multi.contains(QStringLiteral("to")))
                args.insert("recipients", QJsonArray::fromStringList(multi.value(QStringLiteral("to"))));
            flag("all", "all");
        }
        if (cmd == QLatin1String("msg.ack"))
            args.insert("ids", QJsonArray::fromStringList(pos));
        flag("ack", "ack");
        if (opt.contains(QStringLiteral("timeout")) && !opt.contains(QStringLiteral("wait")))
            return die(QStringLiteral("--timeout needs --wait"));
        if (opt.contains(QStringLiteral("timeout")) && !(opt.value(QStringLiteral("timeout")).toDouble() > 0))
            return die(QStringLiteral("--timeout must be a positive number of seconds"));
    }
    if ((cmd == QLatin1String("session.close") || cmd == QLatin1String("session.move")) && multi.value(QStringLiteral("target")).size() > 1)
        args.insert("targets", QJsonArray::fromStringList(multi.value(QStringLiteral("target"))));

    QJsonObject request{{"cmd", cmd}, {"args", args}};
    QString target = idTarget.isEmpty() ? opt.value(QStringLiteral("target")) : idTarget;
    if (cmd == QLatin1String("session.companion.new"))
        target = opt.value(QStringLiteral("parent"));
    if (target.isEmpty() && (cmd.startsWith(QLatin1String("session.")) || cmd.startsWith(QLatin1String("font.")) || cmd == QLatin1String("notify") || cmd == QLatin1String("keymap.run"))
        && cmd != QLatin1String("session.new") && cmd != QLatin1String("session.go") && cmd != QLatin1String("session.companion.new"))
        target = qEnvironmentVariable("ELIS_SESSION_ID"); // a pane addresses itself by default
    if (cmd.startsWith(QLatin1String("window.")))
        target = windowTarget.isEmpty() ? opt.value(QStringLiteral("target")) : windowTarget;
    if (!target.isEmpty())
        request.insert("target", target);

    const QString path = opt.value(QStringLiteral("socket"), socketPath());
    QString error;
    if (cmd == QLatin1String("msg.read") && opt.contains(QStringLiteral("wait"))) { // poll while the mailbox is empty
        const qint64 deadline = opt.contains(QStringLiteral("timeout")) ? QDateTime::currentMSecsSinceEpoch() + qint64(opt.value(QStringLiteral("timeout")).toDouble() * 1000) : 0;
        for (;;) {
            const QJsonObject r = exchange(path, {{"cmd", "msg.read"}, {"args", QJsonObject{{"identity", args.value("identity")}}}}, &error);
            if (!r.value("ok").toBool() || !r["result"]["messages"].toArray().isEmpty())
                break;
            if (deadline && QDateTime::currentMSecsSinceEpoch() > deadline)
                return fputs("timed out\n", stderr), 124;
            QThread::msleep(250);
        }
    }
    const QByteArray line = roundTrip(path, request, &error);
    if (line.isEmpty())
        return die(error);
    if ((cmd == QLatin1String("pick.result") || cmd == QLatin1String("ask.result")) && !opt.contains(QStringLiteral("json"))) {
        const QJsonObject r = QJsonDocument::fromJson(line).object();
        if (!r.value("ok").toBool())
            return die(r.value("error").toString());
        const QJsonObject outcome = r["result"][cmd.left(cmd.indexOf(QLatin1Char('.')))].toObject();
        printf("%s\n", QJsonDocument(outcome).toJson(QJsonDocument::Compact).constData());
        static const QHash<QString, int> codes{{"picked", 0}, {"custom", 0}, {"answered", 0}, {"pending", 1}, {"cancelled", 2}, {"escaped", 3}};
        return codes.value(outcome.value("result").toString(), 1);
    }

    if (opt.contains(QStringLiteral("json")))
        return fputs(line.constData(), stdout), 0;
    const QJsonObject response = QJsonDocument::fromJson(line).object();
    if (!response.value("ok").toBool())
        return die(response.value("error").toString());
    const QJsonObject result = response.value("result").toObject();
    if (cmd == QLatin1String("session.transcript")) { // the Mac's formatTranscript
        const QJsonObject meta = result["meta"].toObject();
        for (const char *k : {"title", "model", "permissionMode"})
            if (meta.contains(QLatin1String(k)))
                printf("%s: %s\n", k, qPrintable(meta[QLatin1String(k)].toString()));
        for (const auto &v : meta["agents"].toArray()) {
            const QJsonObject a = v.toObject();
            QStringList words{a["state"].toString(), a["name"].toString(a["agentType"].toString()), a["description"].toString()};
            words.removeAll(QString());
            printf("agent: %s\n", qPrintable(words.join(QLatin1Char(' '))));
        }
        for (const auto &v : result["items"].toArray()) {
            const QJsonObject item = v.toObject();
            QString detail = item["text"].toString();
            if (item["kind"].toString() == QLatin1String("tool")) {
                QStringList words{item["name"].toString(), item["arg"].toString(), item["mark"].toString()};
                words.removeAll(QString());
                detail = words.join(QLatin1Char(' '));
            }
            printf("%s\n", qPrintable(detail.isEmpty() ? item["kind"].toString() : item["kind"].toString() + QStringLiteral("  ") + detail));
        }
        return printf("next %lld\n", result["next"].toInteger()), 0;
    }
    if (cmd == QLatin1String("pick.open") || cmd == QLatin1String("ask.open")) {
        if (opt.contains(QStringLiteral("no-block")))
            return printf("%s\n", QJsonDocument(QJsonObject{{"id", result["id"]}}).toJson(QJsonDocument::Compact).constData()), 0;
        return awaitOutcome(path, cmd.left(cmd.indexOf(QLatin1Char('.'))), result["id"].toString());
    }
    if (cmd == QLatin1String("msg.send")) {
        for (const auto &v : result["rejected"].toArray())
            fprintf(stderr, "rejected %s: %s\n", qPrintable(v.toObject()["address"].toString()), qPrintable(v.toObject()["reason"].toString()));
        printf("%s\n", qPrintable(result["messageID"].toString()));
        return result["rejected"].toArray().isEmpty() ? 0 : 1;
    }
    if (cmd == QLatin1String("msg.read")) {
        QStringList ids;
        for (const auto &v : result["messages"].toArray()) {
            const QJsonObject m = v.toObject();
            ids << m["id"].toString();
            printf("%s from %s\n%s\n", qPrintable(m["id"].toString()), qPrintable(m["from"].toString(QStringLiteral("outside Elis"))), qPrintable(m["body"].toString()));
        }
        if (result["remaining"].toInt() > 0)
            fprintf(stderr, "%d more pending\n", result["remaining"].toInt());
        return 0;
    }
    if (cmd == QLatin1String("msg.ack"))
        return printf("acked %lld\n", result["acked"].toArray().size()), 0;
    if (result.contains("recent")) {
        if (result["recent"].toArray().isEmpty())
            return puts("no recently closed items"), 0;
        for (const auto &v : result["recent"].toArray()) {
            const QJsonObject r = v.toObject();
            printf("%s  %s  %s%s\n", qPrintable(r["id"].toString()), qPrintable(r["kind"].toString()), qPrintable(r["title"].toString()),
                   r["subtitle"].toString().isEmpty() ? "" : qPrintable(QStringLiteral(" (%1)").arg(r["subtitle"].toString())));
        }
        return 0;
    }
    if (result.contains("affected"))
        return printf("%d session(s)\n", result["affected"].toInt()), 0;
    if (result.contains("ratio"))
        return printf("%s\n", qPrintable(QString::number(result["ratio"].toDouble(), 'f', 3))), 0; // C-locale digits, as master
    if (result.contains("sidebarWidth") && cmd == QLatin1String("sidebar.width"))
        return printf("%s\n", qPrintable(QString::number(result["sidebarWidth"].toDouble(), 'f', 1))), 0;
    if (result.contains("filePanelWidth") && cmd == QLatin1String("filepanel.width"))
        return printf("%s\n", qPrintable(QString::number(result["filePanelWidth"].toDouble(), 'f', 1))), 0;
    if (cmd == QLatin1String("session.overlay.open") && opt.contains(QStringLiteral("block"))) {
        // exits with the program's status, printing none of its output
        QJsonObject pollArgs;
        if (args.contains("pane"))
            pollArgs.insert("pane", args.value("pane"));
        const QJsonObject poll{{"cmd", "session.overlay.result"}, {"target", result["id"].toString()}, {"args", pollArgs}};
        for (;;) {
            const QJsonObject r = QJsonDocument::fromJson(roundTrip(path, poll, &error)).object();
            if (r.value("ok").toBool())
                return r["result"]["exitCode"].toInt();
            if (r.value("error").toString() != QLatin1String("overlay still running"))
                return die(r.value("error").toString(error));
            QThread::msleep(200);
        }
    }
    if (result.contains("windows")) {
        for (const auto &v : result["windows"].toArray()) {
            const QJsonObject w = v.toObject();
            printf("%s %s  %-20s %s\n", w["active"].toBool() ? "*" : " ", qPrintable(w["id"].toString()), qPrintable(w["name"].toString()),
                   w["open"].toBool() ? "open" : "closed");
        }
        return 0;
    }
    if (cmd == QLatin1String("window.new"))
        return printf("%s\n", qPrintable(result["id"].toString())), 0;
    if (cmd == QLatin1String("window.resize"))
        return printf("%dx%d\n", result["width"].toInt(), result["height"].toInt()), 0;
    if (result.contains("restore")) {
        const QJsonObject r = result["restore"].toObject();
        printf("configured %s\nat launch  %s\nactive     %s%s\n", qPrintable(r["configured"].toString()), qPrintable(r["requestedAtLaunch"].toString()),
               qPrintable(r["active"].toString()), r["restartRequired"].toBool() ? "\n(restart required)" : "");
        return 0;
    }
    if (result.contains("exitCode"))
        return printf("%d\n", result["exitCode"].toInt()), 0;

    if (result.contains("tree")) {
        for (const auto &wv : result["tree"]["workspaces"].toArray()) {
            const auto w = wv.toObject();
            printf("%s  %s\n", qPrintable(w["id"].toString()), qPrintable(w["name"].toString()));
            for (const auto &sv : w["sessions"].toArray()) {
                const auto s = sv.toObject();
                printf("  %s %s %-24s %-9s %s\n", s["active"].toBool() ? "*" : " ", qPrintable(s["id"].toString()),
                       qPrintable(s["name"].toString()), qPrintable(s["status"].toString()), qPrintable(s["cwd"].toString()));
            }
        }
    } else if (result.contains("keymap")) {
        const QJsonObject k = result["keymap"].toObject();
        printf("%s\n", qPrintable(k["path"].toString()));
        for (const auto &v : k["actions"].toArray()) {
            QStringList keys{v.toObject()["chord"].toString()};
            for (const auto &a : v.toObject()["alternates"].toArray())
                keys << a.toString();
            printf("  %-28s %s%s\n", qPrintable(v.toObject()["name"].toString()), qPrintable(keys.join(QLatin1Char('|'))), v.toObject()["marked"].toBool() ? "  (mapped)" : "");
        }
        for (const auto &v : k["commands"].toArray())
            printf("  command \"%s\" %s%s  %s\n", qPrintable(v.toObject()["name"].toString()), qPrintable(v.toObject()["shortcut"].toString()),
                   v.toObject()["errorHud"].toBool() ? " --error-hud" : "", qPrintable(v.toObject()["command"].toString()));
        for (const auto &v : k["diagnostics"].toArray())
            printf("  line %d: %s\n", v.toObject()["line"].toInt(), qPrintable(v.toObject()["message"].toString()));
        printf("menu:\n");
        for (const auto &v : k["menu"].toArray())
            printf("  %-32s %s%s\n", qPrintable(v.toObject()["title"].toString()), qPrintable(v.toObject()["chord"].toString()), v.toObject()["enabled"].toBool() ? "" : "  (disabled)");
    } else if (result.contains("hooks")) {
        const QJsonObject h = result["hooks"].toObject();
        printf("%s\n", qPrintable(h["path"].toString()));
        for (const auto &v : h["hooks"].toArray()) {
            printf("  line %d  on %s %s", v.toObject()["line"].toInt(), qPrintable(v.toObject()["kind"].toString()), qPrintable(v.toObject()["command"].toString()));
            if (v.toObject().contains("runningPid"))
                printf("  [running pid %lld]", qint64(v.toObject()["runningPid"].toDouble()));
            if (v.toObject()["pending"].toInt() || v.toObject()["dropped"].toInt())
                printf("  [pending %d, dropped %d]", v.toObject()["pending"].toInt(), v.toObject()["dropped"].toInt());
            if (v.toObject().contains("lastFailure"))
                printf("  [last failure: %s]", qPrintable(v.toObject()["lastFailure"].toString()));
            printf("%s\n", v.toObject()["retired"].toBool() ? "  (retired)" : "");
        }
        for (const auto &v : h["diagnostics"].toArray())
            printf("  line %d: %s\n", v.toObject()["line"].toInt(), qPrintable(v.toObject()["message"].toString()));
    } else if (result.contains("themes")) {
        for (const auto &v : result["themes"].toArray())
            printf("%s %s\n", v.toString() == result["theme"].toString() ? "*" : " ", qPrintable(v.toString()));
    } else if (result.contains("count") && !result.contains("text")) {
        printf("%d diagnostic(s)\n", result["count"].toInt());
    } else if (result.contains("session")) {
        const auto s = result["session"].toObject();
        for (auto it = s.begin(); it != s.end(); ++it)
            printf("%-14s %s\n", qPrintable(it.key()), qPrintable(it.value().toVariant().toString()));
    } else if (result.contains("text")) {
        fputs(result["text"].toString().toUtf8().constData(), stdout);
        if (!result["text"].toString().endsWith(QLatin1Char('\n')))
            putchar('\n');
    } else if (result.contains("undoable")) {
        printf("ok %s\n", result["undoable"].toBool() ? "(undoable)" : "(not undoable)");
    } else if (result.contains("count") && cmd == QLatin1String("session.search")) {
        puts("ok");
    } else if (cmd.endsWith(QLatin1String(".new")) || cmd == QLatin1String("session.duplicate") || cmd == QLatin1String("session.companion.duplicate")
               || cmd == QLatin1String("recent.open")) {
        printf("%s\n", qPrintable(result["id"].toString()));
    }
    return 0;
}
