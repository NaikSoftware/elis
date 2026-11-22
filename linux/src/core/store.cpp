#include "store.h"

#include <QDateTime>
#include "restore.h"

#include "elis_bridge.h"

#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSet>
#include <QTimer>
#include <QUuid>

const QStringList Store::statuses = {QStringLiteral("idle"), QStringLiteral("active"), QStringLiteral("completed"),
                                     QStringLiteral("blocked")};
static QJsonObject tintPaletteJson()
{
    char *raw = elis_tint_palette();
    const QJsonObject reply = QJsonDocument::fromJson(raw ? QByteArray(raw) : QByteArray()).object();
    elis_free(raw);
    return reply;
}

const QList<TintSwatch> &Store::tintPalette()
{
    static const QList<TintSwatch> palette = [] {
        QList<TintSwatch> list;
        for (const QJsonValue &c : tintPaletteJson().value("colors").toArray())
            list.append({c["name"].toString(), c["light"].toString(), c["dark"].toString()});
        return list;
    }();
    return palette;
}

const QJsonArray &Store::tintShownParts()
{
    static const QJsonArray parts = tintPaletteJson().value("shownParts").toArray();
    return parts;
}

QString Store::parseTint(const QString &cmd, const QJsonObject &args, QString *tint)
{
    // only the tint keys: the rest of a new's arguments are not ElisCore's to decode
    QJsonObject request;
    for (const char *key : {"mode", "tint", "tintOn"})
        if (args.contains(QLatin1String(key)))
            request.insert(QLatin1String(key), args.value(QLatin1String(key)));
    char *raw = elis_tint_parse(cmd.toUtf8().constData(), QJsonDocument(request).toJson(QJsonDocument::Compact).constData());
    const QJsonObject reply = QJsonDocument::fromJson(raw ? QByteArray(raw) : QByteArray()).object();
    elis_free(raw);
    if (!reply.value("ok").toBool())
        return reply.value("error").toString(QStringLiteral("the tint check gave no answer"));
    *tint = reply.value("tint").toString();
    return {};
}

// a stored colour as ElisCore reads it; "" when unknown
static QString tintValue(const QString &raw)
{
    QString tint;
    return Store::parseTint({}, {{"tint", raw}}, &tint).isEmpty() ? tint : QString();
}

static QJsonValue tintJson(const Tint &t)
{
    return t.color.isEmpty() ? QJsonValue() : QJsonObject{{"color", t.color}};
}

static Tint tintFromJson(const QJsonValue &v)
{
    // an unknown colour drops the tint
    const QString color = v.toObject().value("color").toString();
    return color.isEmpty() ? Tint{} : Tint{tintValue(color)};
}

QString Session::displayName() const
{
    // a pinned name, else the title its program set (or the command it runs), else the folder it is in
    if (!name.isEmpty())
        return name;
    if (!title.trimmed().isEmpty())
        return title.trimmed();
    if (QDir::cleanPath(cwd) == QDir::homePath())
        return QStringLiteral("~");
    const QString folder = QFileInfo(cwd).fileName();
    return folder.isEmpty() ? QStringLiteral("New session") : folder;
}

QString Store::newId()
{
    return QUuid::createUuid().toString(QUuid::Id128).left(12);
}

QString Store::stripTitleSpinner(const QString &title)
{
    // agents animate a status glyph (✳, ◑, braille frames) at the start of the title
    int i = 0;
    for (; i < title.size(); ++i) {
        const char16_t c = title[i].unicode();
        const bool spinner = (c >= 0x2800 && c <= 0x28FF) || (c >= 0x25CB && c <= 0x25D3) || (c >= 0x2722 && c <= 0x2725)
                             || (c >= 0x2731 && c <= 0x273F) || c == 0x00B7;
        if (!spinner && !title[i].isSpace())
            break;
    }
    return i == title.size() ? title : title.mid(i);
}

Session *Store::session(const QString &id)
{
    for (auto &w : workspaces)
        for (auto &s : w.sessions)
            if (s.id == id)
                return &s;
    return nullptr;
}

Workspace *Store::workspace(const QString &id)
{
    for (auto &w : workspaces)
        if (w.id == id)
            return &w;
    return nullptr;
}

Workspace *Store::workspaceOf(const QString &sessionId)
{
    for (auto &w : workspaces)
        for (auto &s : w.sessions)
            if (s.id == sessionId)
                return &w;
    return nullptr;
}

int Store::indexIn(const Workspace &w, const QString &sessionId) const
{
    for (int i = 0; i < w.sessions.size(); ++i)
        if (w.sessions[i].id == sessionId)
            return i;
    return -1;
}

QList<Session *> Store::allSessions()
{
    QList<Session *> out;
    for (auto &w : workspaces)
        for (auto &s : w.sessions)
            out << &s;
    return out;
}

QList<Workspace *> Store::visibleWorkspaces()
{
    QList<Workspace *> out;
    for (auto &w : workspaces)
        if (!focusEnabled || focused.contains(w.id))
            out << &w;
    return out;
}

QList<Session *> Store::navigableSessions()
{
    QList<Session *> out;
    if (flaggedView) { // the flagged view is cross-workspace and ignores the filter
        for (auto *s : allSessions())
            if (s->flagged)
                out << s;
        return out;
    }
    for (auto *w : visibleWorkspaces())
        for (auto &s : w->sessions)
            out << &s;
    return out;
}

QStringList Store::recentOthers(int limit)
{
    QSet<QString> shown;
    for (auto *s : navigableSessions())
        shown << s->id;
    QStringList out;
    for (const QString &id : std::as_const(recent))
        if (id != selected && shown.contains(id) && out.size() < limit)
            out << id;
    return out;
}

