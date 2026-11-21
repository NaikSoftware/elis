#include "palette.h"

#include "sidebar.h"
#include "store.h"

#include <QApplication>
#include <QHideEvent>
#include <QKeyEvent>
#include <QLineEdit>
#include <QListWidget>
#include <QPainter>
#include <QStyledItemDelegate>
#include <QVBoxLayout>

using namespace PaletteRole;

namespace {
class RowDelegate : public QStyledItemDelegate
{
public:
    RowDelegate(const Palette *palette, QObject *parent)
        : QStyledItemDelegate(parent), m_palette(palette)
    {
    }
    void paint(QPainter *p, const QStyleOptionViewItem &opt, const QModelIndex &index) const override
    {
        const QPalette pal = QApplication::palette();
        p->save();
        p->setRenderHint(QPainter::Antialiasing);
        QColor text = pal.color(QPalette::WindowText);
        if (index.data(Header).toBool()) {
            QFont hf = opt.font;
            hf.setPointSizeF(qMax(8.0, opt.font.pointSizeF() * 11.5 / 13.0));
            hf.setWeight(QFont::DemiBold);
            QColor hc = text;
            hc.setAlphaF(hc.alphaF() * 0.58);
            p->setPen(hc);
            p->setFont(hf);
            const QRectF hr(opt.rect.left() + 16, opt.rect.top() + 8, opt.rect.width() - 32, opt.rect.height() - 12);
            p->drawText(hr, Qt::AlignVCenter | Qt::AlignLeft, QFontMetricsF(hf).elidedText(index.data().toString(), Qt::ElideRight, hr.width()));
            p->restore();
            return;
        }
        const QRectF r = QRectF(opt.rect).adjusted(6, 1, -6, -1);
        if (opt.state & QStyle::State_Selected) {
            QColor sel = pal.color(QPalette::Highlight);
            sel.setAlpha(110);
            p->setPen(Qt::NoPen);
            p->setBrush(sel);
            p->drawRoundedRect(r, 6, 6);
        }
        if (!(index.flags() & Qt::ItemIsEnabled))
            text.setAlpha(110);
        const QString status = index.data(Status).toString();
        const bool blink = index.data(Blink).toBool();
        const int alpha = m_palette->blinkAlpha ? m_palette->blinkAlpha() : 255;
        QFont small = opt.font;
        small.setPointSizeF(small.pointSizeF() * 0.85);
        if (index.data(SingleLine).toBool()) {
            const qreal cy = r.center().y();
            qreal x = r.left() + 10;
            qreal right = r.right() - 10;
            if (const QString icon = index.data(Icon).toString(); !icon.isEmpty()) {
                QColor ic = text;
                ic.setAlphaF(text.alphaF() * 0.58);
                drawLauncher(p, QRectF(x + 2, cy - 7, 14, 14), icon, ic);
                x += 28;
            }
            if (!status.isEmpty() && m_palette->settings) {
                paintStatus(p, *m_palette->settings, status, blink, alpha, QPointF(right - 5, cy));
                right -= 20;
            }
            const QFontMetricsF fm(opt.font), sfm(small);
            if (const QString ws = index.data(PaletteRole::Workspace).toString(); !ws.isEmpty() && right > x) {
                const qreal wsMax = qMax<qreal>(40, (right - x) * 0.4);
                const QString shownWs = sfm.elidedText(ws, Qt::ElideRight, wsMax);
                const qreal wsW = sfm.horizontalAdvance(shownWs);
                QColor wc = text;
                wc.setAlphaF(text.alphaF() * 0.36);
                p->setPen(wc);
                p->setFont(small);
                p->drawText(QRectF(right - wsW, r.top(), wsW, r.height()), Qt::AlignVCenter | Qt::AlignRight, shownWs);
                right -= wsW + 10;
            }
            const qreal avail = qMax<qreal>(0, right - x);
            const QString title = index.data().toString();
            const QString shownTitle = fm.elidedText(title, Qt::ElideRight, avail);
            const qreal titleW = fm.horizontalAdvance(shownTitle);
            p->setPen(text);
            p->setFont(opt.font);
            p->drawText(QRectF(x, r.top(), avail, r.height()), Qt::AlignVCenter | Qt::AlignLeft, shownTitle);
            const QString detail = index.data(Subtitle).toString();
            const qreal detailRoom = avail - titleW - 10;
            if (!detail.isEmpty() && detailRoom > sfm.averageCharWidth() * 2) {
                QColor dim = text;
                dim.setAlphaF(text.alphaF() * 0.58);
                p->setPen(dim);
                p->setFont(small);
                p->drawText(QRectF(x + titleW + 10, r.top(), detailRoom, r.height()), Qt::AlignVCenter | Qt::AlignLeft,
                            sfm.elidedText(detail, Qt::ElideMiddle, detailRoom));
            }
            p->restore();
            return;
        }
        QColor dim = text;
        dim.setAlpha(text.alpha() * 150 / 255);
        qreal textWidth = r.width() - 24;
        if (!status.isEmpty() && m_palette->settings) {
            paintStatus(p, *m_palette->settings, status, blink, alpha, QPointF(r.right() - 12, r.center().y()));
            textWidth -= 22;
        }
        const QFontMetrics fm(opt.font), sfm(small);
        const QString sub = index.data(Subtitle).toString();
        const qreal top = r.center().y() - (fm.height() + (sub.isEmpty() ? 0 : sfm.height())) / 2.0;
        p->setPen(text);
        p->setFont(opt.font);
        p->drawText(QRectF(r.left() + 12, top, textWidth, fm.height()), Qt::AlignVCenter,
                    fm.elidedText(index.data().toString(), Qt::ElideRight, int(textWidth)));
        if (!sub.isEmpty()) {
            p->setPen(dim);
            p->setFont(small);
            p->drawText(QRectF(r.left() + 12, top + fm.height(), textWidth, sfm.height()), Qt::AlignVCenter,
                        sfm.elidedText(sub, Qt::ElideMiddle, int(textWidth)));
        }
        p->restore();
    }
    QSize sizeHint(const QStyleOptionViewItem &opt, const QModelIndex &index) const override
    {
        if (index.data(Header).toBool()) {
            QFont hf = opt.font;
            hf.setPointSizeF(qMax(8.0, opt.font.pointSizeF() * 11.5 / 13.0));
            hf.setWeight(QFont::DemiBold);
            return QSize(200, QFontMetrics(hf).height() + 12);
        }
        if (index.data(SingleLine).toBool())
            return QSize(200, qMax(30, opt.fontMetrics.height() + 12));
        const int sub = index.data(Subtitle).toString().isEmpty() ? 0 : opt.fontMetrics.height();
        return QSize(200, opt.fontMetrics.height() + sub + 14);
    }

private:
    const Palette *m_palette;
};
} // namespace

