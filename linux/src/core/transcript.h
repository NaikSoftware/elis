#pragma once

#include <QByteArray>
#include <QDateTime>
#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QString>
#include <QStringList>

#include <functional>
#include <memory>
#include <optional>
#include <utility>

// session.transcript: pages of a Claude Code transcript JSONL, a port of ElisCore's ClaudeTranscript*.swift and
// ClaudeCommandCatalog.swift, which stay the reference. Items, pending calls, meta and commands are the wire objects,
// a Swift nil being an absent key. The spec docs/superpowers/specs/2026-11-20-phone-chat-mode-design.md owns the shapes.
namespace Transcript {

constexpr int pageBudget = 49152, clipBytes = 4096, itemCap = 16384;
constexpr qint64 missRetryMs = 2000;              // a lookup that found nothing answers so until this passes
constexpr qint64 agentSilenceMs = 15 * 60 * 1000; // a launched agent's file unwritten this long reads as gone
inline const QString notFound = QStringLiteral("transcript not found");

// ClaudeHome.directory: configDir (CLAUDE_CONFIG_DIR) when it is absolute, else <home>/.claude
QString claudeHome(const QString &configDir, const QString &home);
// SessionLauncher.plainSessionID: id when it is a nonempty run of ASCII letters, digits, _ and -, else ""
QString plainSessionId(const QString &id);
// bytes as Swift's JSONEncoder writes the value (it escapes '/'); the page budget and the item cap count these
int encodedSize(const QJsonObject &object);
int encodedSize(const QList<QJsonObject> &array);

// One transcript line's index fields; bodies are reread from the file by offset.
struct Record {
    std::optional<QString> uuid, parent, logicalParent;
    qint64 offset = 0;
    int length = 0;
    QString type;
    std::optional<QString> subtype;
    bool sidechain = false;
    std::optional<QString> messageId;
    bool oversized = false;
};

// An Agent call folded from the main records; the page resolves a launched one's state from its file.
struct Agent {
    int call = 0;           // its record
    QJsonObject wire;       // ControlTranscriptAgent: id, agentType, name, color, description, startedAt, state
    std::optional<QString> file; // subagents/agent-<file>.jsonl of a background agent or teammate
    bool launched = false;
    std::optional<std::pair<QString, std::optional<QString>>> ended; // state, timestamp
};

// ClaudeTranscriptIndex: a transcript indexed once and extended per poll; only whole lines count.
class Index
{
public:
    static constexpr int chunk = 1 << 20, lineWindow = 4 << 20, prefixLength = 4096;

    explicit Index(const QString &path, bool keepsSidechains = false);
    // indexes lines appended since the last call; false when the file shrank, changed its head or is unreadable
    bool extend();
    std::optional<int> resultIndex(const QString &toolUseId) const;
    QList<int> activeChain();   // record indices root to leaf
    QList<int> activeRecords(); // the chain, its messages' other records and their calls' results, sorted