template<typename T, typename Name>
static QString resolve(const QList<T *> &items, const QString &target, const char *kind, Name name, QString *error)
{
    QList<T *> prefix, named;
    for (T *i : items) {
        if (i->id == target)
            return i->id;
        if (target.size() >= 3 && i->id.startsWith(target))
            prefix << i;
        if (name(i) == target)
            named << i;
    }
    const auto &hits = prefix.isEmpty() ? named : prefix;
    if (hits.size() == 1)
        return hits.first()->id;
    *error = hits.isEmpty() ? QStringLiteral("no %1 matches '%2'").arg(QLatin1String(kind), target)
                            : QStringLiteral("'%1' matches %2 %3s").arg(target).arg(hits.size()).arg(QLatin1String(kind));
    return {};
}

QString Store::resolveSession(const QString &target, QString *error)
{
    if (target.isEmpty() || target == QLatin1String("active")) {
        if (selected.isEmpty())
            *error = QStringLiteral("no active session");
        return selected;
    }
    return resolve(allSessions(), target, "session", [](Session *s) { return s->displayName(); }, error);
}

QString Store::resolveWorkspace(const QString &target, QString *error)
{
    if (target.isEmpty() || target == QLatin1String("active")) {
        if (!freshWorkspace.isEmpty() && workspace(freshWorkspace))
            return freshWorkspace;
        if (auto *w = workspaceOf(selected))
            return w->id;
        if (!workspaces.isEmpty())
            return workspaces.last().id; // AppStore.currentWorkspaceID
        *error = QStringLiteral("no workspaces");
        return {};
    }
    QList<Workspace *> ws;
    for (auto &w : workspaces)
        ws << &w;
    return resolve(ws, target, "workspace", [](Workspace *w) { return w->name; }, error);
}

QString Store::workspaceOwning(const QString &folder) const
{
    const QString f = QDir::cleanPath(folder);
    QString bestId;
    qsizetype bestLen = -1;
    for (const auto &w : workspaces) {
        if (w.projectFolder.isEmpty())
            continue;
        const QString pin = QDir::cleanPath(w.projectFolder);
        if ((f == pin || f.startsWith(pin + QLatin1Char('/'))) && pin.size() > bestLen) {
            bestLen = pin.size();
            bestId = w.id;
        }
    }
    return bestId;
}

QString Store::workspaceRemembering(const QString &folder) const
{
    const QString f = QDir::cleanPath(folder);
    for (const auto &w : workspaces)
        if (!w.folder.isEmpty() && w.folder == f)
            return w.id;
    return {};
}

QString Store::newSessionCwd(const QString &workspaceId, const QString &currentCwd) const
{
    const QString home = QDir::homePath();
    if (settings.newSessionDirectory == QLatin1String("custom"))
        return QFileInfo(settings.newSessionCustomDirectory).isDir() ? settings.newSessionCustomDirectory : home;
    if (settings.newSessionDirectory == QLatin1String("workspace")) {
        for (const auto &w : workspaces)
            if (w.id == workspaceId) {
                if (!w.projectFolder.isEmpty() && QFileInfo(w.projectFolder).isDir())
                    return w.projectFolder;
                if (QFileInfo(w.folder).isDir())
                    return w.folder; // a vanished folder is skipped, not cleared
            }
        return currentCwd.isEmpty() ? home : currentCwd;
    }
    return home;
}

QString Store::addWorkspace(const QString &name, bool isCollapsed, const QString &projectFolder, bool reveal)
{
    Workspace w{newId(), name.isEmpty() ? QStringLiteral("workspace %1").arg(workspaces.size() + 1) : name, {}, {}, {}, projectFolder};
    workspaces << w;
    if (isCollapsed)
        collapsed.insert(w.id);
    if (focusEnabled && !isCollapsed)
        focused << w.id; // a workspace created under the filter joins it rather than vanishing
    if (reveal && !isCollapsed)
        freshWorkspace = w.id;
    Q_EMIT changed();
    return w.id;
}

QString Store::addSession(const QString &workspaceId, const QString &name, const QString &cwd, const QString &command, int index,
                          const QString &resume)
{
    auto *w = workspace(workspaceId);
    if (!w)
        return {};
    Session s;
    s.id = newId();
    s.cwd = cwd.isEmpty() ? QDir::homePath() : cwd;
    s.name = name;
    s.command = command;
    s.resume = resume;
    if (index < 0 && settings.newSessionPlacement == QLatin1String("afterCurrent"))
        if (const int at = indexIn(*w, selected); at >= 0)
            index = at + 1;
    w->sessions.insert(index < 0 || index > w->sessions.size() ? w->sessions.size() : index, s);
    Q_EMIT sessionAdded(s.id);
    Q_EMIT changed();
    return s.id;
}

QString Store::duplicateSession(const QString &id, const QString &cwd)
{
    auto *w = workspaceOf(id);
    if (!w)
        return {};
    const Session *s = session(id);
    return addSession(w->id, {}, cwd.isEmpty() ? s->cwd : cwd, {}, indexIn(*w, id) + 1);
}

QStringList Store::companionsOf(const QString &parentId) const
{
    QStringList ids;
    for (const auto &w : workspaces)
        for (const auto &s : w.sessions)
            if (s.parentId == parentId && !parentId.isEmpty())
                ids << s.id;
    return ids;
}

QString Store::addCompanion(const QString &parentId, const QString &name, const QString &cwd, const QString &command)
{
    const Session *p = session(parentId);
    if (!p)
        return {};
    const QString parent = p->parentId.isEmpty() ? parentId : p->parentId;
    auto *w = workspaceOf(parent);
    int at = indexIn(*w, parent) + 1;
    while (at < w->sessions.size() && w->sessions[at].parentId == parent)
        ++at;
    Session s;
    s.id = newId();
    s.cwd = cwd.isEmpty() ? session(parent)->cwd : cwd;
    s.name = name;
    s.command = command;
    s.parentId = parent;
    w->sessions.insert(at, s);
    Q_EMIT sessionAdded(s.id);
    Q_EMIT changed();
    return s.id;
}

