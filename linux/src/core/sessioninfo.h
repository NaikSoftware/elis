#pragma once

#include <QList>
#include <QString>

// One styled run of a session's sidebar info line.
struct InfoSpan {
    QString text;
    bool bold = false, italic = false, code = false, dim = false;
    QString color; // an ElisCore TintColor name; "" = the row's own colour
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

    // ElisCore's SessionInfo.make through ElisBridge: the Mac's validation and markup; *error carries its rejection
    static SessionInfo make(const QString &source, bool markdown, double hideAfter, QString *error);
};

// sidebar.density's mode ("" toggles) against the current density, by ElisCore's parse; "" and *error on a refusal
QString sidebarDensity(const QString &mode, const QString &current, QString *error);
