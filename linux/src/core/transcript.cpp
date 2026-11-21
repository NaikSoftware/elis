#include "transcript.h"

// stub: the port lands against the frozen tests in tests/test_transcript.cpp
namespace Transcript {

QString claudeHome(const QString &, const QString &) { return {}; }
QString plainSessionId(const QString &) { return {}; }
int encodedSize(const QJsonObject &) { return 0; }
int encodedSize(const QList<QJsonObject> &) { return 0; }

Index::Index(const QString &path, bool keepsSidechains) : m_path(path), m_keepsSidechains(keepsSidechains) {}
bool Index::extend() { return false; }
std::optional<int> Index::resultIndex(const QString &) const { return {}; }
QList<int> Index::activeChain() { return {}; }
QList<int> Index::activeRecords() { return {}; }

namespace Items {
QList<QJsonObject> items(const QJsonObject &, qint64, const std::optional<QJsonObject> &, const Spilled &) { return {}; }
std::optional<QString> tag(const QString &, const QString &) { return {}; }
std::pair<QString, bool> clip(const QString &text, int) { return {text, false}; }
QJsonObject capped(QJsonObject item) { return item; }
} // namespace Items

namespace Commands {
const QList<QJsonObject> &builtins()
{
    static const QList<QJsonObject> none;
    return none;
}
QList<QJsonObject> skills(const QList<Listing> &) { return {}; }
} // namespace Commands

QJsonObject Page::result() const { return {}; }

Reader::Reader(const QString &claudeDirectory, int cacheLimit, int subagentCacheLimit, std::function<QDateTime()> now)
    : m_claudeDirectory(claudeDirectory), m_cacheLimit(cacheLimit), m_subagentCacheLimit(subagentCacheLimit), m_now(std::move(now))
{
}
Reader &Reader::instance(const QString &claudeDirectory)
{
    static QHash<QString, std::shared_ptr<Reader>> all;
    auto &made = all[claudeDirectory];
    if (!made)
        made = std::make_shared<Reader>(claudeDirectory);
    return *made;
}
std::optional<Page> Reader::page(const Request &) { return {}; }
std::optional<QString> Reader::path(const QString &) { return {}; }
std::shared_ptr<Index> Reader::index(const QString &, bool) { return {}; }
bool Reader::refresh(std::shared_ptr<Index> &) { return false; }

bool endsTurn(const QByteArray &, bool) { return false; }

} // namespace Transcript