    const QString &path() const { return m_path; }
    bool keepsSidechains() const { return m_keepsSidechains; }
    qint64 end() const { return m_end; }
    qint64 size() const { return m_size; }
    const QList<Record> &records() const { return m_records; }
    int skipped() const { return m_skipped; }
    const QHash<QString, int> &openCalls() const { return m_openCalls; }
    const QJsonObject &meta() const { return m_meta; } // ControlTranscriptMeta without `agents`
    const QHash<QString, int> &toolUses() const { return m_toolUses; }  // tool_use id -> record, kept after it closes
    const QHash<int, QStringList> &closers() const { return m_closers; } // result record -> the ids it closes
    const QList<int> &skillListings() const { return m_skillListings; } // skill_listing records since the last initial
    const QHash<QString, Agent> &agents() const { return m_agents; }    // Agent tool_use id -> its call

private:
    QString m_path;
    bool m_keepsSidechains;
    qint64 m_end = 0, m_size = 0;
    QList<Record> m_records;
    int m_skipped = 0;
    QHash<QString, int> m_openCalls;
    QJsonObject m_meta;
    QHash<QString, int> m_toolUses;
    QHash<int, QStringList> m_closers;
    QList<int> m_skillListings;
    QHash<QString, Agent> m_agents;
    QByteArray m_prefix;
    QHash<QString, int> m_byUuid, m_results;
    std::optional<QString> m_customTitle, m_aiTitle;
    QList<std::optional<QString>> m_queue; // nullopt holds a content-less enqueue's place
    std::optional<std::pair<int, QList<int>>> m_chainCache, m_activeCache;
};

// ClaudeTranscriptItems: one decoded record to its items; the spec's "Records kept as items" table is the only way in.
namespace Items {
using Spilled = std::function<std::optional<QByteArray>(const QString &toolUseId)>; // tool-results/<id>.txt, head only
QList<QJsonObject> items(const QJsonObject &record, qint64 at, const std::optional<QJsonObject> &result, const Spilled &spilled);
std::optional<QString> tag(const QString &name, const QString &text); // inside the first <name>…</name>
std::pair<QString, bool> clip(const QString &text, int limitBytes);   // cut on a character boundary; true when it cut
QJsonObject capped(QJsonObject item);                                 // shrunk until it encodes within itemCap
} // namespace Items

// ClaudeCommandCatalog: the "/" menu, Claude Code's built-ins plus the skills its transcript lists.
namespace Commands {
constexpr int descriptionLimit = 160;
struct Listing {
    bool isInitial = false;
    QStringList names;
    QString content;
};
const QList<QJsonObject> &builtins(); // {name, description, source: builtin, panel: true for the panel set}
QList<QJsonObject> skills(const QList<Listing> &listings);
} // namespace Commands

struct Request {
    QString sessionId;
    std::optional<qint64> after, before;
    std::optional<QString> held; // the id the caller holds; only compared
    int maxBytes = pageBudget;
};

struct Page {
    QString transcript;
    qint64 size = 0, start = 0, next = 0;
    bool reset = false;
    QList<QJsonObject> items, pending;
    QJsonObject meta;
    std::optional<QList<QJsonObject>> commands;
    int skipped = 0;

    // the flat session.transcript result: reset only when true, pending when any, commands when set, skipped when not 0
    QJsonObject result() const;
};

// ClaudeTranscript: pages of <claudeDirectory>/projects/*/<id>.jsonl, each file indexed once and extended per poll.
// Not thread-safe: the dispatcher calls it on the GUI thread.
class Reader
{
public:
    explicit Reader(const QString &claudeDirectory, int cacheLimit = 8, int subagentCacheLimit = 64,
                    std::function<QDateTime()> now = &QDateTime::currentDateTimeUtc);
    static Reader &instance(const QString &claudeDirectory); // one per directory
    std::optional<Page> page(const Request &request);          // nullopt: transcript not found
    int scans() const { return m_scans; }                      // indexes built from scratch

private:
    struct Tail {
        QDateTime modified;
        qint64 size;
        bool endsTurn;
    };
    struct SubagentMeta {
        QDateTime modified;
        qint64 size;
        QString call;
        std::optional<QString> agentType;
    };
    std::optional<QString> path(const QString &id);
    std::shared_ptr<Index> index(const QString &path, bool keepsSidechains);
    bool refresh(std::shared_ptr<Index> &index);

    QString m_claudeDirectory;
    int m_cacheLimit, m_subagentCacheLimit;
    std::function<QDateTime()> m_now;
    int m_scans = 0;
    QHash<QString, QString> m_paths;
    QHash<QString, QDateTime> m_misses;
    QHash<QString, SubagentMeta> m_metas;
    QHash<QString, Tail> m_tails;
    // least recently used first, apart per keepsSidechains so an Agent fan-out never evicts a main transcript
    QHash<bool, QList<std::pair<QString, std::shared_ptr<Index>>>> m_indexes;
};

// True when the last whole conversation record is an assistant turn that ended (ClaudeTranscript.endsTurn).
bool endsTurn(const QByteArray &data, bool whole);

} // namespace Transcript
