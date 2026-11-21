#include "sessioninfo.h"

#include "store.h"

#include <QHash>

#include <cmath>

namespace {
// The Mac parses with Foundation's inline-only markdown plus ^[text](color: "NAME") and ^[text](dim: true).
// shortcut: a hand parser for the inline forms people write (emphasis, code, links, escapes, entities, the two
// attributes); upgrade to a CommonMark library if a caller needs its corner cases.
struct Parser {
    QString error;

    QList<InfoSpan> parse(const QString &s, InfoSpan style)
    {
        QList<InfoSpan> out;
        QString run;
        auto flush = [&] {
            if (!run.isEmpty())
                out << InfoSpan{run, style.bold, style.italic, style.code, style.dim, style.color};
            run.clear();
        };
        auto inner = [&](const QString &text, const InfoSpan &with) {
            flush();
            out << parse(text, with);
        };
        for (qsizetype i = 0; i < s.size() && error.isEmpty(); ++i) {
            const QChar c = s[i];
            if (c == QLatin1Char('\\') && i + 1 < s.size() && s[i + 1].isPunct()) {
                run += s[++i];
            } else if (c == QLatin1Char('`')) {
                const qsizetype end = s.indexOf(QLatin1Char('`'), i + 1);
                if (end < 0) {
                    run += c;
                    continue;
                }
                flush();
                InfoSpan code = style;
                code.code = true;
                code.text = s.mid(i + 1, end - i - 1);
                out << code;
                i = end;
            } else if ((c == QLatin1Char('^') && s.mid(i, 2) == QLatin1String("^[")) || c == QLatin1Char('[')) {
                const bool attributed = c == QLatin1Char('^');
                const qsizetype open = attributed ? i + 1 : i, close = matching(s, open);
                if (close < 0 || close + 1 >= s.size() || s[close + 1] != QLatin1Char('(')) {
                    run += c;
                    continue;
                }
                const qsizetype paren = s.indexOf(QLatin1Char(')'), close + 2);
                if (paren < 0) {
                    run += c;
                    continue;
                }
                InfoSpan with = style;
                if (attributed && !attributes(s.mid(close + 2, paren - close - 2), &with))
                    return {};
                inner(s.mid(open + 1, close - open - 1), with); // a link keeps its label and drops its target
                i = paren;
            } else if (c == QLatin1Char('*') || c == QLatin1Char('_')) {
                const bool strong = i + 1 < s.size() && s[i + 1] == c;
                const QString marker = strong ? QString(2, c) : QString(c);
                // an underscore inside a word is a letter (snake_case), as in CommonMark
                const bool wordBefore = i > 0 && s[i - 1].isLetterOrNumber();
                qsizetype end = s.indexOf(marker, i + marker.size());
                while (!strong && end >= 0 && end + 1 < s.size() && s[end + 1] == c)
                    end = s.indexOf(marker, end + 2);
                const bool wordAfter = end >= 0 && end + marker.size() < s.size() && s[end + marker.size()].isLetterOrNumber();
                if (end < 0 || end == i + marker.size() || (c == QLatin1Char('_') && (wordBefore || wordAfter))) {
                    run += marker;
                    i += marker.size() - 1;
                    continue;
                }
                InfoSpan with = style;
                (strong ? with.bold : with.italic) = true;
                inner(s.mid(i + marker.size(), end - i - marker.size()), with);
                i = end + marker.size() - 1;
            } else if (c == QLatin1Char('&')) {
                const qsizetype semi = s.indexOf(QLatin1Char(';'), i);
                const QString name = semi > i ? s.mid(i + 1, semi - i - 1) : QString();
                if (const QString decoded = entity(name); !decoded.isEmpty()) {
                    run += decoded;
                    i = semi;
                } else {
                    run += c;
                }
            } else {
                run += c;
            }
        }
        flush();
        return out;
    }

    static qsizetype matching(const QString &s, qsizetype open)
    {
        int depth = 0;
        for (qsizetype i = open; i < s.size(); ++i) {
            if (s[i] == QLatin1Char('\\'))
                ++i;
            else if (s[i] == QLatin1Char('['))
                ++depth;
            else if (s[i] == QLatin1Char(']') && --depth == 0)
                return i;
        }
        return -1;
    }