Palette::Palette(QWidget *window)
    : QFrame(window)
{
    setObjectName(QStringLiteral("palette"));
    const QPalette pal = QApplication::palette();
    QColor border = pal.color(QPalette::WindowText);
    border.setAlpha(40);
    setStyleSheet(QStringLiteral("#palette{background:%1;border:1px solid %2;border-radius:10px;}"
                                 "QLineEdit{border:none;background:transparent;padding:10px 12px;font-size:%3pt;}"
                                 "QListWidget{border:none;background:transparent;}")
                      .arg(pal.color(QPalette::Window).name(), border.name(QColor::HexArgb))
                      .arg(font().pointSizeF() * 1.1));
    m_search = new QLineEdit;
    m_search->addAction(QIcon::fromTheme(QStringLiteral("search")), QLineEdit::LeadingPosition);
    m_list = new QListWidget;
    m_list->setItemDelegate(new RowDelegate(this, m_list));
    m_list->setFocusPolicy(Qt::NoFocus);
    m_list->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
    auto *col = new QVBoxLayout(this);
    col->setContentsMargins(4, 4, 4, 6);
    col->setSpacing(2);
    col->addWidget(m_search);
    col->addWidget(m_list);
    connect(m_search, &QLineEdit::textChanged, this, &Palette::filter);
    connect(m_list, &QListWidget::itemClicked, this, [this](QListWidgetItem *item) {
        if (!item || item->data(Header).toBool() || !(item->flags() & Qt::ItemIsEnabled))
            return;
        m_list->setCurrentItem(item);
        runCurrent();
    });
    connect(m_list, &QListWidget::currentItemChanged, this, [this](QListWidgetItem *row) {
        if (row && isVisible() && !row->data(Header).toBool()) {
            const int idx = row->data(Index).toInt();
            if (idx >= 0 && idx < m_items.size())
                if (const auto &preview = m_items[idx].preview)
                    preview();
        }
    });
    m_blinkTimer.setInterval(33);
    connect(&m_blinkTimer, &QTimer::timeout, this, [this] { m_list->viewport()->update(); });
    m_search->installEventFilter(this);
    qApp->installEventFilter(this); // Ctrl release ends the switcher; a click elsewhere dismisses
    hide();
}

