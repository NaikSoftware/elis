#include "assistantview.h"

#include "assistant.h"
#include "detectedlaunchers.h"
#include "launcher.h"
#include "mainwindow.h"
#include "palette.h"
#include "sidebar.h"
#include "store.h"

#include <QAbstractItemView>
#include <QAbstractTextDocumentLayout>
#include <QApplication>
#include <QCompleter>
#include <QDragEnterEvent>
#include <QFontDatabase>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QKeyEvent>
#include <QLabel>
#include <QMouseEvent>
#include <QMimeData>
#include <QPaintEvent>
#include <QPainter>
#include <QPlainTextEdit>
#include <QRegularExpression>
#include <QScrollArea>
#include <QScreen>
#include <QScrollBar>
#include <QStandardItemModel>
#include <QStatusBar>
#include <QSyntaxHighlighter>
#include <QTextBlock>
#include <QTimer>
#include <QToolButton>
#include <QVBoxLayout>

#include <array>
#include <functional>

namespace {
QList<AssistantView *> s_views;
bool s_refreshQueued = false;

QColor ink(qreal alpha = 1)
{
    QColor c = QApplication::palette().color(QPalette::WindowText);
    c.setAlphaF(alpha);
    return c;
}

QColor accent(qreal alpha = 1)
{
    QColor c = QApplication::palette().color(QPalette::Highlight);
    c.setAlphaF(alpha);
    return c;
}

QString css(const QColor &c)
{
    return QStringLiteral("rgba(%1,%2,%3,%4)").arg(c.red()).arg(c.green()).arg(c.blue()).arg(c.alphaF(), 0, 'f', 3);
}

QFont mono(const QFont &base)
{
    QFont f = QFontDatabase::systemFont(QFontDatabase::FixedFont);
    f.setPointSizeF(qMax(7.0, base.pointSizeF() - 1));
    return f;
}

QLabel *text(const QString &s, const QColor &color, Qt::TextFormat format = Qt::PlainText)
{
    auto *l = new QLabel(s);
    l->setTextFormat(format);
    l->setWordWrap(true);
    l->setTextInteractionFlags(Qt::TextSelectableByMouse | Qt::LinksAccessibleByMouse);
    l->setFocusPolicy(Qt::NoFocus); // a click to select text leaves the keys with the composer
    l->setOpenExternalLinks(true);
    l->setStyleSheet(QStringLiteral("color:%1;").arg(css(color)));
    return l;
}

QLabel *caption(const QString &s)
{
    auto *l = new QLabel(s.toUpper());
    QFont f = l->font();
    f.setPointSizeF(qMax(7.0, f.pointSizeF() - 1.5));
    f.setWeight(QFont::DemiBold);
    f.setLetterSpacing(QFont::PercentageSpacing, 106);
    l->setFont(f);
    l->setStyleSheet(QStringLiteral("color:%1;").arg(css(ink(0.55))));
    return l;
}

// a session name cut with an ellipsis to the room its row leaves
class Elided : public QLabel
{
public:
    Elided(const QString &s, const QColor &color) : QLabel(s), m_color(color) { }
    QSize minimumSizeHint() const override { return {0, QLabel::minimumSizeHint().height()}; }

protected:
    void paintEvent(QPaintEvent *) override
    {
        QPainter p(this);
        p.setPen(m_color);
        p.drawText(contentsRect(), Qt::AlignLeft | Qt::AlignVCenter, fontMetrics().elidedText(text(), Qt::ElideRight, contentsRect().width()));
    }

private:
    QColor m_color;
};

// a tag is a word that starts with @; only one naming a session, a workspace or @all is marked
const QRegularExpression &tagPattern()
{
    static const QRegularExpression pattern(QStringLiteral("(?<!\\S)@[\\w:-]+"));
    return pattern;
}

class TagHighlighter : public QSyntaxHighlighter
{
public:
    std::function<QColor(const QString &)> tint; // invalid for a word that names nothing
    using QSyntaxHighlighter::QSyntaxHighlighter;

protected:
    void highlightBlock(const QString &line) override
    {
        for (auto it = tagPattern().globalMatch(line); it.hasNext();) {
            const QRegularExpressionMatch m = it.next();
            if (const QColor c = tint(m.captured()); c.isValid()) {
                QTextCharFormat f;
                f.setBackground(c);
                setFormat(int(m.capturedStart()), int(m.capturedLength()), f);
            }
        }
    }
};

// The message box's keys live here, not in an event filter: QCompleter passes its popup's keys to the widget's event()
// directly, and takes Return, Tab and Escape itself only when the widget leaves them unaccepted.
class ComposerEdit : public QPlainTextEdit
{
public:
    std::function<void()> send;
    QCompleter *completer = nullptr;

protected:
    void keyPressEvent(QKeyEvent *key) override
    {
        const bool enter = key->key() == Qt::Key_Return || key->key() == Qt::Key_Enter;
        if (completer && completer->popup()->isVisible()
            && (enter || key->key() == Qt::Key_Escape || key->key() == Qt::Key_Tab || key->key() == Qt::Key_Backtab))
            return key->ignore();
        if (enter && key->modifiers() & Qt::ShiftModifier)
            return insertPlainText(QStringLiteral("\n"));
        if (enter && !(key->modifiers() & ~Qt::KeypadModifier))
            return send();
        QPlainTextEdit::keyPressEvent(key);
    }
};

QPixmap sendGlyph(const QColor &color)
{
    QPixmap pm(36, 36);
    pm.fill(Qt::transparent);
    QPainter p(&pm);
    p.setRenderHint(QPainter::Antialiasing);
    p.scale(2, 2);
    p.setPen(QPen(color, 2.2, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
    p.drawLine(QPointF(3.5, 9), QPointF(14.5, 9));
    p.drawPolyline(QList<QPointF>{{9.5, 4}, {14.5, 9}, {9.5, 14}});
    p.end();
    pm.setDevicePixelRatio(2);
    return pm;
}

constexpr int columnWidth = 760;

QWidget *centred(QWidget *column)
{
    auto *outer = new QWidget;
    auto *row = new QHBoxLayout(outer);
    row->setContentsMargins(32, 0, 32, 0);
    column->setMaximumWidth(columnWidth);
    row->addStretch(0); // the stretches take what the column's cap leaves, one half each
    row->addWidget(column, 1);
    row->addStretch(0);
    return outer;
}

// The provider picker: a rounded panel with its own soft shadow, a small header and padded rows,
// the current provider tinted with the accent. A QMenu cannot: Breeze fixes its indent, radius and section rule.
class ProviderPopup : public QWidget
{
public:
    static constexpr int Shadow = 14, Inset = 6, Radius = 10;

    ProviderPopup(QWidget *anchor, QList<QPair<QString, QString>> rows, const QString &current, std::function<void(const QString &)> pick)
        : QWidget(anchor, Qt::Popup | Qt::FramelessWindowHint | Qt::NoDropShadowWindowHint)
        , m_rows(std::move(rows))
        , m_pick(std::move(pick))
    {
        setObjectName(QStringLiteral("assistantProviderPopup"));
        setAttribute(Qt::WA_TranslucentBackground);
        setAttribute(Qt::WA_DeleteOnClose);
        setMouseTracking(true);
        for (int r = 0; r < m_rows.size(); ++r)
            if (m_rows[r].first == current)
                m_current = m_hover = r;
        m_header = font();
        m_header.setPointSizeF(m_header.pointSizeF() * 0.78);
        m_header.setWeight(QFont::DemiBold);
        m_header.setCapitalization(QFont::AllUppercase);
        m_header.setLetterSpacing(QFont::AbsoluteSpacing, 0.8);
        const QFontMetrics fm(font()), hm(m_header);
        int wide = hm.horizontalAdvance(title());
        for (const auto &r : std::as_const(m_rows))
            wide = qMax(wide, fm.horizontalAdvance(r.second));
        m_rowHeight = fm.height() + 12;
        m_headerHeight = hm.height() + 18;
        setFixedSize(2 * Shadow + qMax(200, wide + 2 * (Inset + 12)), 2 * Shadow + m_headerHeight + int(m_rows.size()) * m_rowHeight + Inset);
    }
    static QString title() { return AssistantView::tr("Found on this system"); }

protected:
    QRect panel() const { return rect().adjusted(Shadow, Shadow, -Shadow, -Shadow); }
    QRect row(int r) const
    {
        const QRect p = panel();
        return {p.left() + Inset, p.top() + m_headerHeight + r * m_rowHeight, p.width() - 2 * Inset, m_rowHeight};
    }
    int rowAt(const QPoint &pos) const
    {
        for (int r = 0; r < m_rows.size(); ++r)
            if (row(r).contains(pos))
                return r;
        return -1;
    }
    void paintEvent(QPaintEvent *) override
    {
        QPainter p(this);
        p.setRenderHint(QPainter::Antialiasing);
        p.setPen(Qt::NoPen);
        const bool dark = palette().color(QPalette::Window).lightness() < 128;
        for (int i = Shadow; i > 0; --i) { // a soft drop shadow, densest at the panel's edge and a little below it
            const qreal t = 1 - qreal(i) / Shadow;
            p.setBrush(QColor(0, 0, 0, int((dark ? 40 : 18) * t * t)));
            p.drawRoundedRect(QRectF(panel()).adjusted(-i, -i + 4, i, i + 4), Radius + i, Radius + i);
        }
        p.setBrush(palette().color(QPalette::Window));
        p.setPen(QPen(ink(dark ? 0.14 : 0.12), 1));
        p.drawRoundedRect(QRectF(panel()).adjusted(0.5, 0.5, -0.5, -0.5), Radius, Radius);
        p.setPen(ink(0.5));
        p.setFont(m_header);
        const QRect head(panel().left() + Inset + 12, panel().top() + 4, panel().width(), m_headerHeight - 4);
        p.drawText(head, Qt::AlignLeft | Qt::AlignVCenter, title());
        p.setFont(font());
        for (int r = 0; r < m_rows.size(); ++r) {
            const QRect at = row(r);
            const QColor fill = r == m_current ? accent(0.16) : r == m_hover ? ink(0.07) : QColor(Qt::transparent);
            p.setPen(Qt::NoPen);
            p.setBrush(fill);
            p.drawRoundedRect(QRectF(at), 6, 6);
            p.setPen(ink());
            p.drawText(at.adjusted(12, 0, -12, 0), Qt::AlignLeft | Qt::AlignVCenter, m_rows[r].second);
        }
    }
    void mouseMoveEvent(QMouseEvent *e) override
    {
        if (const int r = rowAt(e->position().toPoint()); r != m_hover) {
            m_hover = r;
            update();
        }
    }
    void leaveEvent(QEvent *) override
    {
        m_hover = -1;
        update();
    }
    void mousePressEvent(QMouseEvent *e) override
    {
        if (rect().contains(e->position().toPoint()))
            return;
        // a press outside closes the panel and is replayed to what it hit, except on the picker that opened it, as QMenu
        // does: replayed there it would open the panel again
        if (const QWidget *picker = parentWidget(); picker && picker->rect().contains(picker->mapFromGlobal(e->globalPosition().toPoint())))
            setAttribute(Qt::WA_NoMouseReplay);
        close();
    }
    void mouseReleaseEvent(QMouseEvent *e) override
    {
        if (const int r = rowAt(e->position().toPoint()); r >= 0)
            choose(r);
    }
    void keyPressEvent(QKeyEvent *e) override
    {
        const int n = int(m_rows.size());
        switch (e->key()) {
        case Qt::Key_Up:
            m_hover = m_hover <= 0 ? n - 1 : m_hover - 1;
            return update();
        case Qt::Key_Down:
            m_hover = (m_hover + 1) % qMax(1, n);
            return update();
        case Qt::Key_Return:
        case Qt::Key_Enter:
            if (m_hover >= 0)
                choose(m_hover);
            return;
        case Qt::Key_Escape:
            close();
            return;
        default:
            QWidget::keyPressEvent(e);
        }
    }

private:
    void choose(int r)
    {
        const QString id = m_rows[r].first;
        auto pick = m_pick;
        close();
        pick(id);
    }

    QList<QPair<QString, QString>> m_rows; // provider id, title
    std::function<void(const QString &)> m_pick;
    QFont m_header;
    int m_current = -1, m_hover = -1, m_rowHeight = 0, m_headerHeight = 0;
};
}

AssistantView::AssistantView(MainWindow &window, Store &store)
    : m_window(window), m_store(store)
{
    s_views << this;
    // shortcut: the page's colours are taken from the palette once, so a desktop theme switch shows after a relaunch;
    // restyle on QEvent::PaletteChange if that matters
    auto *page = new QHBoxLayout(this);
    page->setContentsMargins(0, 0, 0, 0);
    page->setSpacing(0);
    auto *main = new QVBoxLayout;
    main->setSpacing(0);
    page->addLayout(main, 1);

    // the transcript: an empty state, the entries, and a working line while a turn runs
    auto *content = new QWidget;
    auto *stack = new QVBoxLayout(content);
    stack->setContentsMargins(0, 28, 0, 20);
    stack->setSpacing(18);
    m_empty = new QWidget;
    {
        auto *box = new QVBoxLayout(m_empty);
        box->setContentsMargins(0, 80, 0, 0);
        box->setSpacing(8);
        auto *dog = new QLabel;
        QPixmap pm = QPixmap(QStringLiteral(":/elis.png")).scaled(128, 128, Qt::KeepAspectRatio, Qt::SmoothTransformation);
        pm.setDevicePixelRatio(2);
        dog->setPixmap(pm);
        box->addWidget(dog, 0, Qt::AlignHCenter);
        auto *title = new QLabel(QStringLiteral("Elis"));
        QFont tf = title->font();
        tf.setPointSizeF(tf.pointSizeF() * 1.4);
        tf.setWeight(QFont::DemiBold);
        title->setFont(tf);
        box->addWidget(title, 0, Qt::AlignHCenter);
        QLabel *hint = text(tr("Ask about your sessions. Tag one with @, or drag a sidebar row onto the message box."), ink(0.6));
        hint->setAlignment(Qt::AlignHCenter);
        box->addWidget(hint);
    }
    stack->addWidget(m_empty);
    auto *entries = new QWidget;
    m_column = new QVBoxLayout(entries);
    m_column->setContentsMargins(0, 0, 0, 0);
    m_column->setSpacing(18);
    stack->addWidget(entries);
    m_working = text(tr("Elis is working…"), ink(0.55));
    m_working->setObjectName(QStringLiteral("assistantWorking"));
    QFont italic = m_working->font();
    italic.setItalic(true);
    m_working->setFont(italic);
    stack->addWidget(m_working);
    stack->addStretch(1);
    m_scroll = new QScrollArea;
    m_scroll->setWidgetResizable(true);
    m_scroll->setFrameShape(QFrame::NoFrame);
    m_scroll->setFocusPolicy(Qt::NoFocus);
    m_scroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    m_scroll->setWidget(centred(content));
    m_scroll->viewport()->setAutoFillBackground(false);
    m_scroll->widget()->setAutoFillBackground(false);
    // the column follows its end while it is scrolled there
    auto follow = std::make_shared<bool>(true);
    connect(m_scroll->verticalScrollBar(), &QScrollBar::valueChanged, this, [this, follow](int v) { *follow = v >= m_scroll->verticalScrollBar()->maximum() - 4; });
    connect(m_scroll->verticalScrollBar(), &QScrollBar::rangeChanged, this, [this, follow](int, int max) {
        if (*follow)
            m_scroll->verticalScrollBar()->setValue(max);
    });
    main->addWidget(m_scroll, 1);

    // the composer: the message with its tags in place, then the provider picker and send
    auto *composer = new QFrame;
    composer->setObjectName(QStringLiteral("composer"));
    composer->setStyleSheet(QStringLiteral("QFrame#composer{border:1px solid %1;border-radius:14px;background:%2;}")
                                .arg(css(ink(0.22)), css(QApplication::palette().color(QPalette::Window))));
    composer->setAcceptDrops(true);
    composer->installEventFilter(this);
    auto *box = new QVBoxLayout(composer);
    box->setContentsMargins(14, 10, 14, 10);
    box->setSpacing(8);
    auto *editor = new ComposerEdit;
    editor->send = [this] { send(); };
    m_editor = editor;
    auto *highlighter = new TagHighlighter(m_editor->document());
    highlighter->tint = [this](const QString &tag) { return tagTint(tag, QApplication::palette().color(QPalette::Window)); }; // the composer's fill
    m_highlighter = highlighter;
    m_editor->setObjectName(QStringLiteral("assistantComposer"));
    m_editor->setPlaceholderText(tr("Message Elis…  @ to tag, or drag a row from the sidebar"));
    m_editor->setFrameShape(QFrame::NoFrame);
    m_editor->setStyleSheet(QStringLiteral("QPlainTextEdit{background:transparent;}"));
    m_editor->setTabChangesFocus(true);
    m_editor->document()->setDocumentMargin(1);
    m_editor->viewport()->installEventFilter(this); // drops land on the viewport
    auto fit = [this] {
        const int lines = qBound(1, int(m_editor->document()->documentLayout()->documentSize().height()), 8);
        m_editor->setFixedHeight(lines * m_editor->fontMetrics().lineSpacing() + 6);
        m_editor->setVerticalScrollBarPolicy(lines == 8 ? Qt::ScrollBarAsNeeded : Qt::ScrollBarAlwaysOff);
    };
    connect(m_editor->document(), &QTextDocument::contentsChanged, this, fit);
    fit();
    box->addWidget(m_editor);
    auto *bottom = new QHBoxLayout;
    bottom->setSpacing(8);
    m_provider = new QToolButton;
    m_provider->setObjectName(QStringLiteral("assistantProvider"));
    connect(m_provider, &QToolButton::clicked, this, &AssistantView::openProviders);
    m_provider->setFocusPolicy(Qt::NoFocus);
    m_provider->setStyleSheet(QStringLiteral("QToolButton{border:1px solid %1;border-radius:7px;padding:3px 10px;background:%2;}")
                                  .arg(css(accent()), css(accent(0.10))));
    bottom->addWidget(m_provider);
    auto *note = new QLabel(tr("applies from the next message"));
    QFont small = note->font();
    small.setPointSizeF(qMax(7.0, small.pointSizeF() - 1.5));
    note->setFont(small);
    note->setStyleSheet(QStringLiteral("color:%1;").arg(css(ink(0.55))));
    bottom->addWidget(note);
    bottom->addStretch(1);
    m_send = new QToolButton;
    m_send->setObjectName(QStringLiteral("assistantSend"));
    m_send->setToolTip(tr("Send"));
    m_send->setAccessibleName(tr("Send"));
    m_send->setIcon(QIcon(sendGlyph(Qt::white)));
    m_send->setIconSize(QSize(18, 18));
    m_send->setFixedSize(34, 34);
    m_send->setFocusPolicy(Qt::NoFocus);
    m_send->setStyleSheet(QStringLiteral("QToolButton{background:%1;border:0;border-radius:9px;}QToolButton:disabled{background:%2;}")
                              .arg(css(accent()), css(accent(0.35))));
    connect(m_send, &QToolButton::clicked, this, &AssistantView::send);
    bottom->addWidget(m_send);
    box->addLayout(bottom);
    auto *composerColumn = new QWidget;
    auto *under = new QVBoxLayout(composerColumn);
    under->setContentsMargins(0, 14, 0, 16);
    under->addWidget(composer);
    main->addWidget(centred(composerColumn));
    connect(m_editor, &QPlainTextEdit::textChanged, this, &AssistantView::syncSend);
    syncSend();

    m_candidates = new QStandardItemModel(this);
    m_completer = new QCompleter(m_candidates, this);
    m_completer->setWidget(m_editor);
    m_completer->setCompletionMode(QCompleter::PopupCompletion);
    m_completer->setCaseSensitivity(Qt::CaseInsensitive);
    m_completer->setCompletionRole(Qt::UserRole);
    m_completer->popup()->setObjectName(QStringLiteral("assistantCompletion"));
    m_completer->popup()->setItemDelegate(Palette::rowDelegate(m_completer->popup())); // the session switcher's rows
    // the provider panel's surface (painted in eventFilter), so the rows do not float on the chat; a thin scrollbar with no groove rule
    QAbstractItemView *list = m_completer->popup();
    list->setAttribute(Qt::WA_TranslucentBackground);
    list->setFrameShape(QFrame::NoFrame);
    list->viewport()->setAutoFillBackground(false);
    list->installEventFilter(this);
    list->setStyleSheet(QStringLiteral("QListView{background:transparent;border:0;padding-top:5px;}"
                                       "QScrollBar:vertical{background:transparent;width:10px;margin:8px 3px 8px 0;}"
                                       "QScrollBar::handle:vertical{background:%1;border-radius:3px;min-height:24px;}"
                                       "QScrollBar::add-line:vertical,QScrollBar::sub-line:vertical{height:0;}"
                                       "QScrollBar::add-page:vertical,QScrollBar::sub-page:vertical{background:transparent;}")
                            .arg(css(ink(0.22))));
    m_completer->setMaxVisibleItems(8);
    editor->completer = m_completer;
    connect(m_completer, qOverload<const QModelIndex &>(&QCompleter::activated), this, [this](const QModelIndex &index) {
        QTextCursor c = m_editor->textCursor();
        c.movePosition(QTextCursor::Left, QTextCursor::KeepAnchor, int(m_completer->completionPrefix().size()));
        c.removeSelectedText();
        insertTags({index.data(Qt::UserRole).toString()}, c);
    });
    connect(m_editor, &QPlainTextEdit::textChanged, this, &AssistantView::complete);

    setFocusProxy(m_editor);
    window.installEventFilter(this); // its activation shows the chat's replies to you
}

AssistantView::~AssistantView()
{
    s_views.removeAll(this);
}

void AssistantView::refreshAll()
{
    if (std::exchange(s_refreshQueued, true))
        return;
    QTimer::singleShot(0, qApp, [] {
        s_refreshQueued = false;
        if (std::any_of(s_views.cbegin(), s_views.cend(), [](AssistantView *v) {
                return v->isVisible() && v->window()->isActiveWindow() && !v->window()->isMinimized();
            }))
            AssistantBridge::markSeen(); // a reply in front of you is not unread
        for (AssistantView *v : std::as_const(s_views)) {
            if (v->isVisible())
                v->refresh();
            Q_EMIT v->changed();
        }
    });
}

void AssistantView::focusComposer()
{
    m_editor->setFocus();
}

void AssistantView::loadDirectory()
{
    m_directory = Assistant::directory(m_window.assistantWindows(), m_window.assistantProviders());
    m_sessions.clear();
    m_workspaces.clear();
    for (const QJsonValue &w : m_directory.value("workspaces").toArray()) {
        m_workspaces.insert(w["id"].toString(), w.toObject());
        for (const QJsonValue &s : w["sessions"].toArray()) {
            QJsonObject session = s.toObject();
            session.insert("workspace", w["id"]);
            m_sessions.insert(s["id"].toString(), session);
        }
    }
    QSet<QString> known{QStringLiteral("@all")};
    for (const QJsonObject &w : std::as_const(m_workspaces))
        if (!w["handle"].toString().isEmpty())
            known << QStringLiteral("@ws:") + w["handle"].toString().toLower();
    for (auto it = m_sessions.cbegin(); it != m_sessions.cend(); ++it)
        known << tagOf(it.key()).toLower();
    if (known != m_known) {
        m_known = known;
        if (m_highlighter)
            m_highlighter->rehighlight();
    }
}

// a over b, opaque
static QColor blend(const QColor &a, const QColor &b, qreal alpha)
{
    return QColor::fromRgbF(a.redF() * alpha + b.redF() * (1 - alpha), a.greenF() * alpha + b.greenF() * (1 - alpha),
                            a.blueF() * alpha + b.blueF() * (1 - alpha));
}

// opaque: a translucent background is painted per text run, and runs overlap by a pixel inside the tag
// shortcut: it assumes an opaque window behind the bubble; with window transparency the tag shows a shade darker
QColor AssistantView::tagTint(const QString &tag, const QColor &under) const
{
    return m_known.contains(tag.toLower()) ? blend(tagColor(tag), under, 0.3) : QColor();
}

QString AssistantView::tagged(const QString &body) const
{
    const QColor bubble = blend(accent(), QApplication::palette().color(QPalette::Base), 0.16);
    QString html;
    qsizetype at = 0;
    for (auto it = tagPattern().globalMatch(body); it.hasNext();) {
        const QRegularExpressionMatch m = it.next();
        if (const QColor tint = tagTint(m.captured(), bubble); tint.isValid()) {
            html += body.mid(at, m.capturedStart() - at).toHtmlEscaped();
            html += QStringLiteral("<span style=\"background-color:%1\">%2</span>").arg(css(tint), m.captured().toHtmlEscaped());
            at = m.capturedEnd();
        }
    }
    return QStringLiteral("<div style=\"white-space:pre-wrap\">%1</div>").arg(html + body.mid(at).toHtmlEscaped());
}

QStringList AssistantView::tags() const
{
    QStringList found;
    for (auto it = tagPattern().globalMatch(m_editor->toPlainText()); it.hasNext();)
        if (const QString t = it.next().captured(); m_known.contains(t.toLower()) && !found.contains(t))
            found << t;
    return found;
}

void AssistantView::refresh()
{
    loadDirectory();
    const QJsonObject read = m_window.assistantRequest({{"cmd", "assistant.read"}});
    const QJsonArray entries = read["result"]["assistant"]["entries"].toArray();
    // the transcript grows at its end until its cap trims the start: the entries that left go, the rest stay
    QSet<QString> ids;
    for (const QJsonValue &e : entries)
        ids.insert(e["id"].toString());
    while (!m_shown.isEmpty() && !ids.contains(m_shown.first())) {
        QLayoutItem *item = m_column->takeAt(0);
        delete item->widget();
        delete item;
        m_shown.removeFirst();
    }
    for (const QJsonValue &e : entries)
        if (!m_shown.contains(e["id"].toString()))
            append(e.toObject());
    m_empty->setVisible(m_shown.isEmpty());
    m_working->setVisible(m_directory.value("assistant")["running"].toBool());
    rebuildProviders();
}

QString AssistantView::tagOf(const QString &sessionId) const
{
    const QString handle = m_sessions.value(sessionId).value("handle").toString();
    return QLatin1Char('@') + (handle.isEmpty() ? sessionId : handle);
}

QColor AssistantView::tagColor(const QString &tag) const
{
    QString tint;
    if (tag.startsWith(QLatin1String("@ws:"))) {
        for (const QJsonObject &w : m_workspaces)
            if (QStringLiteral("@ws:") + w["handle"].toString() == tag)
                tint = w["tint"].toString();
    } else {
        for (const QJsonObject &s : m_sessions)
            if (tagOf(s["id"].toString()) == tag)
                tint = s["tint"].toString().isEmpty() ? m_workspaces.value(s["workspace"].toString())["tint"].toString() : s["tint"].toString();
    }
    const QColor c = tintColor(tint);
    return c.isValid() ? c : accent();
}

QWidget *AssistantView::chip(const QString &tag)
{
    auto *c = new QLabel(tag);
    const QColor color = tagColor(tag);
    QColor fill = color, edge = color;
    fill.setAlphaF(0.22);
    edge.setAlphaF(0.45);
    c->setFont(mono(font()));
    c->setStyleSheet(QStringLiteral("QLabel{background:%1;border:1px solid %2;border-radius:6px;padding:1px 7px;color:%3;}").arg(css(fill), css(edge), css(ink())));
    c->setSizePolicy(QSizePolicy::Fixed, QSizePolicy::Fixed);
    return c;
}

void AssistantView::insertTags(const QStringList &tags, QTextCursor at)
{
    if (tags.isEmpty())
        return;
    const QTextDocument *doc = m_editor->document();
    const QChar before = at.position() ? doc->characterAt(at.position() - 1) : QChar(u' ');
    const bool spaced = doc->characterAt(at.position()) == QLatin1Char(' ');
    QString words = tags.join(QLatin1Char(' '));
    if (!before.isSpace())
        words.prepend(QLatin1Char(' '));
    if (!spaced)
        words += QLatin1Char(' '); // typing goes on after the tag, and the completion does not reopen on it
    at.insertText(words);
    if (spaced)
        at.movePosition(QTextCursor::NextCharacter);
    m_editor->setTextCursor(at);
}

void AssistantView::syncSend()
{
    m_send->setEnabled(!m_editor->toPlainText().trimmed().isEmpty());
}

void AssistantView::append(const QJsonObject &e)
{
    const QString kind = e["kind"].toString(), body = e["text"].toString();
    QWidget *w = nullptr;
    if (kind == QLatin1String("user")) {
        auto *bubble = new QFrame;
        bubble->setObjectName(QStringLiteral("bubble"));
        bubble->setMaximumWidth(560);
        bubble->setStyleSheet(QStringLiteral("QFrame#bubble{background:%1;border:1px solid %2;border-top-left-radius:14px;border-top-right-radius:14px;"
                                             "border-bottom-left-radius:14px;border-bottom-right-radius:4px;}")
                                  .arg(css(accent(0.16)), css(accent(0.45))));
        auto *in = new QHBoxLayout(bubble);
        in->setContentsMargins(14, 10, 14, 10);
        QLabel *said = text(tagged(body), ink(), Qt::RichText); // the tags in place, marked as the composer marks them
        // a wrapping label asks for little width, so the bubble grows to the text's line, up to its cap
        said->setMinimumWidth(qMin(said->fontMetrics().horizontalAdvance(body) + 4, 420));
        in->addWidget(said, 1);
        w = new QWidget;
        auto *row = new QHBoxLayout(w);
        row->setContentsMargins(0, 0, 0, 0);
        row->addStretch(1);
        row->addWidget(bubble);
    } else if (kind == QLatin1String("assistant")) {
        w = text(body, ink(0.92), Qt::MarkdownText);
    } else if (kind == QLatin1String("sent") || kind == QLatin1String("reply")) {
        // the side tells the direction, as in a messenger: from a session on the left, to sessions on the right
        const bool sent = kind == QLatin1String("sent");
        auto *c = new QFrame;
        c->setObjectName(QStringLiteral("card"));
        c->setStyleSheet(QStringLiteral("QFrame#card{border:1px solid %1;border-radius:12px;%2:4px;background:%3;}")
                             .arg(css(ink(0.14)), sent ? QStringLiteral("border-bottom-right-radius") : QStringLiteral("border-bottom-left-radius"),
                                  sent ? QStringLiteral("transparent") : css(ink(0.06))));
        c->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
        auto *box = new QVBoxLayout(c);
        box->setContentsMargins(14, 14, 11, 12); // the arrow's glyph sits as far in as the caption
        box->setSpacing(8);
        auto *rows = new QGridLayout;
        rows->setHorizontalSpacing(6);
        rows->setVerticalSpacing(6);
        rows->setColumnStretch(2, 1);
        rows->addWidget(caption(sent ? tr("To") : tr("From")), 0, 0);
        const QJsonArray peers = sent ? e["to"].toArray() : QJsonArray{e["from"]};
        for (int i = 0; i < peers.size(); ++i) {
            const QString id = peers[i].toString();
            rows->addWidget(chip(tagOf(id)), i, 1);
            rows->addWidget(new Elided(m_sessions.value(id)["name"].toString(), ink(0.55)), i, 2);
            auto *go = new QToolButton;
            go->setIcon(QIcon(sendGlyph(accent())));
            go->setIconSize(QSize(14, 14));
            go->setFixedSize(16, 16);
            go->setStyleSheet(QStringLiteral("QToolButton{border:0;padding:0;border-radius:4px;}QToolButton:hover{background:%1;}").arg(css(ink(0.1))));
            go->setFocusPolicy(Qt::NoFocus);
            go->setCursor(Qt::PointingHandCursor);
            go->setToolTip(tr("Go to session"));
            go->setAccessibleName(tr("Go to session"));
            connect(go, &QToolButton::clicked, this, [this, id] { m_window.goToSession(id); });
            rows->addWidget(go, i, 3);
        }
        box->addLayout(rows);
        box->addWidget(text(body, sent ? ink(0.7) : ink()));
        w = new QWidget;
        auto *row = new QHBoxLayout(w);
        row->setContentsMargins(0, 0, 0, 0);
        row->insertWidget(0, c, 4);
        row->insertStretch(sent ? 0 : 1, 1); // a fifth of the column on the far side
    } else {
        const bool dark = QApplication::palette().color(QPalette::Window).lightness() < 128;
        w = text(body, QColor(dark ? 0xFF453A : 0xD70015)); // system red
    }
    m_column->addWidget(w);
    m_shown << e["id"].toString();
}

void AssistantView::rebuildProviders()
{
    const QJsonObject node = m_directory.value("assistant").toObject();
    DetectedLaunchers *found = m_window.assistantLaunchers();
    if (m_watched != found) { // the list fills when the login shell answers, a second or more after launch
        m_watched = found;
        connect(found, &DetectedLaunchers::changed, this, [] { refreshAll(); });
    }
    if (!found->detected()) { // still looking: the saved choice, not "none found"
        const Launcher *saved = launcher(node["provider"].toString());
        m_provider->setText(saved ? saved->title : tr("Detecting agents…"));
        m_provider->setEnabled(false);
        m_providerRows.clear();
        return;
    }
    const QJsonArray providers = node["providers"].toArray();
    QString current = node["provider"].toString();
    if (!providers.contains(QJsonValue(current)))
        current = providers.isEmpty() ? QString() : providers.first().toString();
    const Launcher *shown = launcher(current);
    m_provider->setText(shown ? shown->title : tr("No agent found"));
    m_provider->setEnabled(!providers.isEmpty());
    m_providerRows.clear();
    for (const QJsonValue &v : providers) {
        const Launcher *l = launcher(v.toString());
        m_providerRows.append({v.toString(), l ? l->title : v.toString()});
    }
    m_currentProvider = current;
}

void AssistantView::openProviders()
{
    auto *popup = new ProviderPopup(m_provider, m_providerRows, m_currentProvider, [this](const QString &id) {
        const QJsonObject r = m_window.assistantRequest({{"cmd", "assistant.provider"}, {"args", QJsonObject{{"provider", id}}}});
        if (!r["ok"].toBool())
            m_window.statusBar()->showMessage(r["error"].toString(), 4000);
        refreshAll();
    });
    // the panel's left edge on the button's, its bottom 6 px above the composer box
    const QPoint button = m_provider->mapToGlobal(QPoint(0, 0));
    const int boxTop = findChild<QFrame *>(QStringLiteral("composer"))->mapToGlobal(QPoint(0, 0)).y();
    popup->move(onScreen(QPoint(button.x() - ProviderPopup::Shadow, boxTop - 6 - popup->height() + ProviderPopup::Shadow), popup->size()));
    popup->show();
}

QPoint AssistantView::onScreen(QPoint at, const QSize &size) const
{
    if (const QScreen *screen = window()->screen()) {
        const QRect room = screen->availableGeometry();
        at.setX(qBound(room.left(), at.x(), qMax(room.left(), room.right() - size.width() + 1)));
        at.setY(qBound(room.top(), at.y(), qMax(room.top(), room.bottom() - size.height() + 1)));
    }
    return at;
}

void AssistantView::complete()
{
    const QTextCursor cursor = m_editor->textCursor();
    static const QRegularExpression token(QStringLiteral("(?:^|\\s)(@[^\\s@]*)$"));
    const QRegularExpressionMatch m = token.match(cursor.block().text().left(cursor.positionInBlock()));
    if (!m.hasMatch())
        return m_completer->popup()->hide();
    loadDirectory();
    m_candidates->clear();
    QList<std::array<QString, 3>> rows; // tag, name, icon
    rows.append({QStringLiteral("@all"), tr("every agent session"), QStringLiteral("chrome:dashboard")});
    for (const QJsonValue &w : m_directory.value("workspaces").toArray()) {
        if (!w["handle"].toString().isEmpty())
            rows.append({QStringLiteral("@ws:") + w["handle"].toString(), w["name"].toString(), QStringLiteral("chrome:workspace-stack")});
        for (const QJsonValue &s : w["sessions"].toArray())
            rows.append({tagOf(s["id"].toString()), s["name"].toString(), s["agent"].toString().isEmpty() ? QStringLiteral("terminal") : s["agent"].toString()});
    }
    const QFontMetrics fm(m_completer->popup()->font());
    int column = 0;
    for (const auto &r : std::as_const(rows))
        column = qMax(column, fm.horizontalAdvance(r[0]) + 16);
    for (const auto &r : std::as_const(rows)) {
        auto *item = new QStandardItem(r[0]);
        item->setData(r[0], Qt::UserRole);
        item->setData(r[1], PaletteRole::Subtitle);
        item->setData(r[2], PaletteRole::Icon);
        item->setData(true, PaletteRole::SingleLine);
        item->setData(column, PaletteRole::TitleColumn);
        m_candidates->appendRow(item);
    }
    m_completer->setCompletionPrefix(m.captured(1));
    if (!m_completer->completionCount())
        return m_completer->popup()->hide();
    QRect at = m_editor->cursorRect();
    at.setWidth(qMin(460, 28 + column + 200 + 32)); // icon, handle column, a name, margins
    m_completer->complete(at);
    // QCompleter flips the popup above the cursor line, which still lies inside the composer; lift it clear of the box.
    // It is unmapped first: a Wayland compositor may not move an xdg_popup already shown.
    QAbstractItemView *popup = m_completer->popup();
    const QWidget *box = findChild<QFrame *>(QStringLiteral("composer"));
    popup->hide();
    popup->resize(popup->width(), popup->height() + 5); // the list's 5 px top padding, so the last row keeps its room
    popup->move(onScreen(QPoint(box->mapToGlobal(QPoint(0, 0)).x(), box->mapToGlobal(QPoint(0, 0)).y() - popup->height() - 6), popup->size()));
    popup->show();
    popup->setCurrentIndex(m_completer->completionModel()->index(0, 0));
}

void AssistantView::send()
{
    const QString body = m_editor->toPlainText().trimmed();
    if (body.isEmpty())
        return;
    const QJsonObject r = m_window.assistantRequest({{"cmd", "assistant.ask"}, {"args", QJsonObject{{"text", body}}}});
    if (!r["ok"].toBool())
        return m_window.statusBar()->showMessage(r["error"].toString(), 4000);
    m_editor->clear();
}

bool AssistantView::dropTags(const QMimeData *mime, const QTextCursor &at)
{
    loadDirectory();
    QStringList tags;
    if (mime->hasFormat(SidebarMime::sessions)) {
        for (const QString &id : QString::fromUtf8(mime->data(SidebarMime::sessions)).split(QLatin1Char(',')))
            if (m_sessions.contains(id))
                tags << tagOf(id);
    } else if (mime->hasFormat(SidebarMime::workspace)) {
        if (const QString handle = m_workspaces.value(QString::fromUtf8(mime->data(SidebarMime::workspace)))["handle"].toString(); !handle.isEmpty())
            tags << QStringLiteral("@ws:") + handle;
    } else {
        return false;
    }
    insertTags(tags, at);
    return true;
}

QTextCursor AssistantView::landing(QObject *watched, QPointF pos) const
{
    QTextCursor at = watched == m_editor->viewport() ? m_editor->cursorForPosition(pos.toPoint()) : m_editor->textCursor();
    const QTextDocument *doc = m_editor->document();
    while (!at.atEnd() && at.position() && !doc->characterAt(at.position() - 1).isSpace() && !doc->characterAt(at.position()).isSpace())
        at.movePosition(QTextCursor::NextCharacter); // past the word the pointer splits
    return at;
}

void AssistantView::paintEvent(QPaintEvent *event)
{
    // the content surface, as a terminal is, so the chat does not merge into the toolbar's Window colour
    QPainter p(this);
    p.setCompositionMode(QPainter::CompositionMode_Source);
    QColor surface = palette().color(QPalette::Base);
    surface.setAlphaF(1 - qBound(0.0, m_store.settings.windowTransparency, 90.0) / 100);
    p.fillRect(event->rect(), surface);
}

bool AssistantView::eventFilter(QObject *watched, QEvent *event)
{
    switch (event->type()) {
    case QEvent::WindowActivate:
        if (watched == &m_window && isVisible())
            refreshAll();
        return false;
    case QEvent::Paint:
        if (watched == m_completer->popup()) { // the provider panel's rounded surface under a transparent list
            auto *popup = static_cast<QWidget *>(watched);
            QPainter p(popup);
            p.setRenderHint(QPainter::Antialiasing);
            p.setPen(QPen(ink(0.14), 1));
            p.setBrush(QApplication::palette().color(QPalette::Window));
            p.drawRoundedRect(QRectF(popup->rect()).adjusted(0.5, 0.5, -0.5, -0.5), 10, 10);
        }
        return false;
    case QEvent::DragEnter:
    case QEvent::DragMove: {
        auto *drag = static_cast<QDragMoveEvent *>(event);
        if (!drag->mimeData()->hasFormat(SidebarMime::sessions) && !drag->mimeData()->hasFormat(SidebarMime::workspace))
            return false; // text and files drop into the message as usual
        drag->acceptProposedAction(); // the sidebar offers a move and removes nothing after it, as onto a terminal
        m_editor->setFocus(); // the caret shows where the tag lands
        m_editor->setTextCursor(landing(watched, drag->position()));
        return true;
    }
    case QEvent::Drop: {
        auto *drop = static_cast<QDropEvent *>(event);
        if (!dropTags(drop->mimeData(), landing(watched, drop->position())))
            return false;
        drop->acceptProposedAction();
        m_editor->setFocus();
        return true;
    }
    default:
        break;
    }
    return QWidget::eventFilter(watched, event);
}
