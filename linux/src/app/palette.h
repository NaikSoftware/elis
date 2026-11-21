#pragma once

#include <QFrame>
#include <QPointer>
#include <functional>

class QLineEdit;
class QListWidget;

// elis's fuzzy palettes: type to filter, arrows or Ctrl-J/Ctrl-K to move, Enter to run, Esc to dismiss.
// In switcher mode (Ctrl-Tab) there is no search field: Tab walks the list and releasing Ctrl runs the pick.
class Palette : public QFrame
{
    Q_OBJECT
public:
    struct Item {
        QString title, subtitle;
        std::function<void()> run;
        bool enabled = true; // a disabled action still shows and matches, greyed out, and does nothing
        std::function<void()> preview; // runs when the row becomes current (the theme picker's live preview)
        QString id; // what the row stands for, for a caller that reorders its items
    };

    explicit Palette(QWidget *window);
    // cancel runs on Esc or a click outside, not after a pick; current = the row selected at open
    void open(const QString &placeholder, const QList<Item> &items, bool switcher = false, std::function<void()> cancel = {}, int current = -1);
    void step(int delta);
    void setQuery(const QString &query); // after open: a prefilled, already filtered search
    QString query() const;
    // Enter with no enabled row runs this with the query (pick --allow-custom); open() clears it
    std::function<void(const QString &)> custom;
    // the next open() hangs under this widget, centred on it, as elis's switcher hangs under its title pill; open() clears it
    QPointer<QWidget> anchor;
    bool switching() const { return isVisible() && m_switcher; }

    static bool fuzzyMatch(const QString &needle, const QString &haystack); // case-insensitive subsequence

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    void filter();
    void runCurrent();
    void place();

    QLineEdit *m_search;
    QListWidget *m_list;
    QList<Item> m_items;
    bool m_switcher = false;
    std::function<void()> m_cancel;
    int m_initial = -1;
    QPointer<QWidget> m_anchor;
    void dismiss();
};