bool Palette::fuzzyMatch(const QString &needle, const QString &haystack)
{
    int at = 0;
    for (const QChar c : needle) {
        if (c.isSpace())
            continue;
        at = haystack.indexOf(c, at, Qt::CaseInsensitive);
        if (at < 0)
            return false;
        ++at;
    }
    return true;
}

void Palette::open(const QString &placeholder, const QList<Item> &items, bool switcher, std::function<void()> cancel, int current)
{
    m_sectioned = false;
    m_sections.clear();
    m_searchHeader.clear();
    m_searchItems.clear();
    m_items = items;
    m_switcher = switcher;
    m_cancel = std::move(cancel);
    custom = {};
    m_anchor = std::exchange(anchor, nullptr);
    m_initial = current;
    m_search->setPlaceholderText(placeholder);
    m_search->setVisible(!switcher);
    m_search->clear();
    filter();
    m_initial = -1;
    place();
    show();
    updateBlinkTimer();
    raise();
    m_search->setFocus();
}

void Palette::open(const QString &placeholder, const QList<Section> &sections, const QString &searchHeader, const QList<Item> &searchItems)
{
    m_sectioned = true;
    m_sections = sections;
    m_searchHeader = searchHeader;
    m_searchItems = searchItems;
    m_items.clear();
    m_switcher = false;
    m_cancel = {};
    custom = {};
    m_anchor = std::exchange(anchor, nullptr);
    m_initial = -1;
    m_search->setPlaceholderText(placeholder);
    m_search->setVisible(true);
    m_search->clear();
    filter();
    place();
    show();
    updateBlinkTimer();
    raise();
    m_search->setFocus();
}

void Palette::place()
{
    QWidget *w = parentWidget();
    const int width = qBound(420, w->width() * 2 / 5, 760);
    int rows = 0;
    for (int i = 0; i < m_list->count(); ++i) {
        const int h = m_list->sizeHintForRow(i);
        if (m_sectioned ? (rows + h > 440 && rows > 0) : (i >= 9))
            break;
        rows += h;
    }
    const QMargins m = layout()->contentsMargins();
    const int chrome = m.top() + m.bottom() + 2 * frameWidth() + (rows ? layout()->spacing() + 2 * m_list->frameWidth() : 0);
    const int height = (m_switcher ? 0 : m_search->sizeHint().height()) + rows + chrome;
    if (m_anchor && m_anchor->isVisible()) {
        const QRect at(m_anchor->mapTo(w, QPoint()), m_anchor->size());
        const int x = qBound(8, at.center().x() - width / 2, w->width() - width - 8);
        setGeometry(x, at.bottom() + 7, width, qMin(height, w->height() - at.bottom() - 15));
        return;
    }
    setGeometry((w->width() - width) / 2, w->height() / 6, width, qMin(height, w->height() * 2 / 3));
}

void Palette::filter()
{
    m_list->clear();
    m_hasBlink = false;
    const QString needle = m_search->text();
    auto addHeader = [this](const QString &title) {
        auto *row = new QListWidgetItem(title, m_list);
        row->setData(Header, true);
        row->setData(Index, -1);
        row->setFlags(Qt::NoItemFlags);
    };
    auto addRow = [this](const Item &it, int idx) {
        auto *row = new QListWidgetItem(it.title, m_list);
        row->setData(Subtitle, it.subtitle);
        row->setData(Index, idx);
        row->setData(Header, false);
        row->setData(Status, it.status);
        row->setData(Blink, it.blink);
        row->setData(Icon, it.icon);
        row->setData(PaletteRole::Workspace, it.workspace);
        row->setData(SingleLine, it.singleLine);
        if (!it.enabled)
            row->setFlags(row->flags() & ~Qt::ItemIsEnabled);
        m_hasBlink |= it.blink;
    };
    if (m_sectioned) {
        m_items.clear();
        if (needle.trimmed().isEmpty()) {
            for (const Section &sec : std::as_const(m_sections)) {
                if (sec.items.isEmpty())
                    continue;
                addHeader(sec.title);
                for (const Item &it : sec.items) {
                    const int idx = int(m_items.size());
                    m_items.append(it);
                    addRow(it, idx);
                }
            }
        } else {
            QList<Item> hits;
            for (const Item &it : std::as_const(m_searchItems)) {
                const QString searchSub = it.workspace.isEmpty() ? it.subtitle : it.workspace + QStringLiteral(" · ") + it.subtitle;
                if (fuzzyMatch(needle, it.title + QLatin1Char(' ') + searchSub))
                    hits.append(it);
            }
            if (!hits.isEmpty()) {
                addHeader(m_searchHeader);
                for (const Item &it : std::as_const(hits)) {
                    const int idx = int(m_items.size());
                    m_items.append(it);
                    addRow(it, idx);
                }
            }
        }
    } else {
        for (int i = 0; i < m_items.size(); ++i) {
            const Item &it = m_items[i];
            if (!fuzzyMatch(needle, it.title + QLatin1Char(' ') + it.subtitle))
                continue;
            addRow(it, i);
        }
    }
    int row = -1;
    for (int i = 0; i < m_list->count(); ++i)
        if (!m_list->item(i)->data(Header).toBool()) {
            row = i;
            break;
        }
    if (m_switcher && m_list->count() > 1)
        row = 1; // a single Ctrl-Tab tap flips back
    for (int i = 0; m_initial >= 0 && i < m_list->count(); ++i)
        if (!m_list->item(i)->data(Header).toBool() && m_list->item(i)->data(Index).toInt() == m_initial)
            row = i;
    m_list->setCurrentRow(row);
    m_list->setVisible(m_list->count() > 0); // an empty list keeps a minimum height that squeezed the search field
    updateBlinkTimer();
    if (isVisible())
        place();
}

