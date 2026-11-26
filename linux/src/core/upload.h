#pragma once

#include <QJsonObject>
#include <QString>
#include <QStringList>

#include <optional>

// session.upload through ElisBridge: ElisCore's argument check and path reservation, shared with the Mac.
QJsonObject uploadReserve(const QString &stateDir, const QString &sessionId, const QJsonObject &args);

// Drops upload folders of sessions `keep` lacks and files past the age cap; nullopt (a window file unreadable) keeps every folder.
void uploadSweep(const QString &stateDir, const std::optional<QStringList> &keep);
