#pragma once

#include <QList>
#include <QString>

// One styled run of a session's sidebar info line.
struct InfoSpan {
    QString text;
    bool bold = false, italic = false, code = false, dim = false;
    QString color; // a Store::tintColors name; "" = the row's own colour
    bool operator==(const InfoSpan &) const = default;
};

// elis's session.info line: runtime only, never saved or duplicated. An empty source is no line.
struct SessionInfo {
    static constexpr int maxSourceBytes = 512;
    QString source;
    bool markdown = false;
    double hideAfter = 0; // seconds, 0 = until cleared
    QList<InfoSpan> spans;
    bool operator==(const SessionInfo &) const = default;

    // validates a set and parses its source; *error carries the control message on a refusal
    static SessionInfo make(const QString &source, bool markdown, double hideAfter, QString *error);
};
