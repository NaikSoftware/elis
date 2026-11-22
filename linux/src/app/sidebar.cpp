#include "sidebar.h"

#include "assistant.h"
#include "store.h"

#include <QApplication>
#include <QLinearGradient>
#include <QDrag>
#include <QDragEnterEvent>
#include <QFile>
#include <QFileInfo>
#include <QFontDatabase>
#include <QHash>
#include <QLineEdit>
#include <QMimeData>
#include <QPainter>
#include <QPainterPath>
#include <QScrollBar>
#include <QSvgRenderer>
#include <QtMath>

using namespace SidebarRole;

QColor statusColor(const Settings &settings, const QString &status)
{
    // elis's defaults: active #DBD9E6, blocked system orange, completed system green
    const QHash<QString, std::pair<QString, QColor>> table{{QStringLiteral("active"), {settings.activeStatusColorHex, QColor(0xDB, 0xD9, 0xE6)}},
                                                           {QStringLiteral("blocked"), {settings.blockedStatusColorHex, QColor(0xFF, 0x9F, 0x0A)}},
                                                           {QStringLiteral("completed"), {settings.completedStatusColorHex, QColor(0x30, 0xD1, 0x58)}}};
    const auto [hex, fallback] = table.value(status);
    return QColor::isValidColorName(hex) ? QColor(hex) : fallback;
}

QString statusShape(const Settings &settings, const QString &status)
{
    const QString shape = status == QLatin1String("active")      ? settings.activeStatusShape
                          : status == QLatin1String("blocked")   ? settings.blockedStatusShape
                          : status == QLatin1String("completed") ? settings.completedStatusShape
                                                                 : QString();
    if (!shape.isEmpty())
        return shape;
    // elis's defaults: active circle, blocked triangle, completed diamond
    return status == QLatin1String("blocked") ? QStringLiteral("triangle") : status == QLatin1String("completed") ? QStringLiteral("diamond") : QStringLiteral("circle");
}

void drawStatusGlyph(QPainter *p, const QPointF &c, qreal r, const QString &shape)
{
    if (shape == QLatin1String("square")) {
        p->drawRoundedRect(QRectF(c.x() - r * 0.85, c.y() - r * 0.85, r * 1.7, r * 1.7), r * 0.3, r * 0.3);
    } else if (shape == QLatin1String("capsule")) {
        p->drawRoundedRect(QRectF(c.x() - r, c.y() - r * 0.6, r * 2, r * 1.2), r * 0.6, r * 0.6);
    } else if (shape == QLatin1String("triangle") || shape == QLatin1String("diamond") || shape == QLatin1String("star")) {
        QPolygonF poly;
        const int points = shape == QLatin1String("triangle") ? 3 : shape == QLatin1String("diamond") ? 4 : 10;
        for (int i = 0; i < points; ++i) {
            const qreal a = -M_PI / 2 + i * 2 * M_PI / points, radius = shape == QLatin1String("star") && i % 2 ? r * 0.45 : r * 1.1;
            poly << c + QPointF(radius * qCos(a), radius * qSin(a) + (points == 3 ? r * 0.2 : 0));
        }
        p->drawPolygon(poly);
    } else {
        p->drawEllipse(c, r, r);
    }
}

void paintStatus(QPainter *p, const Settings &settings, const QString &status, bool blink, int blinkAlpha, QPointF centre)
{
    if (status.isEmpty() || status == QLatin1String("idle"))
        return;
    QColor c = statusColor(settings, status);
    if (blink)
        c.setAlpha(blinkAlpha);
    p->setPen(Qt::NoPen);
    p->setBrush(c);
    drawStatusGlyph(p, centre, 5, statusShape(settings, status));
}

static int attentionRank(const QString &status)
{
    return status == QLatin1String("blocked") ? 0 : status == QLatin1String("active") ? 1 : 2;
}

static const char *sessionsMime = SidebarMime::sessions;
static const char *workspaceMime = SidebarMime::workspace;

namespace {
QImage tintedSvg(const QString &path, const QColor &color, int px)
{
    static QHash<QString, QImage> cache;
    const QString key = QStringLiteral("%1/%2/%3").arg(path, color.name(QColor::HexArgb)).arg(px);
    if (auto it = cache.constFind(key); it != cache.cend())
        return *it;
    QImage img(px, px, QImage::Format_ARGB32_Premultiplied);
    img.fill(Qt::transparent);
    QSvgRenderer svg(path);
    QPainter p(&img);
    svg.render(&p, QRectF(0, 0, px, px));
    p.setCompositionMode(QPainter::CompositionMode_SourceIn); // template image: keep alpha, take the colour
    p.fillRect(img.rect(), color);
    p.end();
    cache.insert(key, img);
    return img;
}

void drawSvg(QPainter *p, const QRectF &r, const QString &path, const QColor &c)
{
    const qreal dpr = p->device()->devicePixelRatioF();
    QImage img = tintedSvg(path, c, qRound(r.width() * dpr));
    img.setDevicePixelRatio(dpr);
    p->drawImage(r.topLeft(), img);
}

// elis's bundled Lucide glyphs (resources/glyphs): workspace-stack[-focused], session-terminal, session-plus,
// focus-frame[-fill], flag-lucide
void drawGlyph(QPainter *p, const QRectF &r, const QString &name, const QColor &c)
{
    drawSvg(p, r, QStringLiteral(":/glyphs/%1.svg").arg(name), c);
}
} // namespace

void drawLauncher(QPainter *p, const QRectF &r, const QString &id, const QColor &c)
{
    if (id.isEmpty() || id == QLatin1String("terminal"))
        drawGlyph(p, r, QStringLiteral("session-terminal"), c);
    else
        drawSvg(p, r, QStringLiteral(":/launchers/%1.svg").arg(id), c);
}

QColor tintColor(const QString &name)
{
    if (name.startsWith(QLatin1Char('#')))
        return QColor(name); // a hex is fixed sRGB in both appearances, as on the Mac
    const bool dark = QApplication::palette().color(QPalette::Window).lightness() < 128;
    for (const TintSwatch &c : Store::tintPalette())
        if (c.name == name)
            return QColor(dark ? c.dark : c.light);
    return {};
}

QIcon launcherIcon(const QString &launcherId, const QColor &color)
{
    QPixmap pm(QSize(32, 32));
    pm.fill(Qt::transparent);
    QPainter p(&pm);
    p.setRenderHint(QPainter::Antialiasing);
    p.scale(2, 2);
    drawLauncher(&p, QRectF(0, 0, 16, 16), launcherId, color);
    p.end();
    pm.setDevicePixelRatio(2);
    return QIcon(pm);
}