void Store::removeSession(const QString &id)
{
    auto *w = workspaceOf(id);
    if (!w)
        return;
    for (const QString &c : companionsOf(id))
        removeSession(c); // closing the parent closes the group
    const int i = indexIn(*w, id);
    const Session &gone = w->sessions[i];
    closed.prepend({w->id, gone.name, gone.cwd, i, gone.id, QDateTime::currentMSecsSinceEpoch(), gone.displayName(), gone.resume});
    if (closed.size() > 20)
        closed.removeLast();
    w->sessions.removeAt(i);
    recent.removeAll(id);
    if (selected == id)
        reselect(w, i);
    Q_EMIT sessionRemoved(id);
    Q_EMIT changed();
}

void Store::reselect(const Workspace *w, int i)
{
    // most recent in the same workspace, the adjacent row, then most recent anywhere: each kept on screen first
    QSet<QString> shown;
    for (auto *s : navigableSessions())
        shown << s->id;
    QString next;
    for (const auto &r : std::as_const(recent))
        if (w && indexIn(*w, r) >= 0 && shown.contains(r)) {
            next = r;
            break;
        }
    for (int k = i; w && next.isEmpty() && k < w->sessions.size(); ++k)
        if (shown.contains(w->sessions[k].id))
            next = w->sessions[k].id;
    for (int k = w ? qMin(i, int(w->sessions.size())) - 1 : -1; next.isEmpty() && k >= 0; --k)
        if (shown.contains(w->sessions[k].id))
            next = w->sessions[k].id;
    for (const auto &r : std::as_const(recent))
        if (next.isEmpty() && shown.contains(r))
            next = r;
    if (next.isEmpty() && w && !w->sessions.isEmpty())
        next = w->sessions[qMin(i, int(w->sessions.size()) - 1)].id;
    if (next.isEmpty() && !recent.isEmpty())
        next = recent.first();
    if (next.isEmpty())
        if (auto all = allSessions(); !all.isEmpty())
            next = all.first()->id;
    selected.clear();
    if (!next.isEmpty())
        select(next);
    else
        Q_EMIT selectionChanged({});
}

bool Store::softClose(const QStringList &ids)
{
    // a parent takes its companions; the panes stay alive, hidden, until the grace expires
    QStringList group;
    for (const QString &id : ids)
        if (session(id))
            group << id << companionsOf(id);
    PendingClose close{++m_pendingSerial};
    for (auto *s : allSessions())
        if (group.contains(s->id)) {
            auto *w = workspaceOf(s->id);
            close.sessions << Parked{w->id, indexIn(*w, s->id), *s};
        }
    if (close.sessions.isEmpty())
        return false;
    const Parked first = close.sessions.first();
    close.select = group.contains(selected) ? selected : first.session.id;
    const bool wasSelected = group.contains(selected);
    for (auto it = close.sessions.crbegin(); it != close.sessions.crend(); ++it) {
        workspace(it->workspaceId)->sessions.removeAt(it->index);
        recent.removeAll(it->session.id);
    }
    if (wasSelected) {
        const Parked &at = *std::find_if(close.sessions.cbegin(), close.sessions.cend(), [this](const Parked &p) { return p.session.id == selected; });
        reselect(workspace(at.workspaceId), at.index);
    }
    return park(close);
}

bool Store::softRemoveWorkspace(const QString &id)
{
    const auto at = std::find_if(workspaces.cbegin(), workspaces.cend(), [&id](const Workspace &w) { return w.id == id; });
    if (at == workspaces.cend())
        return false;
    PendingClose close{++m_pendingSerial};
    close.workspace = *at;
    close.workspaceIndex = int(at - workspaces.cbegin());
    close.focusMember = focused.contains(id);
    focused.removeAll(id);
    focusEnabled = focusEnabled && !focused.isEmpty();
    if (freshWorkspace == id)
        freshWorkspace.clear();
    const bool wasSelected = workspaceOf(selected) && workspaceOf(selected)->id == id;
    workspaces.removeAt(close.workspaceIndex);
    for (const auto &s : close.workspace.sessions)
        recent.removeAll(s.id);
    close.select = wasSelected ? selected : QString();
    if (wasSelected)
        reselect(nullptr, 0);
    return park(close);
}

bool Store::park(const PendingClose &close)
{
    pending << close;
    QTimer::singleShot(graceMs, this, [this, serial = close.serial] { finalizePending(serial); });
    Q_EMIT changed();
    return true;
}

void Store::finalizePending(int serial)
{
    for (int i = 0; i < pending.size(); ++i) {
        if (serial >= 0 && pending[i].serial != serial)
            continue;
        const PendingClose c = pending.takeAt(i--);
        QList<Parked> gone = c.sessions;
        for (int k = 0; k < c.workspace.sessions.size(); ++k)
            gone << Parked{c.workspace.id, k, c.workspace.sessions[k]};
        for (const Parked &p : std::as_const(gone)) {
            closed.prepend({p.workspaceId, p.session.name, p.session.cwd, p.index, p.session.id, QDateTime::currentMSecsSinceEpoch(),
                            p.session.displayName(), p.session.resume});
            Q_EMIT sessionRemoved(p.session.id);
        }
        while (closed.size() > 20)
            closed.removeLast();
        Q_EMIT changed();
    }
}

bool Store::undoClose()
{
    if (pending.isEmpty())
        return false;
    const PendingClose c = pending.takeLast();
    if (!c.workspace.id.isEmpty()) {
        workspaces.insert(qMin(c.workspaceIndex, int(workspaces.size())), c.workspace);
        if (c.focusMember)
            focused << c.workspace.id; // membership only: the filter flag is current state
    }
    for (const Parked &p : c.sessions) {
        Workspace *w = workspace(p.workspaceId);
        if (!w) // its workspace went meanwhile
            w = workspace(workspaces.isEmpty() ? addWorkspace(QStringLiteral("main")) : workspaces.first().id);
        w->sessions.insert(qMin(p.index, int(w->sessions.size())), p.session);
    }
    if (!c.select.isEmpty())
        select(c.select);
    Q_EMIT changed();
    return true;
}

