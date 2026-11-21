#pragma once

#include "store.h"

#include <QJsonObject>
#include <QList>
#include <QStringList>

// One session's GitHub CI, as ElisCore's CITracker sees it: the tree's `ci` object and the sidebar line.
struct CiStatus {
    QJsonObject ci; // empty = none
    QList<InfoSpan> spans;
};

// Each cwd's status, in order. Blocks on gh for up to its timeout per repository, so it runs off the GUI thread,
// one call at a time.
QList<CiStatus> ciStatuses(const QStringList &cwds);
