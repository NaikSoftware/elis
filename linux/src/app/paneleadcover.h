#pragma once

#include <QWidget>

#include <functional>

class QKeyEvent;
class QLabel;
namespace Zmx { struct Lead; }

// The Mac's PaneLeadCover: over a live pane whose zmx client does not lead its daemon (it draws output laid out for
// another client's grid), or a fresh attach that has not reported yet. A key takes the lead; a click focuses the pane.
class PaneLeadCover : public QWidget
{
    Q_OBJECT
public:
    // `takeOver` replaces the pane with a fresh attach that claims the lead; `ownShortcut` keeps the window's keys
    PaneLeadCover(QWidget *pane, QWidget *display, std::function<void()> takeOver, std::function<bool(QKeyEvent *)> ownShortcut);
    void apply(const Zmx::Lead &lead);
    static QString title(const QString &role, bool reattaching);

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;
    void mousePressEvent(QMouseEvent *) override;
    void paintEvent(QPaintEvent *) override;

private:
    QWidget *m_display;
    QLabel *m_title, *m_hint;
    bool m_covered = false, m_reattaching = false;
    std::function<void()> m_takeOver;
    std::function<bool(QKeyEvent *)> m_ownShortcut;
};