QString Store::reopenClosed(const QString &closedId)
{
    qsizetype at = 0;
    while (!closedId.isEmpty() && at < closed.size() && closed[at].id != closedId)
        ++at;
    if (at >= closed.size())
        return {};
    const Closed c = closed.takeAt(at);
    QString ws = c.workspaceId;
    if (!workspace(ws))
        ws = workspaces.isEmpty() ? addWorkspace(QStringLiteral("main")) : workspaces.first().id;
    const QString id = addSession(ws, c.name, c.cwd, {}, c.index, c.resume);
    select(id);
    return id;
}

void Store::removeWorkspace(const QString &id)
{
    auto *w = workspace(id);
    if (!w)
        return;
    focused.removeAll(id);
    focusEnabled = focusEnabled && !focused.isEmpty();
    if (freshWorkspace == id)
        freshWorkspace.clear();
    QStringList ids;
    for (const auto &s : w->sessions)
        ids << s.id;
    for (const auto &sid : ids)
        removeSession(sid);
    for (int i = 0; i < workspaces.size(); ++i)
        if (workspaces[i].id == id)
            workspaces.removeAt(i--);
    Q_EMIT changed();
}

void Store::renameSession(const QString &id, const QString &name)
{
    if (auto *s = session(id)) {
        s->name = name.trimmed();
        Q_EMIT changed();
    }
}

void Store::renameWorkspace(const QString &id, const QString &name)
{
    if (auto *w = workspace(id); w && !name.trimmed().isEmpty()) {
        w->name = name.trimmed();
        Q_EMIT changed();
    }
}

bool Store::moveSession(const QString &id, const QString &workspaceId, int index)
{
    auto *from = workspaceOf(id);
    if (!from || !workspace(workspaceId))
        return false;
    const int at = indexIn(*from, id);
    const QString parent = from->sessions[at].parentId;
    if (!parent.isEmpty()) {
        // a companion reorders only among its parent's companions
        if (from->id != workspaceId)
            return false;
        const int first = indexIn(*from, parent) + 1;
        const int end = first + int(companionsOf(parent).size());
        index = qBound(first, index < 0 ? end : index, end);
    } else if (index >= 0) {
        auto *to = workspace(workspaceId);
        while (index < to->sessions.size() && index > 0 && !to->sessions[index].parentId.isEmpty())
            ++index; // never land inside another session's companion group
    }
    // a parent carries its companions
    int count = 1;
    while (at + count < from->sessions.size() && from->sessions[at + count].parentId == id)
        ++count;
    QList<Session> block = from->sessions.mid(at, count);
    from->sessions.remove(at, count);
    auto *to = workspace(workspaceId);
    if (to == from && index > at)
        index -= qMin(count, index - at); // the removal shifted the target
    int dest = index < 0 || index > to->sessions.size() ? int(to->sessions.size()) : index;
    for (const Session &s : block)
        to->sessions.insert(dest++, s);
    if (focusEnabled && !flaggedView && !focused.contains(workspaceId))
        for (const Session &s : block)
            if (s.id == selected)
                focusEnabled = false;
    Q_EMIT changed();
    return true;
}

QJsonObject Store::bridge(char *(*call)(const char *), const QJsonObject &request)
{
    char *raw = call(QJsonDocument(request).toJson(QJsonDocument::Compact).constData());
    const QJsonObject reply = QJsonDocument::fromJson(raw ? QByteArray(raw) : QByteArray()).object();
    elis_free(raw);
    return reply;
}

// a --to step by ElisCore's ReorderDirection; -1 at that end
static int reorderDestination(const QString &direction, int index, int count)
{
    return Store::bridge(elis_reorder_destination, {{"to", direction}, {"index", index}, {"count", count}}).value("destination").toInt(-1);
}

// The session moves are AppStore+SessionMoves.swift's over this store's rows; their index math comes from ElisCore.

QList<QStringList> Store::sessionOrder() const
{
    QList<QStringList> order;
    for (const auto &w : workspaces) {
        order << QStringList{};
        for (const auto &s : w.sessions)
            order.last() << s.id;
    }
    return order;
}

// the first remaining top-level row from index on that is not in the moving block, "" for the end
static QString insertionAnchor(const Workspace &to, const QStringList &moving, const QStringList &block, int index)
{
    if (index < 0)
        return {};
    QList<const Session *> remaining;
    for (const Session &s : to.sessions)
        if (!moving.contains(s.id))
            remaining << &s;
    for (qsizetype i = qBound(qsizetype(0), qsizetype(index), remaining.size()); i < remaining.size(); ++i)
        if (!block.contains(remaining[i]->id) && remaining[i]->parentId.isEmpty())
            return remaining[i]->id;
    return {};
}

void Store::relocate(const QStringList &block, const QString &workspaceId, const QString &before)
{
    const QList<QStringList> was = sessionOrder();
    QList<Session> moving;
    for (const QString &id : block)
        if (Workspace *w = workspaceOf(id))
            moving << w->sessions.takeAt(indexIn(*w, id));
    Workspace *to = workspace(workspaceId);
    const int at = before.isEmpty() ? int(to->sessions.size()) : indexIn(*to, before);
    for (int i = 0; i < moving.size(); ++i)
        to->sessions.insert(at + i, moving[i]);
    if (focusEnabled && !flaggedView && block.contains(selected) && !focused.contains(workspaceId))
        focusEnabled = false; // the selection left the marked set
    if (sessionOrder() != was)
        Q_EMIT changed();
}

// siblings reorder within their group: index counts the workspace without them and falls from right after the parent to
// the group's end; -1 appends to the group
bool Store::moveCompanions(const QStringList &ids, int index)
{
    Workspace *w = workspaceOf(ids.value(0));
    const QString parent = w ? session(ids.first())->parentId : QString();
    if (parent.isEmpty())
        return false;
    QList<Session> moving, remaining;
    for (const Session &s : std::as_const(w->sessions))
        (ids.contains(s.id) ? moving : remaining) << s;
    if (moving.size() != ids.size() || std::any_of(moving.cbegin(), moving.cend(), [&](const Session &s) { return s.parentId != parent; }))
        return false;
    const int at = int(std::find_if(remaining.cbegin(), remaining.cend(), [&](const Session &s) { return s.id == parent; }) - remaining.cbegin());
    if (at == remaining.size())
        return false;
    int end = at + 1;
    while (end < remaining.size() && !remaining[end].parentId.isEmpty())
        ++end;
    const int dest = index < 0 ? end : index;
    if (dest <= at || dest > end)
        return false;
    for (int i = 0; i < moving.size(); ++i)
        remaining.insert(dest + i, moving[i]);
    const QList<QStringList> was = sessionOrder();
    w->sessions = remaining;
    if (sessionOrder() != was)
        Q_EMIT changed();
    return true;
}