void Palette::step(int delta)
{
    const int n = m_list->count();
    if (!n)
        return;
    int cur = m_list->currentRow();
    if (cur < 0)
        cur = delta > 0 ? -1 : 0;
    for (int k = 0; k < n; ++k) {
        cur = (cur + delta + n) % n;
        if (!m_list->item(cur)->data(Header).toBool()) {
            m_list->setCurrentRow(cur);
            return;
        }
    }
}

void Palette::runCurrent()
{
    QListWidgetItem *row = m_list->currentItem();
    if (row && row->data(Header).toBool())
        return;
    if ((!row || !(row->flags() & Qt::ItemIsEnabled)) && custom) {
        m_cancel = {};
        hide();
        return std::exchange(custom, {})(m_search->text());
    }
    m_cancel = {};
    hide();
    if (row && (row->flags() & Qt::ItemIsEnabled)) {
        const int idx = row->data(Index).toInt();
        if (idx >= 0 && idx < m_items.size())
            if (auto run = m_items[idx].run)
                run();
    }
}

void Palette::updateBlinkTimer()
{
    if (m_hasBlink && isVisible()) {
        if (!m_blinkTimer.isActive())
            m_blinkTimer.start();
    } else {
        m_blinkTimer.stop();
    }
}

void Palette::hideEvent(QHideEvent *event)
{
    m_blinkTimer.stop();
    QFrame::hideEvent(event);
}

bool Palette::eventFilter(QObject *watched, QEvent *event)
{
    if (!isVisible())
        return false;
    if (event->type() == QEvent::KeyRelease && m_switcher && static_cast<QKeyEvent *>(event)->key() == Qt::Key_Control) {
        runCurrent();
        return true;
    }
    // widgets only: the press reaches the window's QWindow first, which is no widget and read as a click elsewhere
    auto *widget = qobject_cast<QWidget *>(watched);
    if (event->type() == QEvent::MouseButtonPress && widget && widget != this && !isAncestorOf(widget)) {
        dismiss();
        return false;
    }
    if (event->type() != QEvent::KeyPress || (watched != m_search && !m_switcher))
        return false;
    auto *key = static_cast<QKeyEvent *>(event);
    const bool ctrl = key->modifiers() & Qt::ControlModifier;
    switch (key->key()) {
    case Qt::Key_Escape:
        dismiss();
        return true;
    case Qt::Key_Return:
    case Qt::Key_Enter:
        runCurrent();
        return true;
    case Qt::Key_Down:
        step(1);
        return true;
    case Qt::Key_Up:
        step(-1);
        return true;
    case Qt::Key_Tab:
        if (m_switcher)
            step(1);
        return m_switcher;
    case Qt::Key_Backtab:
        if (m_switcher)
            step(-1);
        return m_switcher;
    case Qt::Key_J:
    case Qt::Key_K:
        if (!ctrl)
            return false;
        step(key->key() == Qt::Key_J ? 1 : -1);
        return true;
    default:
        return m_switcher; // the switcher swallows keys while Ctrl is held
    }
}

void Palette::dismiss()
{
    hide();
    if (auto cancel = std::exchange(m_cancel, {}))
        cancel();
}

void Palette::setQuery(const QString &query)
{
    m_search->setText(query);
    filter();
}

QString Palette::query() const
{
    return m_search->text();
}
