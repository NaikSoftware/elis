#include "assistantview.h"

#include "assistant.h"
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
#include <QMenu>
#include <QMimeData>
#include <QPaintEvent>
#include <QPainter>
#include <QPlainTextEdit>
#include <QRegularExpression>
#include <QScrollArea>
#include <QScrollBar>
#include <QStandardItemModel>
#include <QStatusBar>
#include <QTextBlock>
#include <QTimer>
#include <QToolButton>
#include <QVBoxLayout>

#include <array>

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

QFrame *card()
{
    auto *f = new QFrame;
    f->setObjectName(QStringLiteral("card"));
    f->setStyleSheet(QStringLiteral("QFrame#card{border:1px solid %1;border-radius:12px;background:%2;}").arg(css(ink(0.14)), css(ink(0.04))));
    return f;
}

QFrame *hairline()
{
    auto *f = new QFrame;
    f->setFixedHeight(1);
    f->setStyleSheet(QStringLiteral("background:%1;").arg(css(ink(0.10))));
    return f;
}

class Chip : public QLabel
{
public:
    std::function<void()> removed;
    using QLabel::QLabel;

protected:
    void mousePressEvent(QMouseEvent *) override
    {
        if (removed)
            removed();
    }
};

// The message box's keys live here, not in an event filter: QCompleter passes its popup's keys to the widget's event()
// directly, and takes Return, Tab and Escape itself only when the widget leaves them unaccepted.
class ComposerEdit : public QPlainTextEdit
{
public:
    std::function<void()> send;
    std::function<bool()> untag; // Backspace at the start: true when it took the last tag
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
        if (key->key() == Qt::Key_Backspace && textCursor().position() == 0 && !textCursor().hasSelection() && untag())
            return;
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
    main->addWidget(hairline());