int Store::moveSessions(const QStringList &ids, const QString &workspaceId, int index)
{
    Workspace *to = workspace(workspaceId);
    QStringList ordered;
    for (Session *s : allSessions())
        if (ids.contains(s->id))
            ordered << s->id;
    if (!to || ordered.isEmpty())
        return 0;
    if (ordered.size() == 1 && session(ordered.first())->parentId.isEmpty()) {
        const QStringList block = QStringList{ordered.first()} + companionsOf(ordered.first());
        relocate(block, workspaceId, insertionAnchor(*to, ordered, block, index));
        return int(block.size());
    }
    QStringList parents;
    for (const QString &id : std::as_const(ordered))
        if (session(id)->parentId.isEmpty())
            parents << id;
    if (parents.isEmpty())
        return workspaceOf(ordered.first()) == to && moveCompanions(ordered, index) ? int(ordered.size()) : 0;
    if (index < 0)
        parents.removeIf([&](const QString &id) { return workspaceOf(id) == to; }); // groups already there stay
    if (parents.isEmpty())
        return 0;
    QStringList block;
    for (const QString &p : std::as_const(parents))
        block << p << companionsOf(p);
    relocate(block, workspaceId, insertionAnchor(*to, ordered, block, index));
    return int(block.size());
}

bool Store::placement(const QStringList &ids, const QString &anchorId, bool after, QString *workspaceId, int *index)
{
    const auto place = [this](const QString &id) {
        for (int w = 0; w < workspaces.size(); ++w)
            if (const int i = indexIn(workspaces[w], id); i >= 0)
                return QJsonObject{{"workspace", w}, {"index", i}, {"count", int(workspaces[w].sessions.size())}};
        return QJsonObject{};
    };
    QJsonArray sources;
    for (const QString &id : ids)
        sources << place(id);
    const QJsonObject landing = bridge(elis_session_placement, {{"sources", sources}, {"anchor", place(anchorId)}, {"after", after}});
    if (!landing.contains("destination"))
        return false;
    *workspaceId = workspaces.value(landing.value("workspace").toInt()).id;
    *index = landing.value("destination").toInt();
    return true;
}

void Store::reorderSession(const QString &id, const QString &direction)
{
    Workspace *w = workspaceOf(id);
    if (!w)
        return;
    const QList<Session> &ss = w->sessions;
    const int at = indexIn(*w, id);
    if (const QString parent = ss[at].parentId; !parent.isEmpty()) {
        const int p = indexIn(*w, parent);
        if (const int dest = p < 0 ? -1 : reorderDestination(direction, at - p - 1, int(companionsOf(parent).size())); dest >= 0)
            moveSessions({id}, w->id, p + 1 + dest);
        return;
    }
    QList<int> units; // the top-level rows
    for (int i = 0; i < ss.size(); ++i)
        if (ss[i].parentId.isEmpty())
            units << i;
    const int dest = reorderDestination(direction, int(units.indexOf(at)), int(units.size()));
    if (dest < 0)
        return;
    units.removeAll(at);
    moveSessions({id}, w->id, dest < units.size() ? units[dest] - (units[dest] > at ? 1 : 0) : int(ss.size()) - 1);
}

bool Store::moveWorkspace(const QString &id, int index)
{
    for (int i = 0; i < workspaces.size(); ++i)
        if (workspaces[i].id == id) {
            Workspace w = workspaces.takeAt(i);
            if (index > i)
                --index;
            workspaces.insert(index < 0 || index > workspaces.size() ? workspaces.size() : index, w);
            Q_EMIT changed();
            return true;
        }
    return false;
}

bool Store::reorderWorkspace(const QString &id, const QString &direction)
{
    for (int i = 0; i < workspaces.size(); ++i)
        if (workspaces[i].id == id) {
            if (const int dest = reorderDestination(direction, i, int(workspaces.size())); dest >= 0) {
                workspaces.move(i, dest);
                Q_EMIT changed();
            }
            return true;
        }
    return false;
}

// AppStore.selectWorkspace: its first session, or the empty workspace itself as the current one
bool Store::selectWorkspace(const QString &id)
{
    auto *w = workspace(id);
    if (!w)
        return false;
    if (!w->sessions.isEmpty()) {
        select(w->sessions.first().id);
        if (!std::exchange(freshWorkspace, QString()).isEmpty()) // the first session may already be the selection
            Q_EMIT changed();
        return true;
    }
    if (focusEnabled && !focused.contains(id))
        focused << id;
    freshWorkspace = id;
    Q_EMIT changed();
    return true;
}

void Store::select(const QString &id)
{
    auto *s = session(id);
    if (!s || selected == id)
        return;
    freshWorkspace.clear(); // a selection change ends the fresh workspace; a same-value one keeps it, as on the Mac
    if (focusEnabled && !flaggedView && !focused.contains(workspaceOf(id)->id))
        focusEnabled = false; // selecting outside the set suspends the filter, keeping the set
    selected = id;
    recent.removeAll(id);
    recent.prepend(id);
    s->unseen = 0; // focusing a session acknowledges its notifications
    if (s->status == QLatin1String("completed") && s->autoReset)
        setStatus(id, QStringLiteral("idle"));
    Q_EMIT selectionChanged(id);
    Q_EMIT changed();
}

