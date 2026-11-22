#include "cipanel.h"

#include "ci.h"
#include "sidebar.h"
#include "store.h"

#include <QApplication>
#include <QDesktopServices>
#include <QFrame>
#include <QJsonArray>
#include <QLabel>
#include <QThreadPool>
#include <QUrl>
#include <QVBoxLayout>

CiLine::CiLine(Store &store, Sidebar *sidebar, QObject *parent)
    : QObject(parent), m_store(store), m_sidebar(sidebar)
{
    m_timer.setInterval(5000);
    connect(&m_timer, &QTimer::timeout, this, &CiLine::poll);
    m_timer.start();
    QTimer::singleShot(0, this, &CiLine::poll);
    connect(sidebar, &Sidebar::ciPanelRequested, this, &CiLine::showPanel);
    connect(&m_store, &Store::changed, this, &CiLine::closeStalePanel);
}

void CiLine::poll()
{
    if (m_polling)
        return;
    // Off polls nothing and Flagged only what the flagged view can show, as on the Mac
    const QString display = m_store.settings.sessionInfoDisplay;
    QStringList ids, cwds;
    for (Session *s : m_store.allSessions()) {
        if (display == QLatin1String("always") || (display == QLatin1String("flagged") && s->flagged))
            ids << s->id, cwds << s->cwd;
        else
            m_store.setCi(s->id, {}, {});
    }
    m_polling = true;
    QThreadPool::globalInstance()->start([self = QPointer(this), ids, cwds] {
        const QList<CiStatus> statuses = ciStatuses(cwds);
        QMetaObject::invokeMethod(qApp, [self, ids, statuses] {
            if (!self)
                return;
            self->m_polling = false;
            for (int i = 0; i < ids.size(); ++i)
                self->m_store.setCi(ids[i], statuses[i].ci, statuses[i].spans);
        }, Qt::QueuedConnection);
    });
}

void CiLine::closeStalePanel()
{
    const Session *s = m_store.session(m_panelId);
    if (m_panel && (!s || s->ci.isEmpty()))
        m_panel->close(); // a line that went takes its panel with it
}

namespace {
QString glyph(const QString &state)
{
    return state == QLatin1String("failed") ? QStringLiteral("✗") : state == QLatin1String("running") ? QStringLiteral("◷")
         : state == QLatin1String("passed") ? QStringLiteral("✓") : QStringLiteral("–");
}

QString colorOf(const QString &state)
{
    return state == QLatin1String("failed") ? QStringLiteral("red") : state == QLatin1String("running") ? QStringLiteral("yellow")
         : state == QLatin1String("passed") ? QStringLiteral("green") : QString();
}

QString link(const QString &url, const QString &text)
{
    return QStringLiteral("<a href=\"%1\" style=\"text-decoration:none\">%2</a>").arg(url.toHtmlEscaped(), text.toHtmlEscaped());
}
}

void CiLine::showPanel(const QString &sessionId, const QPoint &globalPos)
{
    const Session *s = m_store.session(sessionId);
    if (!s || s->ci.isEmpty())
        return;
    if (m_panel)
        m_panel->close();
    auto *panel = new QFrame(m_sidebar, Qt::Popup); // Wayland shows no popup without a transient parent
    panel->setAttribute(Qt::WA_DeleteOnClose);
    panel->setFrameShape(QFrame::StyledPanel);
    auto *box = new QVBoxLayout(panel);
    box->setContentsMargins(12, 12, 12, 12);
    box->setSpacing(6);
    auto add = [panel, box](const QString &html, bool heading = false, bool dim = false) {
        auto *label = new QLabel(html, panel);
        label->setTextFormat(Qt::RichText);
        QFont f = label->font();
        f.setBold(heading);
        label->setFont(f);
        if (dim)
            label->setEnabled(false);
        // a link opens its GitHub page and the panel closes, as on the Mac
        QObject::connect(label, &QLabel::linkActivated, panel, [panel](const QString &url) {
            // close first: on Wayland openUrl waits for an activation token from the focused window, which the
            // closing panel never delivers; with the panel gone it launches the browser at once
            panel->close();
            if (QUrl(url).scheme() == QLatin1String("https"))
                QDesktopServices::openUrl(QUrl(url));
        });
        box->addWidget(label);
    };
    const QJsonObject ci = s->ci;
    if (const QJsonObject pr = ci.value("pr").toObject(); !pr.isEmpty()) {
        add(link(pr.value("url").toString(), QStringLiteral("#%1 %2").arg(pr.value("number").toInt()).arg(pr.value("title").toString())), true);
        QStringList approved, changes;
        for (const QJsonValue &v : pr.value("approved").toArray())
            approved << v.toString();
        for (const QJsonValue &v : pr.value("changesRequested").toArray())
            changes << v.toString();
        if (approved.isEmpty() && changes.isEmpty())
            add(tr("No reviews yet").toHtmlEscaped(), false, true);
        if (!approved.isEmpty())
            add(tr("Approved: %1").arg(approved.join(QStringLiteral(", "))).toHtmlEscaped());
        if (!changes.isEmpty())
            add(tr("Changes requested: %1").arg(changes.join(QStringLiteral(", "))).toHtmlEscaped());
    } else {
        add(QStringLiteral("%1 · %2").arg(ci.value("branch").toString(), ci.value("sha").toString().left(7)).toHtmlEscaped(), true);
    }
    const QList<std::pair<QString, QString>> groups{{QStringLiteral("failed"), tr("Failed")}, {QStringLiteral("running"), tr("Running")},
                                                    {QStringLiteral("passed"), tr("Passed")}, {QStringLiteral("skipped"), tr("Skipped")}};
    for (const auto &[state, title] : groups) {
        QStringList rows;
        for (const QJsonValue &v : ci.value("runs").toArray()) {
            const QJsonObject run = v.toObject();
            if (run.value("state").toString() != state)
                continue;
            const QString color = colorOf(state);
            const QString mark = color.isEmpty() ? glyph(state)
                                                 : QStringLiteral("<span style=\"color:%1\">%2</span>").arg(tintColor(color).name(), glyph(state));
            rows << mark + QStringLiteral("&nbsp;") + link(run.value("url").toString(), run.value("workflow").toString());
        }
        if (rows.isEmpty())
            continue;
        add(title.toHtmlEscaped(), false, true);
        for (const QString &row : rows)
            add(row);
    }
    panel->adjustSize();
    panel->move(globalPos + QPoint(8, 8));
    panel->show();
    m_panel = panel;
    m_panelId = sessionId;
}