    static QString entity(const QString &name)
    {
        static const QHash<QString, QString> named{{"amp", "&"}, {"lt", "<"}, {"gt", ">"}, {"quot", "\""}, {"apos", "'"}, {"nbsp", QString(QChar(0xA0))}};
        if (named.contains(name))
            return named.value(name);
        bool ok = false;
        const uint code = name.startsWith(QLatin1String("#x"), Qt::CaseInsensitive) ? name.mid(2).toUInt(&ok, 16)
                          : name.startsWith(QLatin1Char('#'))                        ? name.mid(1).toUInt(&ok, 10)
                                                                                     : 0;
        return ok && code > 0 && code <= 0x10FFFF ? QString::fromUcs4(reinterpret_cast<const char32_t *>(&code), 1) : QString();
    }

    // color: "NAME" and dim: true, comma-separated; an unknown key is dropped, as Foundation drops it
    bool attributes(const QString &raw, InfoSpan *with)
    {
        for (const QString &pair : raw.split(QLatin1Char(','), Qt::SkipEmptyParts)) {
            const qsizetype colon = pair.indexOf(QLatin1Char(':'));
            const QString key = pair.left(colon).trimmed(), value = pair.mid(colon + 1).trimmed();
            const bool quoted = value.size() >= 2 && value.startsWith(QLatin1Char('"')) && value.endsWith(QLatin1Char('"'));
            if (colon < 0 || (!quoted && value != QLatin1String("true") && value != QLatin1String("false") && !isNumber(value))) {
                error = QStringLiteral("invalid info markdown; quote attribute values: ^[text](color: \"green\")");
                return false;
            }
            if (key == QLatin1String("color")) {
                const QString name = value.mid(1, value.size() - 2).toLower();
                if (!quoted || !Store::tintColors.contains(name)) {
                    error = QStringLiteral("unknown info color: %1 (%2)").arg(quoted ? value.mid(1, value.size() - 2) : value,
                                                                             Store::tintColors.join(QStringLiteral(", ")));
                    return false;
                }
                with->color = name;
            } else if (key == QLatin1String("dim")) {
                with->dim = value == QLatin1String("true");
            }
        }
        return true;
    }

    static bool isNumber(const QString &v)
    {
        bool ok = false;
        v.toDouble(&ok);
        return ok;
    }
};

QString lineError(const QString &text)
{
    for (const char32_t u : text.toUcs4()) {
        if (u == 0x0A || u == 0x0D || u == 0x2028 || u == 0x2029 || u == 0x85)
            return QStringLiteral("info text must be one line");
        if (QChar::category(u) == QChar::Other_Control)
            return QStringLiteral("info text contains a control character");
    }
    return text.trimmed().isEmpty() ? QStringLiteral("info text is empty") : QString();
}
} // namespace

SessionInfo SessionInfo::make(const QString &source, bool markdown, double hideAfter, QString *error)
{
    if (source.toUtf8().size() > maxSourceBytes) {
        *error = QStringLiteral("info text is over %1 bytes").arg(maxSourceBytes);
        return {};
    }
    if (!std::isfinite(hideAfter) || hideAfter < 0 || hideAfter > 86400) {
        *error = QStringLiteral("--hide-after must be 0...86400 seconds");
        return {};
    }
    Parser parser;
    QList<InfoSpan> spans = markdown ? parser.parse(source, {}) : QList<InfoSpan>{InfoSpan{source}};
    if (!parser.error.isEmpty()) {
        *error = parser.error;
        return {};
    }
    // neighbours of one style are one span
    QList<InfoSpan> merged;
    QString visible;
    for (InfoSpan &span : spans) {
        visible += span.text;
        InfoSpan probe = span;
        if (!merged.isEmpty() && (probe.text = merged.last().text, probe == merged.last()))
            merged.last().text += span.text;
        else if (!span.text.isEmpty())
            merged << span;
    }
    if (const QString e = lineError(visible); !e.isEmpty()) {
        *error = e;
        return {};
    }
    return {source, markdown, hideAfter, merged};
}