bool Store::setStatus(const QString &id, const QString &status, bool autoReset, bool blink, bool ifIdle)
{
    auto *s = session(id);
    if (!s || !statuses.contains(status))
        return false;
    if (ifIdle && s->status != QLatin1String("idle"))
        return true;
    const bool same = s->status == status && s->blink == blink;
    s->autoReset = autoReset;
    s->blink = blink && status != QLatin1String("idle");
    if (same)
        return true;
    s->status = status;
    Q_EMIT statusChanged(id, status);
    Q_EMIT changed();
    return true;
}

void Store::setUnseen(const QString &id, int count)
{
    if (auto *s = session(id); s && s->unseen != count) {
        s->unseen = count;
        Q_EMIT titleChanged(id); // a repaint, not a save: unseen counts are not persisted
    }
}

void Store::setFlag(const QString &id, bool flagged)
{
    if (auto *s = session(id); s && s->flagged != flagged) {
        s->flagged = flagged;
        Q_EMIT changed();
    }
}

bool Store::focusWorkspace(const QString &id, const QString &mode)
{
    // marking (add) never applies the filter on its own, so a set is built with the whole tree on screen
    const bool exists = workspace(id);
    QStringList ids = focused;
    if (mode == QLatin1String("on") || (mode == QLatin1String("toggle") && !isSoleFocus(id))) {
        if (exists)
            commitFocus({id}, true);
    } else if (mode == QLatin1String("toggle")) {
        commitFocus({}, false);
    } else if (mode == QLatin1String("add")) {
        if (exists && !ids.contains(id))
            commitFocus(ids << id, focusEnabled);
    } else if (mode == QLatin1String("off")) {
        ids.removeAll(id);
        commitFocus(ids, focusEnabled);
    } else {
        return false;
    }
    return true;
}

void Store::setFilter(bool on)
{
    commitFocus(focused, on);
}

void Store::commitFocus(QStringList ids, bool enabled)
{
    enabled = enabled && !ids.isEmpty();
    if (ids == focused && enabled == focusEnabled)
        return;
    focused = ids;
    focusEnabled = enabled;
    if (!freshWorkspace.isEmpty() && focusEnabled && !focused.contains(freshWorkspace))
        freshWorkspace.clear();
    // a narrowing that hid the active session moves to the most recent one still on screen
    const auto nav = navigableSessions();
    const bool hidden = !selected.isEmpty() && std::none_of(nav.begin(), nav.end(), [this](Session *s) { return s->id == selected; });
    if (hidden && !nav.isEmpty()) {
        QString next = nav.first()->id;
        for (const auto &r : std::as_const(recent))
            if (std::any_of(nav.begin(), nav.end(), [&r](Session *s) { return s->id == r; })) {
                next = r;
                break;
            }
        select(next);
    }
    Q_EMIT changed();
}

Tint *Store::tintOf(const QString &id)
{
    if (auto *s = session(id))
        return &s->tint;
    auto *w = workspace(id);
    return w ? &w->tint : nullptr;
}

void Store::setTint(const QString &id, const QString &color)
{
    Tint *t = tintOf(id);
    const QString c = color.isEmpty() ? color : tintValue(color);
    if (!t || c.isEmpty() != color.isEmpty() || t->color == c)
        return;
    t->color = c;
    Q_EMIT changed();
}

void Store::setCwd(const QString &id, const QString &cwd)
{
    auto *s = session(id);
    if (!s || cwd.isEmpty())
        return;
    const QString c = QDir::cleanPath(cwd);
    auto *w = workspaceOf(id);
    if (s->cwd == c && w->folder == c)
        return;
    s->cwd = c;
    w->folder = c; // the workspace remembers where its sessions last were
    Q_EMIT changed();
}

void Store::setTitle(const QString &id, const QString &title)
{
    const QString t = stripTitleSpinner(title);
    if (auto *s = session(id); s && s->title != t) {
        s->title = t; // a program's title or a command's name: once per command at most, so saving is cheap
        Q_EMIT changed();
    }
}

void Store::setAgent(const QString &id, const QString &agent, const QString &pane)
{
    const QString at = agent.isEmpty() ? QString() : pane;
    if (auto *s = session(id); s && (s->agent != agent || s->agentPane != at)) {
        s->agent = agent;
        s->agentPane = at;
        Q_EMIT changed(); // tree.changed too: the phone's Chat follows the agent and its pane
    }
}

void Store::setAgentSessionId(const QString &id, const QString &claudeId)
{
    if (auto *s = session(id); s && s->agentSessionId != claudeId) {
        s->agentSessionId = claudeId;
        Q_EMIT changed();
    }
}

void Store::setCi(const QString &id, const QJsonObject &ci, const QList<InfoSpan> &spans)
{
    if (auto *s = session(id); s && (s->ci != ci || s->infoSpans != spans)) {
        s->ci = ci;
        s->infoSpans = spans;
        Q_EMIT changed(); // tree.changed too: `ci` is read back there
    }
}

void Store::setBusy(const QString &id, bool busy)
{
    if (auto *s = session(id); s && s->busy != busy) {
        s->busy = busy;
        Q_EMIT titleChanged(id); // a repaint, not a save
    }
}

void Store::setSettings(const Settings &s)
{
    settings = s;
    Q_EMIT settingsChanged();
    Q_EMIT changed();
}

// every field by its master name; empty strings and defaults stay out of the file
#define ELIS_SETTINGS_STRINGS(X)                                                                                                  \
    X(newSessionDirectory) X(newSessionCustomDirectory) X(newSessionPlacement) X(statusReset) X(lastLauncher) X(fontFamily) X(theme) \
    X(cursorStyle) X(cursorBlink) X(notificationSoundName) X(dockBounce) X(activeStatusColorHex) X(blockedStatusColorHex)            \
    X(completedStatusColorHex) X(activeStatusShape) X(blockedStatusShape) X(completedStatusShape) X(blockedStatusSoundName)            \
    X(configDirectory) X(restoreMode) X(autoFollowAttention) X(flaggedViewLayout) X(sidebarDensity) X(sessionInfoDisplay)