QIcon chromeIcon(const QString &name, const QColor &color)
{
    QPixmap pm(QSize(40, 40));
    pm.fill(Qt::transparent);
    QPainter p(&pm);
    p.setRenderHint(QPainter::Antialiasing);
    p.scale(2, 2);
    auto done = [&] {
        p.end();
        pm.setDevicePixelRatio(2);
        return QIcon(pm);
    };
    if (QFile::exists(QStringLiteral(":/glyphs/%1.svg").arg(name))) {
        drawGlyph(&p, QRectF(2.5, 2.5, 15, 15), name, color);
        return done();
    }
    p.setPen(QPen(color, 1.3, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
    if (name == QLatin1String("clock")) { // the title bar's recent sessions
        p.drawEllipse(QRectF(3, 3, 14, 14));
        p.drawPolyline(QList<QPointF>{{10, 6}, {10, 10}, {13, 12}});
        return done();
    }
    if (name == QLatin1String("filepanel")) {
        // elis's "folder" symbol: a tab on the left of the lid
        QPainterPath folder;
        folder.moveTo(2.5, 15);
        folder.lineTo(2.5, 5.5);
        folder.quadTo(2.5, 4.5, 3.5, 4.5);
        folder.lineTo(7.5, 4.5);
        folder.lineTo(9, 6.5);
        folder.lineTo(16.5, 6.5);
        folder.quadTo(17.5, 6.5, 17.5, 7.5);
        folder.lineTo(17.5, 15);
        folder.quadTo(17.5, 16, 16.5, 16);
        folder.lineTo(3.5, 16);
        folder.quadTo(2.5, 16, 2.5, 15);
        p.drawPath(folder);
        p.drawLine(QPointF(2.5, 8.5), QPointF(17.5, 8.5));
        return done();
    }
    // the rectangle family: sidebar.left, rectangle.split.2x1 / 1x2 / 2x2, each pane filled while it shows
    const QRectF box(2.5, 4.5, 15, 11);
    const bool across = name.startsWith(QLatin1String("splitH")) || name == QLatin1String("splitTop") || name == QLatin1String("splitBottom");
    const bool grid = name.startsWith(QLatin1String("dashboard"));
    QList<QRectF> filled;
    const QRectF left(box.left(), box.top(), box.width() / 2, box.height()), right = left.translated(box.width() / 2, 0);
    const QRectF top(box.left(), box.top(), box.width(), box.height() / 2), bottom = top.translated(0, box.height() / 2);
    if (name.endsWith(QLatin1String("Filled")))
        filled << box;
    else if (name == QLatin1String("splitLeft"))
        filled << left;
    else if (name == QLatin1String("splitRight"))
        filled << right;
    else if (name == QLatin1String("splitTop"))
        filled << top;
    else if (name == QLatin1String("splitBottom"))
        filled << bottom;
    QPainterPath shape;
    shape.addRoundedRect(box, 2.5, 2.5);
    for (const QRectF &f : std::as_const(filled)) {
        p.save();
        p.setClipRect(f);
        p.fillPath(shape, color);
        p.restore();
    }
    p.drawPath(shape);
    if (!filled.isEmpty()) // the divider cut out of a filled pane
        p.setCompositionMode(QPainter::CompositionMode_Clear);
    if (name == QLatin1String("sidebar"))
        p.drawLine(QPointF(7.5, 4.5), QPointF(7.5, 15.5));
    if (name.startsWith(QLatin1String("split")) && !across)
        p.drawLine(QPointF(10, box.top() + (filled.isEmpty() ? 0 : 1.5)), QPointF(10, box.bottom() - (filled.isEmpty() ? 0 : 1.5)));
    if (across || grid)
        p.drawLine(QPointF(box.left() + (filled.isEmpty() ? 0 : 1.5), 10), QPointF(box.right() - (filled.isEmpty() ? 0 : 1.5), 10));
    if (grid)
        p.drawLine(QPointF(10, box.top() + (filled.isEmpty() ? 0 : 1.5)), QPointF(10, box.bottom() - (filled.isEmpty() ? 0 : 1.5)));
    return done();
}

SidebarDelegate::SidebarDelegate(Sidebar *sidebar)
    : QStyledItemDelegate(sidebar), m_sidebar(sidebar)
{
}

namespace {
QColor faded(QColor c, qreal alpha)
{
    c.setAlphaF(c.alphaF() * alpha);
    return c;
}

// how far an info line lifts into the plain row's bottom padding, by density
qreal infoLift(const Settings &st)
{
    return st.sidebarDensity == QLatin1String("compact") ? 4 : 6;
}

// one line of styled spans from the top of `at`, the last one that does not fit elided. A colour stays on a
// selected row, as a row tint does; plain text follows the row's text colour.
void drawInfo(QPainter *p, const QList<InfoSpan> &spans, const QRectF &at, const QFont &rowFont, const QColor &text, bool selected)
{
    const QFont base = Sidebar::infoFont(rowFont);
    const qreal height = QFontMetricsF(base).height();
    qreal x = at.left();
    for (const InfoSpan &span : spans) {
        QFont f = span.code ? QFontDatabase::systemFont(QFontDatabase::FixedFont) : base;
        f.setPointSizeF(base.pointSizeF());
        f.setBold(span.bold);
        f.setItalic(span.italic);
        const QFontMetricsF fm(f);
        const qreal room = at.right() - x;
        if (room <= fm.averageCharWidth())
            break;
        const QString shown = fm.elidedText(span.text, Qt::ElideRight, room);
        QColor c = span.color.isEmpty() ? text : tintColor(span.color);
        c.setAlphaF(!span.color.isEmpty() ? (span.dim ? 0.55 : 1) : selected ? (span.dim ? 0.6 : 0.85) : span.dim ? 0.38 : span.bold ? 1 : 0.58);
        p->setFont(f);
        p->setPen(c);
        p->drawText(QRectF(x, at.top(), room, height), Qt::AlignVCenter | Qt::AlignLeft, shown);
        x += fm.horizontalAdvance(shown);
        if (shown != span.text)
            break;
    }
}

// elis's metrics: the pill's inset into the row, and where icons and names start inside it
constexpr qreal pillInset = 10, chevronX = 8, iconBox = 16, iconGap = 8;
}

void SidebarDelegate::paint(QPainter *p, const QStyleOptionViewItem &opt, const QModelIndex &index) const
{
    // QApplication's palette, not opt.palette: a stylesheet background would make the view's palette transparent
    const QPalette pal = QApplication::palette();
    const QColor text = pal.color(QPalette::WindowText);
    const QColor dim = faded(text, 0.65);
    p->save();
    p->setRenderHint(QPainter::Antialiasing);
    const bool session = index.data(Kind).toInt() == SessionRow;
    const bool assistant = index.data(Kind).toInt() == AssistantRow;
    const bool flat = m_sidebar->flatList();
    const bool selected = opt.state & QStyle::State_Selected;
    const Sidebar::Edge edge = m_sidebar->groupEdge(index);
    const QRectF r = Sidebar::pillRect(m_sidebar->contentRect(index, opt.rect), flat);
    // a tint colours its row's icon and name; a workspace's draws the group's band, a session's a wash
    const QColor tint = tintColor(index.data(TintColor).toString());
    const QColor band = edge == Sidebar::NoEdge ? QColor() : tintColor((session ? index.parent() : index).data(TintColor).toString());
    const QColor iconColor = tint.isValid() ? tint : faded(text, selected ? 0.85 : 0.58);
    const QColor nameColor = tint.isValid() ? tint : text;

    if (band.isValid()) {
        // one rounded outline across the group: each row's piece runs past the edges the group continues over, clipped to the row
        const QRectF row(opt.rect);
        const qreal top = edge == Sidebar::First || edge == Sidebar::Single ? row.top() + Sidebar::groupGap : row.top() - 13;
        const qreal bottom = edge == Sidebar::Last || edge == Sidebar::Single ? row.bottom() - Sidebar::groupGap : row.bottom() + 13;
        const QRectF shape(r.left() - Sidebar::groupPadding, top, r.width() + 2 * Sidebar::groupPadding, bottom - top);
        p->save();
        p->setClipRect(opt.rect);
        p->setPen(QPen(faded(band, 0.16), 1));
        p->setBrush(faded(band, 0.10));
        p->drawRoundedRect(shape.adjusted(0.5, 0.5, -0.5, -0.5), 10.5, 10.5);
        p->restore();
    }
    // a session row's fills are square; only a band's last row rounds its bottom corners, concentric with the band
    const auto shape = [&](const QRectF &rect, qreal radius) {
        QPainterPath path;
        path.setFillRule(Qt::WindingFill);
        if (!session || (band.isValid() && edge == Sidebar::Last)) {
            path.addRoundedRect(rect, radius, radius);
            if (session)
                path.addRect(rect.adjusted(0, 0, 0, -rect.height() / 2));
        } else {
            path.addRect(rect);
        }
        return path.simplified(); // one outline, so a stroke does not trace the seam between the two shapes
    };
    p->setPen(Qt::NoPen);
    if (session && tint.isValid()) {
        p->setBrush(faded(tint, 0.09));
        p->drawPath(shape(r, 8));
    }
    // Elis stands alone at a group card's size, so its edges and the gap under it match the cards below
    const qreal pad = assistant ? Sidebar::groupPadding : 0;
    const QRectF fill = r.adjusted(-pad, -pad, pad, pad);
    if (selected) {
        // the group's tint, else the row's own, else the accent; dimmer while the window is in the background
        const QColor c = band.isValid() ? band : tint.isValid() ? tint : pal.color(QPalette::Highlight);
        const bool key = m_sidebar->isActiveWindow();
        p->setPen(QPen(faded(c, key ? 0.55 : 0.35), 1));
        p->setBrush(faded(c, key ? 0.20 : 0.12));
        p->drawPath(shape(fill.adjusted(0.5, 0.5, -0.5, -0.5), assistant ? 10.5 : 7.5));
    } else if (opt.state & QStyle::State_MouseOver) {
        p->setBrush(faded(text, 0.07));
        p->drawPath(shape(fill, assistant ? 10.5 : 8));
    }

    if (session && index.data(Status).toString() == QLatin1String("active")) {
        // in progress: the row's tint (else the active colour) drifts across it with a second hue, one period every two row widths
        const QColor active = statusColor(m_sidebar->settings(), QStringLiteral("active"));
        const QColor base = tint.isValid() ? tint : active, second = tint.isValid() ? active : pal.color(QPalette::Highlight);
        auto alpha = [](QColor c, int a) { return c.setAlpha(a), c; };
        const qreal period = 2 * r.width(), x0 = r.left() - m_sidebar->auroraPhase() * period;
        QLinearGradient g(x0, 0, x0 + period, 0);
        g.setSpread(QGradient::RepeatSpread);
        g.setColorAt(0, alpha(base, 10));
        g.setColorAt(0.25, alpha(base, 51));
        g.setColorAt(0.55, alpha(second, 41));
        g.setColorAt(1, alpha(base, 10));
        p->setPen(Qt::NoPen);
        p->setBrush(g);
        p->drawPath(shape(r, 8));
    }

    qreal x = r.left() + chevronX;
    const QRect title = m_sidebar->titleRect(index, opt.rect);
    const qreal cy = QRectF(title).center().y();
    QFont font = opt.font;
    if (assistant) {
        static const QImage dog = QImage(QStringLiteral(":/elis.png")).scaled(64, 64, Qt::KeepAspectRatio, Qt::SmoothTransformation);
        p->setRenderHint(QPainter::SmoothPixmapTransform);
        p->drawImage(QRectF(x - 1, cy - 9, 18, 18), dog);
        x += 18 + iconGap;
        font.setWeight(QFont::DemiBold);
    } else if (!session) {
        QPainterPath chevron;
        if (index.data(Expanded).toBool()) {
            chevron.moveTo(x + 1, cy - 1.8);
            chevron.lineTo(x + 4.5, cy + 1.8);
            chevron.lineTo(x + 8, cy - 1.8);
        } else {
            chevron.moveTo(x + 2.7, cy - 3.5);
            chevron.lineTo(x + 6.3, cy);
            chevron.lineTo(x + 2.7, cy + 3.5);
        }
        p->setPen(QPen(dim, 1.4, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
        p->drawPath(chevron);
        x += 14;
        if (m_sidebar->settings().shows(QStringLiteral("workspaceIcons"))) {
            const bool focused = index.data(Focused).toBool();
            drawGlyph(p, QRectF(x, cy - iconBox / 2, iconBox, iconBox), focused ? QStringLiteral("workspace-stack-focused") : QStringLiteral("workspace-stack"),
                      iconColor);
            x += iconBox + iconGap;
        } else {
            x += 4;
        }
        font.setWeight(QFont::DemiBold);
    } else {
        x += flat ? 0 : 14; // under the workspace's icon
        if (index.data(Companion).toBool() && !flat)
            x += 18; // indented under its parent
        if (index.data(HasCompanions).toBool() && !flat) {
            // the parent's own disclosure chevron folds its companions away
            QPainterPath chevron;
            const qreal cx = x - 9;
            if (index.data(Expanded).toBool()) {
                chevron.moveTo(cx - 3.5, cy - 1.8);
                chevron.lineTo(cx, cy + 1.8);
                chevron.lineTo(cx + 3.5, cy - 1.8);
            } else {
                chevron.moveTo(cx - 1.8, cy - 3.5);
                chevron.lineTo(cx + 1.8, cy);
                chevron.lineTo(cx - 1.8, cy + 3.5);
            }
            p->setPen(QPen(dim, 1.4, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
            p->setBrush(Qt::NoBrush);
            p->drawPath(chevron);
            if (index.data(FoldedAttention).toBool()) {
                p->setPen(Qt::NoPen);
                p->setBrush(statusColor(m_sidebar->settings(), QStringLiteral("blocked")));
                p->drawEllipse(QPointF(x + 15, cy - 6), 3, 3); // a hidden companion needs you
            }
        }
        if (m_sidebar->settings().shows(QStringLiteral("sessionIcons"))) {
            const QRectF box(x, cy - iconBox / 2, iconBox, iconBox);
            if (const QString split = index.data(Split).toString(); !split.isEmpty())
                p->drawPixmap(box.toRect(), chromeIcon(split, iconColor).pixmap(int(iconBox))); // a split session shows its panes
            else
                drawLauncher(p, box, index.data(Agent).toString(), iconColor);
            x += iconBox + iconGap;
        }
    }

    qreal right = r.right() - 8;
    // hover-only: the launcher menu "+" and, left of it, a repeat of the last choice
    const bool buttons = !session && !assistant && m_sidebar->hovered() == index && m_sidebar->settings().shows(QStringLiteral("workspaceAddSession"));
    const QRect content = title;
    // a collapsed workspace rolls up its sessions' status and badge, as master does; an open one leaves them to its rows
    if (session || (!buttons && !index.data(Expanded).toBool())) {
        const QString status = index.data(Status).toString();
        if (session && m_sidebar->hovered() == index && m_sidebar->closable(index)) {
            // hover-only: a finished session's glyph turns into its close button
            const QPointF c = QRectF(Sidebar::closeButtonRect(content)).center();
            p->setPen(QPen(dim, 1.4, Qt::SolidLine, Qt::RoundCap));
            p->drawLine(c + QPointF(-4, -4), c + QPointF(4, 4));
            p->drawLine(c + QPointF(-4, 4), c + QPointF(4, -4));
            right -= 20;
        } else if (status != QLatin1String("idle")) {
            paintStatus(p, m_sidebar->settings(), status, index.data(Blink).toBool(), m_sidebar->blinkAlpha(), QPointF(right - 6, cy));
            right -= 20;
        }
        if (const int unseen = index.data(Unseen).toInt(); unseen > 0 && m_sidebar->settings().notificationBadgeEnabled) {
            QFont f = opt.font;
            f.setPointSizeF(f.pointSizeF() * 0.8);
            f.setWeight(QFont::DemiBold);
            const QString n = unseen > 99 ? QStringLiteral("99+") : QString::number(unseen);
            const qreal w = qMax<qreal>(18, QFontMetricsF(f).horizontalAdvance(n) + 10);
            const QRectF pill(right - w, cy - 9, w, 18);
            p->setPen(Qt::NoPen);
            p->setBrush(QColor(0xFF, 0x45, 0x3A)); // the system red of elis's count badge
            p->drawRoundedRect(pill, 9, 9);
            p->setPen(Qt::white);
            p->setFont(f);
            p->drawText(pill, Qt::AlignCenter, n);
            right -= w + 6;
        }
    } else if (buttons) {
        const QRect add = Sidebar::addButtonRect(content), rep = Sidebar::repeatButtonRect(content);
        p->setPen(QPen(dim, 1.4, Qt::SolidLine, Qt::RoundCap));
        const QPointF c = QRectF(add).center();
        p->drawLine(QPointF(c.x() - 5, c.y()), QPointF(c.x() + 5, c.y()));
        p->drawLine(QPointF(c.x(), c.y() - 5), QPointF(c.x(), c.y() + 5));
        drawLauncher(p, QRectF(rep).adjusted(3, 3, -3, -3), m_sidebar->lastLauncher(), dim);
        right = rep.left() - 4;
    }

    // the tree marks a flagged session after its name, in the flag's indigo; the flagged view lists only flagged ones
    const bool flagMark = session && !m_sidebar->flaggedView() && index.data(Flagged).toBool();
    const qreal flagRoom = flagMark ? 17 : 0;
    const QFontMetricsF fm(font);
    p->setPen(nameColor);
    p->setFont(font);
    const QRectF label(x, title.top(), right - x - flagRoom, title.height());
    const QString suffix = index.data(WorkspaceLabel).toString().isEmpty() ? QString() : QStringLiteral(" : ") + index.data(WorkspaceLabel).toString();
    const QString name = fm.elidedText(index.data(Qt::DisplayRole).toString(), Qt::ElideRight, label.width());
    p->drawText(label, Qt::AlignVCenter | Qt::AlignLeft, name);
    qreal end = x + fm.horizontalAdvance(name);
    if (!suffix.isEmpty()) { // flat layout: "session : workspace", the workspace part dimmed
        p->setPen(dim);
        const QRectF rest = label.adjusted(fm.horizontalAdvance(name), 0, 0, 0);
        const QString tail = fm.elidedText(suffix, Qt::ElideRight, rest.width());
        p->drawText(rest, Qt::AlignVCenter | Qt::AlignLeft, tail);
        end += fm.horizontalAdvance(tail);
    }
    if (flagMark) {
        const bool dark = pal.color(QPalette::Window).lightness() < 128;
        drawGlyph(p, QRectF(end + 6, cy - 5.5, 11, 11), QStringLiteral("flag-lucide"), QColor(dark ? 0x5E5CE6 : 0x5856D6)); // systemIndigo
    }
    if (const QList<InfoSpan> *spans = m_sidebar->shownInfo(index))
        drawInfo(p, *spans, QRectF(x, title.bottom() + 1 - infoLift(m_sidebar->settings()), r.right() - 8 - x, 0), opt.font, text, selected);
    p->restore();
}

QSize SidebarDelegate::sizeHint(const QStyleOptionViewItem &opt, const QModelIndex &index) const
{
    const QMargins extras = Sidebar::edgeExtras(m_sidebar->groupEdge(index));
    // an info line lifts into the plain row's bottom padding and is padded by as much under it: the row grows by one line
    const int info = m_sidebar->shownInfo(index) ? QFontMetrics(Sidebar::infoFont(opt.font)).height() : 0;
    return QSize(200, m_sidebar->titleHeight(opt.fontMetrics) + info + extras.top() + extras.bottom());
}

void SidebarDelegate::updateEditorGeometry(QWidget *editor, const QStyleOptionViewItem &opt, const QModelIndex &index) const
{
    // where paint() puts the name
    const Settings &st = m_sidebar->settings();
    const bool session = index.data(Kind).toInt() == SessionRow, flat = m_sidebar->flatList();
    const QRectF pill = Sidebar::pillRect(m_sidebar->contentRect(index, opt.rect), flat);
    qreal x = pill.left() + chevronX + (session ? (flat ? 0 : 14) + (index.data(Companion).toBool() && !flat ? 18 : 0) : 14);
    x += st.shows(session ? QStringLiteral("sessionIcons") : QStringLiteral("workspaceIcons")) ? iconBox + iconGap : session ? 0 : 4;
    editor->setGeometry(QRectF(x - 4, pill.top() + 2, pill.right() - x, pill.height() - 4).toRect());
}

void SidebarDelegate::setEditorData(QWidget *editor, const QModelIndex &index) const
{
    auto *line = qobject_cast<QLineEdit *>(editor);
    line->setText(index.data(Qt::DisplayRole).toString());
    line->selectAll();
}

Sidebar::Sidebar(Store &store, QWidget *parent)
    : QTreeWidget(parent), m_store(store)
{
    Q_INIT_RESOURCE(resources); // the logos live in a static library, which the linker would otherwise drop
    setHeaderHidden(true);
    setRootIsDecorated(false);
    setIndentation(0);
    setItemDelegate(new SidebarDelegate(this));
    setMouseTracking(true);
    setFrameShape(QFrame::NoFrame);
    setExpandsOnDoubleClick(false);
    setEditTriggers(NoEditTriggers);
    setSelectionMode(ExtendedSelection);
    setContextMenuPolicy(Qt::CustomContextMenu);
    setFocusPolicy(Qt::NoFocus); // the keyboard stays in the terminal
    setVerticalScrollMode(ScrollPerPixel);
    setAnimated(false); // a style (Breeze) may animate expansion, which a rebuild would replay
    setDragEnabled(true);
    setAcceptDrops(true);
    setDropIndicatorShown(false);
    setDragDropMode(DragDrop);
    viewport()->setAcceptDrops(true);
    viewport()->setAttribute(Qt::WA_Hover);

    connect(this, &QTreeWidget::itemChanged, this, [this](QTreeWidgetItem *item) {
        if (m_rebuilding)
            return;
        const bool isSession = item->data(0, Kind).toInt() == SessionRow;
        Q_EMIT renameRequested(isSession ? QStringLiteral("session") : QStringLiteral("workspace"), item->data(0, Id).toString(),
                               item->text(0));
    });
    m_blinkTimer.setInterval(33);
    connect(&m_blinkTimer, &QTimer::timeout, this, [this] {
        // master's glyph: opacity 1.0 -> 0.2 over 0.5 s, autoreversed (a 1 s cycle)
        m_blinkPhase = (m_blinkPhase + 1) % 30;
        m_blinkAlpha = 51 + int(204 * (0.5 + 0.5 * qCos(m_blinkPhase * M_PI / 15)));
        m_auroraPhase = std::fmod(m_auroraPhase + 33.0 / 4800, 1.0); // a 4.8 s drift
        viewport()->update();
    });
}

void Sidebar::setAssistantSelected(bool on)
{
    if (on == m_assistantSelected)
        return;
    m_assistantSelected = on;
    rebuild();
}

QString Sidebar::lastLauncher() const
{
    return m_store.settings.lastLauncher;
}

const Settings &Sidebar::settings() const
{
    return m_store.settings;
}

Sidebar::Edge Sidebar::groupEdge(const QModelIndex &index) const
{
    if (flatList() || !index.isValid())
        return NoEdge;
    if (index.data(Kind).toInt() == AssistantRow)
        return Single;
    if (index.data(Kind).toInt() == WorkspaceRow)
        return isExpanded(index) && model()->rowCount(index) > 0 ? First : Single;
    return index.row() == model()->rowCount(index.parent()) - 1 ? Last : Middle;
}

QMargins Sidebar::edgeExtras(Edge edge)
{
    const int outer = groupGap + groupPadding;
    return QMargins(0, edge == First || edge == Single ? outer : 0, 0, edge == Last || edge == Single ? outer : 0);
}

QRect Sidebar::contentRect(const QModelIndex &index, const QRect &row) const
{
    return row.marginsRemoved(edgeExtras(groupEdge(index)));
}

const QList<InfoSpan> *Sidebar::shownInfo(const QModelIndex &index) const
{
    if (index.data(Kind).toInt() != SessionRow || index.data(Info).toString().isEmpty())
        return nullptr;
    const ::Session *s = m_store.session(index.data(Id).toString());
    return s && !s->infoSpans.isEmpty() ? &s->infoSpans : nullptr;
}

int Sidebar::titleHeight(const QFontMetrics &fm) const
{
    return fm.height() + (settings().sidebarDensity == QLatin1String("compact") ? 8 : 16);
}

QFont Sidebar::infoFont(const QFont &rowFont)
{
    QFont f = rowFont;
    f.setPointSizeF(qMax(7.0, rowFont.pointSizeF() - 1.5));
    return f;
}

QRect Sidebar::titleRect(const QModelIndex &index, const QRect &row) const
{
    QRect content = contentRect(index, row);
    if (shownInfo(index))
        content.setHeight(titleHeight(QFontMetrics(font())));
    return content;
}

QRectF Sidebar::pillRect(const QRect &content, bool flat)
{
    const qreal x = flat ? 6 : 10;
    return QRectF(content).adjusted(x, 0.5, -x, -0.5);
}

QRect Sidebar::addButtonRect(const QRect &row)
{
    return QRect(row.right() - 38, row.center().y() - 11, 22, 22);
}

QRect Sidebar::closeButtonRect(const QRect &row)
{
    return QRect(row.right() - 35, row.center().y() - 11, 22, 22); // centred on the status glyph it replaces
}

QRect Sidebar::repeatButtonRect(const QRect &row)
{
    return QRect(row.right() - 66, row.center().y() - 11, 22, 22);
}

void Sidebar::setFlaggedView(bool on)
{
    m_store.flaggedView = on;
    rebuild();
}

bool Sidebar::flaggedView() const
{
    return m_store.flaggedView;
}

bool Sidebar::flatList() const
{
    return m_store.flaggedView && m_store.settings.flaggedViewLayout != QLatin1String("tree");
}

QStringList Sidebar::selectedSessionIds() const
{
    QStringList ids;
    for (auto *item : selectedItems())
        if (item->data(0, Kind).toInt() == SessionRow)
            ids << item->data(0, Id).toString();
    return ids;
}

QStringList Sidebar::structure() const
{
    // the rows and their order; anything else about a row is updated in place
    QStringList rows{m_store.flaggedView ? QStringLiteral("flagged:") + m_store.settings.flaggedViewLayout : QStringLiteral("tree")};
    for (const auto &w : m_store.workspaces) {
        if (m_store.flaggedView) {
            QStringList flagged;
            for (const auto &s : w.sessions)
                if (s.flagged)
                    flagged << s.id;
            if (!flatList() && !flagged.isEmpty()) // the tree layout leaves out workspaces holding nothing flagged
                rows << QLatin1Char('w') + w.id;
            rows << flagged;
            continue;
        }
        if (m_store.focusEnabled && !m_store.focused.contains(w.id))
            continue;
        rows << QLatin1Char('w') + w.id;
        for (const auto &s : w.sessions)
            if (s.parentId.isEmpty() || !m_store.collapsed.contains(s.parentId)) // a folded companion has no row
                rows << s.id;
    }
    return rows;
}

void Sidebar::rebuild()
{
    if (state() == EditingState)
        return; // a rename in progress keeps its row; the commit rebuilds
    m_rebuilding = true;
    const int scroll = verticalScrollBar()->value();
    // a multi-selection survives a rebuild only while it still contains the current session
    QStringList keepSelected = selectedSessionIds();
    if (!keepSelected.contains(m_store.selected))
        keepSelected.clear();
    // recreating the items on every change (a selection, a status) flickers and replays the expand animation
    const QStringList rows = structure();
    const bool reuse = rows == m_structure;
    m_structure = rows;
    if (!reuse) {
        setUpdatesEnabled(false);
        clear();
    }
    int top = 0;
    auto topItem = [&] { return reuse ? topLevelItem(top++) : new QTreeWidgetItem(this); };
    bool animating = false; // a blinking glyph or an active row's aurora
    auto sessionItem = [&](QTreeWidgetItem *item, const ::Session &s) {
        item->setText(0, s.displayName());
        item->setData(0, Id, s.id);
        item->setData(0, Kind, SessionRow);
        item->setData(0, Status, s.status);
        item->setData(0, Blink, s.blink);
        item->setData(0, Agent, s.agent);
        item->setData(0, Flagged, s.flagged);
        item->setData(0, Unseen, s.unseen);
        item->setData(0, Busy, s.busy);
        item->setData(0, TintColor, s.tint.color);
        // what the info line shows; set only where Settings shows it, so the row's height follows
        const QString display = m_store.settings.sessionInfoDisplay;
        const bool showsInfo = display == QLatin1String("always") || (display == QLatin1String("flagged") && m_store.flaggedView);
        QString info; // the spans as a key, so a changed line re-asks the row's height
        for (const InfoSpan &span : s.infoSpans)
            info += span.text + QChar(span.bold | span.italic << 1 | span.code << 2 | span.dim << 3) + span.color + QChar(0);
        item->setData(0, Info, showsInfo ? info : QString());
        item->setData(0, Split, !s.hasSplit ? QString() : s.splitAxis == QLatin1String("horizontal") ? QStringLiteral("splitH") : QStringLiteral("split"));
        item->setToolTip(0, s.title.isEmpty() ? s.cwd : s.title + QLatin1Char('\n') + s.cwd);
        item->setFlags(Qt::ItemIsEnabled | Qt::ItemIsSelectable | Qt::ItemIsEditable | Qt::ItemIsDragEnabled);
        animating |= s.blink || s.status == QLatin1String("active");
        if (s.id == m_store.selected)
            setCurrentItem(item, 0, QItemSelectionModel::NoUpdate);
        item->setSelected(s.id == m_store.selected || keepSelected.contains(s.id));
    };
    {
        QTreeWidgetItem *elis = topItem();
        const QJsonObject node = AssistantBridge::stamp({}, QJsonArray(), QJsonValue::Null).value("assistant").toObject(); // app-wide
        elis->setText(0, QStringLiteral("Elis"));
        elis->setData(0, Kind, AssistantRow);
        elis->setData(0, Unseen, node.value("unread").toInt());
        elis->setData(0, Status, node.value("running").toBool() ? QStringLiteral("active") : QStringLiteral("idle"));
        elis->setFlags(Qt::ItemIsEnabled | Qt::ItemIsSelectable);
        if (m_assistantSelected)
            setCurrentItem(elis, 0, QItemSelectionModel::NoUpdate);
        elis->setSelected(m_assistantSelected);
    }
    for (const auto &w : m_store.workspaces) {
        if (flatList()) {
            for (const auto &s : w.sessions)
                if (s.flagged) {
                    QTreeWidgetItem *item = topItem();
                    sessionItem(item, s);
                    item->setData(0, WorkspaceLabel, m_store.settings.flaggedViewLayout == QLatin1String("plain") ? QString() : w.name);
                }
            continue;
        }
        const bool flaggedTree = m_store.flaggedView;
        if (flaggedTree && std::none_of(w.sessions.begin(), w.sessions.end(), [](const ::Session &s) { return s.flagged; }))
            continue;
        if (!flaggedTree && m_store.focusEnabled && !m_store.focused.contains(w.id))
            continue;
        QTreeWidgetItem *wi = topItem();
        int child = 0;
        // the most urgent rendered child's status (blocked > active > completed), the first on a tie
        const ::Session *urgent = nullptr;
        int unseen = 0;
        for (const auto &s : w.sessions)
            if (!flaggedTree || s.flagged) {
                unseen += s.unseen;
                if (s.status != QLatin1String("idle") && (!urgent || attentionRank(s.status) < attentionRank(urgent->status)))
                    urgent = &s;
            }
        wi->setData(0, Status, urgent ? urgent->status : QStringLiteral("idle"));
        wi->setData(0, Blink, urgent && urgent->blink);
        wi->setData(0, Unseen, unseen);
        wi->setText(0, w.name);
        wi->setData(0, Focused, m_store.focused.contains(w.id));
        wi->setData(0, Id, w.id);
        wi->setData(0, Kind, WorkspaceRow);
        wi->setData(0, TintColor, w.tint.color);
        wi->setToolTip(0, w.folder);
        wi->setFlags(Qt::ItemIsEnabled | Qt::ItemIsEditable | Qt::ItemIsDragEnabled | Qt::ItemIsDropEnabled);
        for (const auto &s : w.sessions) {
            if (flaggedTree ? !s.flagged : !s.parentId.isEmpty() && m_store.collapsed.contains(s.parentId))
                continue; // not flagged, or folded under its parent
            QTreeWidgetItem *item = reuse ? wi->child(child++) : new QTreeWidgetItem(wi);
            sessionItem(item, s);
            item->setData(0, Companion, !s.parentId.isEmpty());
            bool hasCompanions = false, attention = false;
            for (const auto &c : w.sessions)
                if (c.parentId == s.id) {
                    hasCompanions = true;
                    attention |= c.unseen > 0 || c.status == QLatin1String("blocked") || c.status == QLatin1String("completed");
                }
            item->setData(0, HasCompanions, hasCompanions && !flaggedTree); // the flagged tree lists companions on their own
            item->setData(0, Expanded, !m_store.collapsed.contains(s.id));
            item->setData(0, FoldedAttention, attention && m_store.collapsed.contains(s.id));
        }
        wi->setExpanded(!m_store.collapsed.contains(w.id) || m_store.isSoleFocus(w.id)); // a zoomed-to workspace is always open
        wi->setData(0, Expanded, wi->isExpanded());
    }
    if (!reuse) {
        verticalScrollBar()->setValue(scroll);
        setUpdatesEnabled(true);
    }
    viewport()->update();
    // start() on a running timer restarts it, so rebuilds faster than the interval would freeze the fade
    if (!animating)
        m_blinkTimer.stop(), m_blinkAlpha = 255;
    else if (!m_blinkTimer.isActive())
        m_blinkTimer.start();
    m_rebuilding = false;
}

void Sidebar::drawRow(QPainter *painter, const QStyleOptionViewItem &option, const QModelIndex &index) const
{
    // the base drawRow is what normally adds per-row selection and hover state
    QStyleOptionViewItem o = option;
    o.state.setFlag(QStyle::State_Selected, selectionModel()->isSelected(index));
    o.state.setFlag(QStyle::State_MouseOver, index == m_hovered);
    itemDelegateForIndex(index)->paint(painter, o, index);
}

void Sidebar::mouseMoveEvent(QMouseEvent *event)
{
    const QModelIndex at = indexAt(event->position().toPoint());
    if (at != m_hovered) {
        m_hovered = at;
        viewport()->update();
    }
    if (!m_pressedId.isEmpty()) { // a pressed, not yet shown row: dragging it leaves the shown terminal as the drop target
        if ((event->position().toPoint() - m_pressPos).manhattanLength() >= QApplication::startDragDistance())
            startDrag(Qt::MoveAction);
        return;
    }
    QTreeWidget::mouseMoveEvent(event);
}

void Sidebar::mouseReleaseEvent(QMouseEvent *event)
{
    if (const QString id = std::exchange(m_pressedId, {}); !id.isEmpty()) {
        const bool ci = std::exchange(m_pressedCi, false);
        if (QTreeWidgetItem *item = itemAt(event->position().toPoint()); item && item->data(0, Id).toString() == id) {
            if (ci)
                Q_EMIT ciPanelRequested(id, event->globalPosition().toPoint());
            else
                setCurrentItem(item); // a click without a drag shows the session, on release
        }
        return;
    }
    QTreeWidget::mouseReleaseEvent(event);
}

void Sidebar::leaveEvent(QEvent *event)
{
    m_hovered = {};
    viewport()->update();
    QTreeWidget::leaveEvent(event);
}

void Sidebar::mousePressEvent(QMouseEvent *event)
{
    const QPoint pos = event->position().toPoint();
    QTreeWidgetItem *item = itemAt(pos);
    if (!item && m_store.flaggedView && topLevelItemCount() == 1 && event->button() == Qt::LeftButton)
        return Q_EMIT editFlaggedRequested(); // only the Elis row: the empty flagged view's link
    if (!item)
        return; // a click on empty space would clear the selection; the shown session always stays selected
    if (item->data(0, Kind).toInt() == AssistantRow) {
        if (event->button() == Qt::LeftButton)
            Q_EMIT assistantRequested();
        return; // no rename, drag or multi-selection
    }
    if (item && item->data(0, HasCompanions).toBool() && !m_store.flaggedView && event->button() == Qt::LeftButton
        && pos.x() < visualItemRect(item).left() + 34) {
        const QString id = item->data(0, Id).toString(); // the parent's chevron folds its companions
        m_store.collapsed.contains(id) ? m_store.collapsed.remove(id) : (m_store.collapsed.insert(id), true);
        rebuild();
        return;
    }
    if (isCloseButton(item, pos) && event->button() == Qt::LeftButton)
        return Q_EMIT closeRequested(item->data(0, Id).toString());
    if (item && item->data(0, Kind).toInt() == WorkspaceRow && event->button() == Qt::LeftButton) {
        const QRect row = titleRect(indexFromItem(item), visualItemRect(item));
        const QString id = item->data(0, Id).toString();
        const bool buttons = m_store.settings.shows(QStringLiteral("workspaceAddSession"));
        if (buttons && addButtonRect(row).contains(pos)) {
            Q_EMIT launcherMenuRequested(id, viewport()->mapToGlobal(addButtonRect(row).bottomLeft() + QPoint(0, 4)));
            return;
        }
        if (buttons && repeatButtonRect(row).contains(pos)) {
            Q_EMIT repeatRequested(id);
            return;
        }
        // a click on the row folds or unfolds it, as elis's default does; with that off only the chevron does
        if (!m_store.settings.workspaceRowClickExpands && pos.x() > row.left() + 28)
            return QTreeWidget::mousePressEvent(event);
        m_store.collapsed.contains(id) ? m_store.collapsed.remove(id) : (m_store.collapsed.insert(id), true);
        item->setExpanded(!m_store.collapsed.contains(id));
        item->setData(0, Expanded, item->isExpanded());
    }
    // a press on the shown session's CI line opens its panel on release; on any other row it selects, so the line never steals a selection
    const QModelIndex index = indexFromItem(item);
    const bool ci = item == currentItem() && shownInfo(index) && pos.y() > titleRect(index, visualItemRect(item)).bottom() + 1 - infoLift(m_store.settings);
    // a plain press on another session selects on release, so a drag of it doesn't switch the terminal away first
    if (item->data(0, Kind).toInt() == SessionRow && (item != currentItem() || ci) && event->button() == Qt::LeftButton
        && !(event->modifiers() & (Qt::ControlModifier | Qt::ShiftModifier))) {
        m_pressedId = item->data(0, Id).toString();
        m_pressedCi = ci;
        m_pressPos = pos;
        return;
    }
    QTreeWidget::mousePressEvent(event);
}

bool Sidebar::isCloseButton(QTreeWidgetItem *item, const QPoint &pos) const
{
    return item && item->data(0, Kind).toInt() == SessionRow && closable(indexFromItem(item))
        && closeButtonRect(titleRect(indexFromItem(item), visualItemRect(item))).contains(pos);
}

// the close X shows only on a quiet row: no attention mark, and no plain command running (an agent's own status speaks for it)
bool Sidebar::closable(const QModelIndex &i) const
{
    const QString status = i.data(Status).toString();
    if (status == QLatin1String("active") || status == QLatin1String("blocked") || i.data(FoldedAttention).toBool()
        || (i.data(Unseen).toInt() > 0 && settings().notificationBadgeEnabled))
        return false;
    return !i.data(Agent).toString().isEmpty() || !i.data(Busy).toBool();
}

QItemSelectionModel::SelectionFlags Sidebar::selectionCommand(const QModelIndex &index, const QEvent *event) const
{
    // the shown session always stays selected: a workspace row or a Ctrl-click on it would deselect it
    const QItemSelectionModel::SelectionFlags command = QTreeWidget::selectionCommand(index, event);
    if (!(index.flags() & Qt::ItemIsSelectable)
        || (index.data(Id).toString() == m_store.selected && command & (QItemSelectionModel::Toggle | QItemSelectionModel::Deselect)))
        return QItemSelectionModel::NoUpdate;
    return command;
}

void Sidebar::mouseDoubleClickEvent(QMouseEvent *event)
{
    if (QTreeWidgetItem *item = itemAt(event->position().toPoint())) {
        if (item->data(0, Kind).toInt() == WorkspaceRow && (addButtonRect(titleRect(indexFromItem(item), visualItemRect(item))).contains(event->position().toPoint())
                                                         || repeatButtonRect(titleRect(indexFromItem(item), visualItemRect(item))).contains(event->position().toPoint())))
            return;
        if (isCloseButton(item, event->position().toPoint()))
            return;
        editItem(item); // inline rename, as in elis
        return;
    }
    QTreeWidget::mouseDoubleClickEvent(event);
}

QMimeData *Sidebar::dragMime(const QString &pressed) const
{
    auto *mime = new QMimeData;
    QTreeWidgetItem *item = pressed.isEmpty() ? currentItem() : nullptr;
    if (item && item->data(0, Kind).toInt() == WorkspaceRow)
        mime->setData(workspaceMime, item->data(0, Id).toString().toUtf8());
    else if (const QStringList ids = pressed.isEmpty() || selectedSessionIds().contains(pressed) ? selectedSessionIds() : QStringList{pressed};
             !ids.isEmpty()) {
        mime->setData(sessionsMime, ids.join(QLatin1Char(',')).toUtf8());
        mime->setText(ids.join(QLatin1Char(','))); // dropped on a terminal, types the Elis ids, as on the Mac
    } else
        return delete mime, nullptr;
    return mime;
}

void Sidebar::startDrag(Qt::DropActions)
{
    QMimeData *mime = dragMime(std::exchange(m_pressedId, {}));
    if (!mime)
        return;
    auto *drag = new QDrag(this);
    drag->setMimeData(mime);
    drag->exec(Qt::MoveAction);
    m_dropLine = {};
    viewport()->update();
}

Sidebar::Drop Sidebar::dropTarget(const QPoint &pos, bool workspaceDrag) const
{
    Drop d;
    QTreeWidgetItem *item = itemAt(pos);
    const int w = viewport()->width();
    if (workspaceDrag) {
        if (!item) {
            d.workspaceIndex = -1;
            d.line = QRect(8, visualItemRect(topLevelItem(topLevelItemCount() - 1)).bottom(), w - 16, 2);
            return d;
        }
        QTreeWidgetItem *top = item->parent() ? item->parent() : item;
        const QRect r = visualItemRect(top);
        const bool after = item->parent() || pos.y() > r.center().y() || top->data(0, Kind).toInt() == AssistantRow; // nothing goes above Elis
        d.workspaceIndex = indexOfTopLevelItem(top) - 1 + (after ? 1 : 0); // less the Elis row
        const QRect edge = after && top->isExpanded() && top->childCount() ? visualItemRect(top->child(top->childCount() - 1)) : r;
        d.line = QRect(8, after ? edge.bottom() : r.top(), w - 16, 2);
        return d;
    }
    if (!item) {
        if (m_store.flaggedView || !topLevelItemCount())
            return d;
        QTreeWidgetItem *last = topLevelItem(topLevelItemCount() - 1);
        d.workspaceId = last->data(0, Id).toString();
        return d;
    }
    if (item->data(0, Kind).toInt() == WorkspaceRow) {
        d.workspaceId = item->data(0, Id).toString();
        d.index = pos.y() > visualItemRect(item).center().y() ? 0 : -1;
        d.line = d.index == 0 ? QRect(28, visualItemRect(item).bottom(), w - 36, 2) : QRect();
        return d;
    }
    const QString sid = item->data(0, Id).toString();
    auto *ws = const_cast<Store &>(m_store).workspaceOf(sid);
    if (!ws)
        return d;
    int idx = 0;
    while (ws->sessions[idx].id != sid)
        ++idx;
    const QRect r = visualItemRect(item);
    const bool after = pos.y() > r.center().y();
    d.workspaceId = ws->id;
    d.index = idx + (after ? 1 : 0);
    d.line = QRect(28, after ? r.bottom() : r.top(), w - 36, 2);
    return d;
}

static QStringList localDirs(const QMimeData *mime)
{
    QStringList dirs;
    for (const QUrl &u : mime->urls())
        if (u.isLocalFile() && QFileInfo(u.toLocalFile()).isDir() && dirs.size() < 20)
            dirs << u.toLocalFile();
    return dirs;
}

void Sidebar::dragEnterEvent(QDragEnterEvent *event)
{
    if (event->mimeData()->hasFormat(sessionsMime) || event->mimeData()->hasFormat(workspaceMime) || !localDirs(event->mimeData()).isEmpty())
        event->acceptProposedAction();
    else
        event->ignore();
}

void Sidebar::dragMoveEvent(QDragMoveEvent *event)
{
    const bool internal = event->mimeData()->hasFormat(sessionsMime) || event->mimeData()->hasFormat(workspaceMime);
    if (!internal && localDirs(event->mimeData()).isEmpty())
        return event->ignore();
    const Drop d = dropTarget(event->position().toPoint(), event->mimeData()->hasFormat(workspaceMime));
    m_dropLine = internal ? d.line : QRect();
    if (QTreeWidgetItem *item = itemAt(event->position().toPoint());
        item && item->data(0, Kind).toInt() == WorkspaceRow && !item->isExpanded() && !event->mimeData()->hasFormat(workspaceMime))
        item->setExpanded(true); // a collapsed workspace springs open under a drag
    viewport()->update();
    event->acceptProposedAction();
}

void Sidebar::dragLeaveEvent(QDragLeaveEvent *event)
{
    m_dropLine = {};
    viewport()->update();
    QTreeWidget::dragLeaveEvent(event);
}

void Sidebar::dropEvent(QDropEvent *event)
{
    m_dropLine = {};
    const QMimeData *mime = event->mimeData();
    const QPoint pos = event->position().toPoint();
    if (mime->hasFormat(workspaceMime)) {
        m_store.moveWorkspace(QString::fromUtf8(mime->data(workspaceMime)), dropTarget(pos, true).workspaceIndex);
    } else if (mime->hasFormat(sessionsMime)) {
        Drop d = dropTarget(pos, false);
        if (d.workspaceId.isEmpty())
            return event->ignore();
        for (const QString &id : QString::fromUtf8(mime->data(sessionsMime)).split(QLatin1Char(','))) {
            m_store.moveSession(id, d.workspaceId, d.index);
            if (d.index >= 0)
                ++d.index; // a batch keeps its order
        }
    } else {
        QString ws;
        if (QTreeWidgetItem *item = itemAt(pos))
            ws = (item->parent() ? item->parent() : item)->data(0, Id).toString();
        Q_EMIT foldersDropped(ws, localDirs(mime));
    }
    event->setDropAction(Qt::IgnoreAction); // the store moved the rows; don't let the view move items too
    event->accept();
    rebuild();
}

void Sidebar::paintEvent(QPaintEvent *event)
{
    QTreeWidget::paintEvent(event);
    if (m_store.flaggedView && topLevelItemCount() == 1) { // only the Elis row
        QPainter p(viewport());
        p.setPen(palette().color(QPalette::PlaceholderText));
        const QRect r = viewport()->rect().adjusted(12, visualItemRect(topLevelItem(0)).bottom() + 24, -12, 0);
        p.drawText(r, Qt::AlignHCenter | Qt::AlignTop, tr("No flagged sessions"));
        p.setPen(palette().color(QPalette::Link));
        p.drawText(r.adjusted(0, fontMetrics().height() + 6, 0, 0), Qt::AlignHCenter | Qt::AlignTop, tr("Edit Flagged Sessions…"));
    }
    if (m_dropLine.isNull())
        return;
    QPainter p(viewport());
    p.setRenderHint(QPainter::Antialiasing);
    p.setPen(Qt::NoPen);
    p.setBrush(QApplication::palette().color(QPalette::Highlight));
    p.drawRoundedRect(m_dropLine, 1, 1);
}
