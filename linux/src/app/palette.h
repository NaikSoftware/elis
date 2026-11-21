#pragma once

#include <QFrame>
#include <QPointer>
#include <QTimer>
#include <functional>

class QLineEdit;
class QListWidget;
struct Settings;

namespace PaletteRole {
enum {
    Subtitle = Qt::UserRole + 1,
    Index,
    Header,
    Status,
    Blink,
    Icon,
    Workspace,
    SingleLine,
};
}

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
        QString icon; // launcher id ("terminal", "claude", ...); empty = none
        QString workspace; // right-aligned workspace column in singleLine mode
        QString status; // non-idle status ("blocked", "active", "completed"); empty = none
        bool blink = false;
        bool singleLine = false;
    };

    struct Section {
        QString title;
        QList<Item> items;
    };

    explicit Palette(QWidget *window);
    // cancel runs on Esc or a click outside, not after a pick; current = the row selected at open
    void open(const QString &placeholder, const QList<Item> &items, bool switcher = false, std::function<void()> cancel = {}, int current = -1);
    // sectioned mode: empty query shows non-empty sections under headers; non-empty query filters searchItems under searchHeader
    void open(const QString &placeholder, const QList<Section> &sections, const QString &searchHeader, const QList<Item> &searchItems);
    void step(int delta);
    void setQuery(const QString &query); // after open: a prefilled, already filtered search
    QString query() const;
    // Enter with no enabled row runs this with the query (pick --allow-custom); open() clears it
    std::function<void(const QString &)> custom;
    // the next open() hangs under this widget, centred on it, as elis's switcher hangs under its title pill; open() clears it
    QPointer<QWidget> anchor;
    const Settings *settings = nullptr;
    std::function<int()> blinkAlpha;
    bool switching() const { return isVisible() && m_switcher; }

    static bool fuzzyMatch(const QString &needle, const QString &haystack); // case-insensitive subsequence

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;
    void hideEvent(QHideEvent *event) override;

private:
    void filter();
    void runCurrent();
    void place();
    void updateBlinkTimer();

    QLineEdit *m_search;
    QListWidget *m_list;
    QList<Item> m_items;
    QList<Section> m_sections;
    QString m_searchHeader;
    QList<Item> m_searchItems;
    bool m_sectioned = false;
    bool m_switcher = false;
    bool m_hasBlink = false;
    QTimer m_blinkTimer;
    std::function<void()> m_cancel;
    int m_initial = -1;
    QPointer<QWidget> m_anchor;
    void dismiss();
};