    // the composer: tag chips and the message, then the provider picker and send
    auto *composer = new QFrame;
    composer->setObjectName(QStringLiteral("composer"));
    composer->setStyleSheet(QStringLiteral("QFrame#composer{border:1px solid %1;border-radius:14px;background:%2;}")
                                .arg(css(ink(0.22)), css(QApplication::palette().color(QPalette::Window))));
    composer->setAcceptDrops(true);
    composer->installEventFilter(this);
    auto *box = new QVBoxLayout(composer);
    box->setContentsMargins(14, 10, 14, 10);
    box->setSpacing(8);
    auto *top = new QHBoxLayout;
    top->setSpacing(6);
    m_chips = new QWidget;
    auto *chips = new QHBoxLayout(m_chips);
    chips->setContentsMargins(0, 0, 0, 0);
    chips->setSpacing(6);
    m_chips->hide();
    top->addWidget(m_chips, 0, Qt::AlignTop);
    auto *editor = new ComposerEdit;
    editor->send = [this] { send(); };
    editor->untag = [this] {
        if (m_tags.isEmpty())
            return false;
        for (QObject *o : m_chips->children())
            if (auto *c = dynamic_cast<Chip *>(o); c && c->text().startsWith(m_tags.last() + QLatin1Char(' ')))
                c->removed();
        return true;
    };
    m_editor = editor;
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
    top->addWidget(m_editor, 1);
    box->addLayout(top);
    auto *bottom = new QHBoxLayout;
    bottom->setSpacing(8);
    m_provider = new QToolButton;
    m_provider->setObjectName(QStringLiteral("assistantProvider"));
    m_provider->setPopupMode(QToolButton::InstantPopup);
    m_provider->setMenu(new QMenu(m_provider));
    m_provider->setFocusPolicy(Qt::NoFocus);
    m_provider->setStyleSheet(QStringLiteral("QToolButton{border:1px solid %1;border-radius:7px;padding:3px 10px;background:%2;}"
                                             "QToolButton::menu-indicator{image:none;width:0;}")
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
    auto syncSend = [this] { m_send->setEnabled(!m_tags.isEmpty() || !m_editor->toPlainText().trimmed().isEmpty()); };
    connect(m_editor, &QPlainTextEdit::textChanged, this, syncSend);
    syncSend();

    m_candidates = new QStandardItemModel(this);
    m_completer = new QCompleter(m_candidates, this);
    m_completer->setWidget(m_editor);
    m_completer->setCompletionMode(QCompleter::PopupCompletion);
    m_completer->setCaseSensitivity(Qt::CaseInsensitive);
    m_completer->setCompletionRole(Qt::UserRole);
    m_completer->popup()->setObjectName(QStringLiteral("assistantCompletion"));
    m_completer->popup()->setItemDelegate(Palette::rowDelegate(m_completer->popup())); // the session switcher's rows
    m_completer->setMaxVisibleItems(8);
    editor->completer = m_completer;
    connect(m_completer, qOverload<const QModelIndex &>(&QCompleter::activated), this, [this](const QModelIndex &index) {
        QTextCursor c = m_editor->textCursor();
        c.movePosition(QTextCursor::Left, QTextCursor::KeepAnchor, int(m_completer->completionPrefix().size()));
        c.removeSelectedText();
        m_editor->setTextCursor(c);
        addTag(index.data(Qt::UserRole).toString());
    });
    connect(m_editor, &QPlainTextEdit::textChanged, this, &AssistantView::complete);

    setFocusProxy(m_editor);
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
        if (std::any_of(s_views.cbegin(), s_views.cend(), [](AssistantView *v) { return v->isVisible(); }))
            AssistantBridge::markSeen(); // a reply already on screen is not unread
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
}

void AssistantView::refresh()
{
    loadDirectory();
    const QJsonObject read = m_window.assistantRequest({{"cmd", "assistant.read"}});
    const QJsonArray entries = read["result"]["assistant"]["entries"].toArray();
    // the transcript grows at its end until its cap trims the start, which redraws the column
    if (!m_shown.isEmpty() && (entries.isEmpty() || entries.first()["id"].toString() != m_shown.first())) {
        while (QLayoutItem *item = m_column->takeAt(0)) {
            delete item->widget();
            delete item;
        }
        m_shown.clear();
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

QWidget *AssistantView::chip(const QString &tag, bool removable)
{
    auto *c = new Chip(removable ? tag + QStringLiteral("  ×") : tag);
    const QColor color = tagColor(tag);
    QColor fill = color, edge = color;
    fill.setAlphaF(0.22);
    edge.setAlphaF(0.45);
    c->setFont(mono(font()));
    c->setStyleSheet(QStringLiteral("QLabel{background:%1;border:1px solid %2;border-radius:6px;padding:1px 7px;color:%3;}").arg(css(fill), css(edge), css(ink())));
    c->setSizePolicy(QSizePolicy::Fixed, QSizePolicy::Fixed);
    if (removable) {
        c->setToolTip(tr("Remove"));
        c->setCursor(Qt::PointingHandCursor);
        c->removed = [this, tag] {
            m_tags.removeAll(tag);
            for (QObject *o : m_chips->children())
                if (auto *l = qobject_cast<QLabel *>(o); l && l->text().startsWith(tag + QLatin1Char(' ')))
                    l->deleteLater();
            m_chips->setVisible(!m_tags.isEmpty());
            Q_EMIT m_editor->textChanged(); // the send button follows the tags too
        };
    }
    return c;
}

void AssistantView::addTag(const QString &tag)
{
    if (tag.isEmpty() || m_tags.contains(tag))
        return;
    m_tags << tag;
    loadDirectory(); // the chip's colour
    m_chips->layout()->addWidget(chip(tag, true));
    m_chips->show();
    Q_EMIT m_editor->textChanged();
}

void AssistantView::append(const QJsonObject &e)
{
    const QString kind = e["kind"].toString(), body = e["text"].toString();
    QWidget *w = nullptr;
    if (kind == QLatin1String("user")) {
        // the leading tags as chips, as the composer showed them
        QStringList words = body.split(QLatin1Char(' '));
        QStringList tags;
        while (!words.isEmpty() && words.first().startsWith(QLatin1Char('@')) && words.first().size() > 1)
            tags << words.takeFirst();
        auto *bubble = new QFrame;
        bubble->setObjectName(QStringLiteral("bubble"));
        bubble->setMaximumWidth(560);
        bubble->setStyleSheet(QStringLiteral("QFrame#bubble{background:%1;border:1px solid %2;border-top-left-radius:14px;border-top-right-radius:14px;"
                                             "border-bottom-left-radius:14px;border-bottom-right-radius:4px;}")
                                  .arg(css(accent(0.16)), css(accent(0.45))));
        auto *in = new QHBoxLayout(bubble);
        in->setContentsMargins(14, 10, 14, 10);
        in->setSpacing(6);
        for (const QString &t : std::as_const(tags))
            in->addWidget(chip(t, false), 0, Qt::AlignTop);
        if (!words.isEmpty()) {
            QLabel *said = text(words.join(QLatin1Char(' ')), ink());
            // a wrapping label asks for little width, so the bubble grows to the text's line, up to its cap
            said->setMinimumWidth(qMin(said->fontMetrics().horizontalAdvance(said->text()) + 4, 420));
            in->addWidget(said, 1);
        }
        w = new QWidget;
        auto *row = new QHBoxLayout(w);
        row->setContentsMargins(0, 0, 0, 0);
        row->addStretch(1);
        row->addWidget(bubble);
    } else if (kind == QLatin1String("assistant")) {
        w = text(body, ink(0.92), Qt::MarkdownText);
    } else if (kind == QLatin1String("sent") || kind == QLatin1String("reply")) {
        QFrame *c = card();
        auto *box = new QVBoxLayout(c);
        box->setContentsMargins(14, 10, 14, 12);
        box->setSpacing(8);
        auto *head = new QHBoxLayout;
        head->setSpacing(6);
        if (kind == QLatin1String("sent")) {
            head->addWidget(caption(tr("Sent to")));
            for (const QJsonValue &to : e["to"].toArray())
                head->addWidget(chip(tagOf(to.toString()), false));
            head->addStretch(1);
        } else {
            const QString from = e["from"].toString();
            head->addWidget(chip(tagOf(from), false));
            QLabel *name = text(m_sessions.value(from)["name"].toString(), ink(0.55));
            name->setWordWrap(false);
            head->addWidget(name, 1);
            auto *go = new QLabel(QStringLiteral("<a href=\"#\" style=\"color:%1;text-decoration:none\">%2</a>").arg(accent().name(), tr("Go to session")));
            go->setCursor(Qt::PointingHandCursor);
            connect(go, &QLabel::linkActivated, this, [this, from] { m_window.goToSession(from); });
            head->addWidget(go);
        }
        box->addLayout(head);
        box->addWidget(text(body, kind == QLatin1String("sent") ? ink(0.7) : ink()));
        w = c;
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
    const QJsonArray providers = node["providers"].toArray();
    QString current = node["provider"].toString();
    if (!providers.contains(QJsonValue(current)))
        current = providers.isEmpty() ? QString() : providers.first().toString();
    const Launcher *shown = launcher(current);
    m_provider->setText(shown ? shown->title : tr("No agent found"));
    m_provider->setEnabled(!providers.isEmpty());
    QMenu *menu = m_provider->menu();
    menu->clear();
    menu->addSection(tr("Found on this system"));
    for (const QJsonValue &v : providers) {
        const QString id = v.toString();
        const Launcher *l = launcher(id);
        menu->addAction(l ? l->title : id, this, [this, id] {
            const QJsonObject r = m_window.assistantRequest({{"cmd", "assistant.provider"}, {"args", QJsonObject{{"provider", id}}}});
            if (!r["ok"].toBool())
                m_window.statusBar()->showMessage(r["error"].toString(), 4000);
            refreshAll();
        });
    }
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
    // QCompleter flips the popup above the cursor line, which still lies inside the composer; lift it clear of the box
    QAbstractItemView *popup = m_completer->popup();
    const QWidget *box = findChild<QFrame *>(QStringLiteral("composer"));
    popup->move(popup->x(), box->mapToGlobal(QPoint(0, 0)).y() - popup->height() - 6);
    popup->setCurrentIndex(m_completer->completionModel()->index(0, 0));
}

void AssistantView::send()
{
    const QString body = m_editor->toPlainText().trimmed();
    if (body.isEmpty() && m_tags.isEmpty())
        return;
    QStringList parts = m_tags;
    if (!body.isEmpty())
        parts << body;
    const QJsonObject r = m_window.assistantRequest({{"cmd", "assistant.ask"}, {"args", QJsonObject{{"text", parts.join(QLatin1Char(' '))}}}});
    if (!r["ok"].toBool())
        return m_window.statusBar()->showMessage(r["error"].toString(), 4000);
    m_editor->clear();
    m_tags.clear();
    for (QObject *o : m_chips->children())
        if (o->isWidgetType())
            o->deleteLater();
    m_chips->hide();
}

bool AssistantView::dropTags(const QMimeData *mime)
{
    loadDirectory();
    if (mime->hasFormat(SidebarMime::sessions)) {
        for (const QString &id : QString::fromUtf8(mime->data(SidebarMime::sessions)).split(QLatin1Char(',')))
            if (m_sessions.contains(id))
                addTag(tagOf(id));
        return true;
    }
    if (mime->hasFormat(SidebarMime::workspace)) {
        if (const QString handle = m_workspaces.value(QString::fromUtf8(mime->data(SidebarMime::workspace)))["handle"].toString(); !handle.isEmpty())
            addTag(QStringLiteral("@ws:") + handle);
        return true;
    }
    return false;
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
    case QEvent::DragEnter:
    case QEvent::DragMove: {
        auto *drag = static_cast<QDragMoveEvent *>(event);
        if (!drag->mimeData()->hasFormat(SidebarMime::sessions) && !drag->mimeData()->hasFormat(SidebarMime::workspace))
            return false; // text and files drop into the message as usual
        drag->acceptProposedAction(); // the sidebar offers a move and removes nothing after it, as onto a terminal
        return true;
    }
    case QEvent::Drop: {
        auto *drop = static_cast<QDropEvent *>(event);
        if (!dropTags(drop->mimeData()))
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
