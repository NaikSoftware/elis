#include "paneleadcover.h"

#include "zmx.h"

#include <QIcon>
#include <QKeyEvent>
#include <QLabel>
#include <QPainter>
#include <QVBoxLayout>

// the key that took a pane over, swallowed until released so neither its repeats nor its release reach the program
// through the fresh attach
static int s_takeoverKey = 0;

PaneLeadCover::PaneLeadCover(QWidget *pane, QWidget *display, std::function<void()> takeOver, std::function<bool(QKeyEvent *)> ownShortcut)
    : QWidget(pane)
    , m_display(display)
    , m_takeOver(std::move(takeOver))
    , m_ownShortcut(std::move(ownShortcut))
{
    setObjectName(QStringLiteral("paneLeadCover"));
    setFocusPolicy(Qt::NoFocus);
    auto *box = new QVBoxLayout(this);
    box->addStretch();
    auto *icon = new QLabel;
    icon->setPixmap(QIcon::fromTheme(QStringLiteral("view-hidden")).pixmap(32));
    icon->setAlignment(Qt::AlignCenter);
    box->addWidget(icon);
    m_title = new QLabel;
    QFont f = m_title->font();
    f.setWeight(QFont::Medium);
    f.setPointSizeF(f.pointSizeF() * 1.15);
    m_title->setFont(f);
    m_hint = new QLabel(tr("Press any key to use it here"));
    m_hint->setEnabled(false); // the palette's dimmed text
    for (QLabel *l : {m_title, m_hint}) {
        l->setAlignment(Qt::AlignCenter);
        l->setWordWrap(true);
        box->addWidget(l);
    }
    box->addStretch();
    pane->installEventFilter(this);
    if (display)
        display->installEventFilter(this);
    hide();
}

QString PaneLeadCover::title(const QString &role, bool reattaching)
{
    if (reattaching)
        return tr("Taking over…");
    if (role == QLatin1String("unowned"))
        return tr("Reconnecting…");
    return tr("In use in another terminal");
}

void PaneLeadCover::apply(const Zmx::Lead &lead)
{
    m_covered = lead.covered;
    m_reattaching = lead.reattaching;
    m_title->setText(title(lead.role, lead.reattaching));
    m_hint->setVisible(!lead.reattaching);
    setGeometry(parentWidget()->rect());
    setVisible(m_covered);
    if (m_covered)
        raise();
}

bool PaneLeadCover::eventFilter(QObject *watched, QEvent *event)
{
    if (watched == parentWidget()) {
        if (event->type() == QEvent::Resize)
            setGeometry(parentWidget()->rect());
        return false;
    }
    if (event->type() != QEvent::KeyPress && event->type() != QEvent::KeyRelease)
        return false;
    auto *key = static_cast<QKeyEvent *>(event);
    if (s_takeoverKey && key->key() == s_takeoverKey) {
        if (event->type() == QEvent::KeyRelease || key->isAutoRepeat()) {
            if (event->type() == QEvent::KeyRelease)
                s_takeoverKey = 0;
            return true;
        }
        s_takeoverKey = 0; // a fresh press proves the key was released
    }
    if (!m_covered)
        return false;
    if (m_ownShortcut && m_ownShortcut(key))
        return false; // the window's shortcuts stay the window's
    const bool modifierOnly = key->key() == Qt::Key_Shift || key->key() == Qt::Key_Control || key->key() == Qt::Key_Alt
        || key->key() == Qt::Key_Meta || key->key() == Qt::Key_AltGr;
    // already on its way, a modifier alone, or a key held since before the cover came up
    if (event->type() == QEvent::KeyPress && !m_reattaching && !modifierOnly && !key->isAutoRepeat()) {
        s_takeoverKey = key->key();
        m_reattaching = true;
        m_takeOver(); // retires this pane later, never inside its own event
    }
    return true;
}

void PaneLeadCover::mousePressEvent(QMouseEvent *)
{
    if (m_display)
        m_display->setFocus();
}

void PaneLeadCover::paintEvent(QPaintEvent *)
{
    QPainter(this).fillRect(rect(), palette().window());
}