#define ELIS_SETTINGS_BOOLS(X)                                                                                                  \
    X(confirmCloseSession) X(closeUndo) X(workspaceRowClickExpands) X(notificationsEnabled) X(notificationBadgeEnabled) X(attentionIncludesActive) X(autoFollowStayOnActive) \
        X(windowBlur)
#define ELIS_SETTINGS_DOUBLES(X) X(fontSize) X(sidebarFontSize) X(interfaceFontSize) X(windowTransparency)
#define ELIS_SETTINGS_LISTS(X) X(hiddenInterfaceElements) X(shownInterfaceElements)

QJsonObject Settings::toJson() const
{
    QJsonObject o;
#define X(f) o.insert(QStringLiteral(#f), f);
    ELIS_SETTINGS_STRINGS(X) ELIS_SETTINGS_BOOLS(X) ELIS_SETTINGS_DOUBLES(X)
#undef X
#define X(f) o.insert(QStringLiteral(#f), QJsonArray::fromStringList(f));
    ELIS_SETTINGS_LISTS(X)
#undef X
    return o;
}

Settings Settings::fromJson(const QJsonObject &o)
{
    Settings s;
#define X(f) s.f = o.value(QStringLiteral(#f)).toString(s.f);
    ELIS_SETTINGS_STRINGS(X)
#undef X
#define X(f) s.f = o.value(QStringLiteral(#f)).toBool(s.f);
    ELIS_SETTINGS_BOOLS(X)
#undef X
#define X(f) s.f = o.value(QStringLiteral(#f)).toDouble(s.f);
    ELIS_SETTINGS_DOUBLES(X)
#undef X
#define X(f)                                                                                                                       \
    for (const auto &v : o.value(QStringLiteral(#f)).toArray())                                                                    \
        s.f << v.toString();
    ELIS_SETTINGS_LISTS(X)
#undef X
    return s;
}

bool Settings::shows(const QString &element) const
{
    static const QStringList offByDefault{QStringLiteral("workspaceName"), QStringLiteral("customCommands")};
    return offByDefault.contains(element) ? shownInterfaceElements.contains(element) : !hiddenInterfaceElements.contains(element);
}

void Store::keyPressed(const QString &id, Key key)
{
    auto *s = session(id);
    if (!s)
        return;
    bool clear = false;
    if (s->status == QLatin1String("active"))
        clear = key == Key::Interrupt;
    else if (s->status == QLatin1String("blocked") || s->status == QLatin1String("completed")) {
        if (settings.statusReset == QLatin1String("firstKey"))
            clear = true;
        else if (settings.statusReset == QLatin1String("enter"))
            clear = key == Key::Submit || (s->status == QLatin1String("blocked") && key == Key::Interrupt);
    }
    if (clear)
        setStatus(id, QStringLiteral("idle"));
}

void Store::toggleSplit(const QString &id, const QString &axis)
{
    Session *s = session(id);
    if (!s)
        return;
    if (!s->hasSplit || !s->splitVisible)
        return setSplit(id, true, true, axis);
    setSplit(id, true, s->splitAxis != axis, axis);
}

void Store::setSplit(const QString &id, bool hasSplit, bool visible, const QString &axis)
{
    Session *s = session(id);
    if (!s || (axis != QLatin1String("vertical") && axis != QLatin1String("horizontal")))
        return;
    s->hasSplit = hasSplit;
    s->splitVisible = hasSplit && visible;
    s->splitAxis = axis;
    Q_EMIT paneLayoutChanged(id);
    Q_EMIT changed();
}

QString Store::go(const QString &direction, QString *error)
{
    static const QStringList known{"next", "prev", "first", "last", "next-attention", "prev-attention"};
    const QString to = direction == QLatin1String("previous") ? QStringLiteral("prev")
                       : direction == QLatin1String("previous-attention") ? QStringLiteral("prev-attention") : direction;
    if (!known.contains(to)) {
        *error = QStringLiteral("session.go requires --to next|prev|first|last|next-attention|prev-attention");
        return {};
    }
    return goTo(to, error);
}

QString Store::goTo(const QString &direction, QString *error)
{
    const auto all = navigableSessions();
    if (all.isEmpty()) {
        *error = QStringLiteral("no session to navigate");
        return {};
    }
    if (direction == QLatin1String("first") || direction == QLatin1String("last")) {
        const QString id = (direction == QLatin1String("first") ? all.first() : all.last())->id;
        select(id);
        return id;
    }
    const bool attention = direction.endsWith(QLatin1String("-attention"));
    const bool back = direction.startsWith(QLatin1String("prev"));
    int at = -1;
    for (int i = 0; i < all.size(); ++i)
        if (all[i]->id == selected)
            at = i;
    const int n = all.size();
    for (int step = 1; step <= n; ++step) {
        const int idx = at < 0 ? (back ? n - step : step - 1) : ((at + (back ? -step : step)) % n + n) % n;
        auto *s = all[idx];
        if (!attention || s->status == QLatin1String("blocked") || s->status == QLatin1String("completed")
            || (settings.attentionIncludesActive && s->status == QLatin1String("active"))) {
            select(s->id);
            return s->id;
        }
    }
    if (selected.isEmpty()) // nothing needs attention: the selection stays, as master
        *error = QStringLiteral("no session to navigate");
    return selected;
}

QString Store::takeReplay(const QString &id, bool split, const QStringList &denylist)
{
    Session *s = session(id);
    if (!s)
        return {};
    const QStringList argv = std::exchange(split ? s->splitReplay : s->replay, {});
    if (!split && !s->resume.isEmpty()) // a reopened agent session: past the restore mode, its pane spawns once
        return s->resume;
    if (restoreModeAtLaunch != QLatin1String("rerun") && restoreModeAtLaunch != QLatin1String("live")) // live: for a daemon that is gone
        return {};
    if (const auto &pin = split ? s->splitRestorePin : s->restorePin)
        return *pin; // typed verbatim, past the denylist
    return Restore::shouldRestore(argv, denylist) ? Restore::shellQuoted(argv) : QString();
}

QJsonObject Store::toJson() const
{
    QJsonArray ws;
    for (const auto &w : workspaces) {
        QJsonArray ss;
        for (const auto &s : w.sessions) {
            QJsonObject so{{"id", s.id},           {"name", s.name},
                           {"cwd", s.cwd}, {"title", s.title}, {"flagged", s.flagged}, {"parentId", s.parentId},
                           {"hasSplit", s.hasSplit}, {"splitVisible", s.splitVisible},
                           {"splitAxis", s.splitAxis}, {"splitRatio", s.splitRatio},
                           {"fontSize", s.fontSize}, {"splitFontSize", s.splitFontSize}};
            if (!s.tint.color.isEmpty())
                so.insert("tint", tintJson(s.tint));
            if (!s.foreground.isEmpty())
                so.insert("foregroundCommand", QJsonArray::fromStringList(s.foreground));
            if (!s.splitForeground.isEmpty())
                so.insert("splitForegroundCommand", QJsonArray::fromStringList(s.splitForeground));
            if (s.restorePin)
                so.insert("restoreCommand", *s.restorePin);
            if (s.splitRestorePin)
                so.insert("splitRestoreCommand", *s.splitRestorePin);
            if (!s.context.isEmpty())
                so.insert("context", s.context);
            if (!s.paneId.isEmpty())
                so.insert("paneId", s.paneId);
            if (s.hasSplit && !s.splitPaneId.isEmpty())
                so.insert("splitPaneId", s.splitPaneId);
            ss << so;
        }
        QJsonObject wo{{"id", w.id}, {"name", w.name}, {"folder", w.folder}, {"sessions", ss}};
        if (!w.projectFolder.isEmpty())
            wo.insert("projectFolder", w.projectFolder);
        if (!w.tint.color.isEmpty())
            wo.insert("tint", tintJson(w.tint));
        ws << wo;
    }
    QJsonArray cl;
    for (const auto &c : closed)
        cl << QJsonObject{{"id", c.id},       {"workspaceId", c.workspaceId}, {"name", c.name},     {"cwd", c.cwd},
                          {"index", c.index}, {"closedAt", c.closedAt},       {"title", c.title}, {"resume", c.resume}};
    const QJsonObject st = settings.toJson();
    return {{"version", 2},      {"closed", cl},      {"selected", selected}, {"recent", QJsonArray::fromStringList(recent)},
            {"settings", st},    {"workspaces", ws},     {"focusedWorkspaces", QJsonArray::fromStringList(focused)},
            {"focusEnabled", focusEnabled}};
}

void Store::fromJson(const QJsonObject &o)
{
    const int version = o.value("version").toInt(1);
    workspaces.clear();
    freshWorkspace.clear();
    for (const auto &wv : o.value("workspaces").toArray()) {
        const auto wo = wv.toObject();
        Workspace w{wo.value("id").toString(), wo.value("name").toString(), wo.value("folder").toString(), {}, tintFromJson(wo.value("tint")),
                    wo.value("projectFolder").toString()};
        if (w.id.isEmpty())
            continue;
        for (const auto &sv : wo.value("sessions").toArray()) {
            const auto so = sv.toObject();
            Session s;
            s.id = so.value("id").toString();
            s.cwd = so.value("cwd").toString();
            s.name = so.value("name").toString();
            if (version < 2 && s.name == QFileInfo(s.cwd).fileName()) // v1 stored the derived name
                s.name.clear();
            s.title = so.value("title").toString();
            s.flagged = so.value("flagged").toBool();
            s.context = so.value("context").toString();
            s.parentId = so.value("parentId").toString();
            s.tint = tintFromJson(so.value("tint"));
            s.fontSize = so.value("fontSize").toDouble();
            s.splitFontSize = so.value("splitFontSize").toDouble();
            s.hasSplit = so.value("hasSplit").toBool();
            s.splitVisible = s.hasSplit && so.value("splitVisible").toBool();
            s.splitAxis = so.value("splitAxis").toString(QStringLiteral("vertical"));
            s.splitRatio = qBound(0.05, so.value("splitRatio").toDouble(0.5), 0.95);
            // the capture moves into a one-shot slot: the next save writes it as gone, so it replays exactly once
            for (const auto &v : so.value("foregroundCommand").toArray())
                s.replay << v.toString();
            for (const auto &v : so.value("splitForegroundCommand").toArray())
                s.splitReplay << v.toString();
            if (so.contains("restoreCommand"))
                s.restorePin = so.value("restoreCommand").toString();
            if (so.contains("splitRestoreCommand"))
                s.splitRestorePin = so.value("splitRestoreCommand").toString();
            s.paneId = so.value("paneId").toString();
            s.splitPaneId = s.hasSplit ? so.value("splitPaneId").toString() : QString();
            if (!s.id.isEmpty())
                w.sessions << s;
        }
        workspaces << w;
    }
    closed.clear();
    for (const auto &cv : o.value("closed").toArray()) {
        const auto co = cv.toObject();
        if (!co.value("id").toString().isEmpty())
            closed << Closed{co.value("workspaceId").toString(), co.value("name").toString(), co.value("cwd").toString(), co.value("index").toInt(-1),
                             co.value("id").toString(),          qint64(co.value("closedAt").toDouble()), co.value("title").toString(), co.value("resume").toString()};
    }
    settings = Settings::fromJson(o.value("settings").toObject());
    if (!std::exchange(m_loaded, true))
        restoreModeAtLaunch = settings.restoreMode;
    focused.clear();
    for (const auto &f : o.value("focusedWorkspaces").toArray())
        if (workspace(f.toString())) // stale ids are pruned, so the filter never restores enabled and empty
            focused << f.toString();
    focusEnabled = o.value("focusEnabled").toBool() && !focused.isEmpty();
    recent.clear();
    for (const auto &r : o.value("recent").toArray())
        if (session(r.toString()))
            recent << r.toString();
    selected = session(o.value("selected").toString()) ? o.value("selected").toString() : QString();
    if (selected.isEmpty())
        if (auto all = allSessions(); !all.isEmpty())
            selected = all.first()->id;
}
