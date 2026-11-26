#pragma once

#include <QObject>
#include <QPointer>
#include <QTimer>

#include <functional>

class QFrame;
class Sidebar;
class Store;
struct Session;

// The sidebar's CI line: polls ElisCore's CITracker for every session's working cwd and shows a row's CI panel on a click.
class CiLine : public QObject
{
    Q_OBJECT
public:
    CiLine(Store &store, Sidebar *sidebar, std::function<QString(const Session &)> workingCwd, QObject *parent);

private:
    void poll();
    void showPanel(const QString &sessionId, const QPoint &globalPos);
    void closeStalePanel();

    Store &m_store;
    Sidebar *m_sidebar;
    std::function<QString(const Session &)> m_workingCwd;
    QTimer m_timer;
    bool m_polling = false; // one tracker call at a time: an overlap would fetch a due repository twice
    QPointer<QFrame> m_panel;
    QString m_panelId;
};
