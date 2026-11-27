// Terminal link clicks routed by ElisCore's LinkPolicy: a web link into a session page when Open links in says so,
// a markdown, picture, text or HTML file into its page kind, any other local path revealed. Qt WebEngine only.
#include "mainwindow.h"
#include "elis_bridge.h"
#include "konsoleprivate.h"
#include "pagecontent.h"
#include "pageoverlay.h"
#include "store.h"

#include <KParts/ReadOnlyPart>
#include <kde_terminal_interface.h>

#include <QDesktopServices>
#include <QJsonArray>
#include <QMouseEvent>
#include <QRegularExpression>
#include <QTimer>

// a file route's page and the open check it takes: {source, navigation, log?}; empty for any other route
static QJsonObject fileCheck(const QJsonObject &route)
{
    const QString kind = route.value("route").toString();
    if (!QStringList{"image", "markdown", "text", "document"}.contains(kind))
        return {};
    QJsonObject page{{"kind", kind}, {"path", route.value("path")}};
    if (route.contains("line"))
        page.insert("line", route.value("line"));
    QJsonObject check{{"source", page}, {"navigation", kind == QLatin1String("markdown")}}; // a clicked markdown file asks for its links
    if (route.contains("log"))
        check.insert("log", route.value("log"));
    return check;
}

QString konsoleFileLink(QString text)
{
    // as Konsole's FileFilter and FileFilterHotSpot read it: quotes and a ctest "[" off, then path(123)] or
    // path:123[:45][:text] as path:line[:column], which LinkPolicy splits as libghostty's links
    if (text.size() > 1 && text.startsWith(QLatin1Char('\'')) && text.endsWith(QLatin1Char('\'')))
        text = text.mid(1, text.size() - 2);
    if (text.startsWith(QLatin1String("[/")))
        text.remove(0, 1);
    static const QRegularExpression suffix(QStringLiteral(R"([:\(](\d+)(?:\)\])?(?::(\d+):?|:[^\d]*)?$)"));
    if (const QRegularExpressionMatch m = suffix.match(text); m.hasMatch())
        return text.left(m.capturedStart(0)) + QLatin1Char(':') + m.captured(1) + (m.captured(2).isEmpty() ? QString() : QLatin1Char(':') + m.captured(2));
    if (text.endsWith(QLatin1Char(':')))
        text.chop(1);
    return text;
}

Qt::KeyboardModifiers MainWindow::linkClick(QWidget *display, QMouseEvent *mouse, Qt::KeyboardModifiers effective, bool tracking)
{
    const bool release = mouse->type() == QEvent::MouseButtonRelease;
    // Konsole starts a drag on an Alt press over a link, and Ctrl+Alt is its column selection: the reveal chord keeps neither
    const auto isLink = [](int type) { return type == KonsolePrivate::File || type == KonsolePrivate::Link || type == KonsolePrivate::EMailAddress; };
    if (!release && (effective & Qt::ControlModifier) && (effective & Qt::AltModifier)) {
        int type = 0;
        KonsolePrivate::linkAt(display, mouse->position().toPoint(), !tracking, &type);
        return isLink(type) ? effective & ~Qt::AltModifier : effective;
    }
    if (!release || !(effective & Qt::ControlModifier))
        return effective;
    int type = 0;
    const QString raw = KonsolePrivate::linkAt(display, mouse->position().toPoint(), !tracking, &type);
    if (raw.isEmpty()) // none here, or an escape-sequence link Konsole opens itself
        return effective;
    QString id;
    bool overlay = false;
    KParts::ReadOnlyPart *clicked = partOf(display, &id, &overlay);
    if (!clicked || !m_store.session(id))
        return effective;
    if (QObject *ks = sessionOf(clicked); ks && !KonsolePrivate::selectedText(ks).isEmpty())
        return effective; // Konsole opens nothing over a selection either
    // the folder Konsole matched a relative file name in
    const QString cwd = qobject_cast<TerminalInterface *>(clicked)->currentWorkingDirectory();
    QString link = raw;
    if (type == KonsolePrivate::Link && !link.contains(QLatin1String("://")))
        link.prepend(QLatin1String("https://")); // Konsole's own completion of www.example.com
    else if (type == KonsolePrivate::EMailAddress)
        link.prepend(QLatin1String("mailto:"));
    else if (type == KonsolePrivate::File) {
        link = konsoleFileLink(link);
        // Konsole underlines a relative name only when it is in the pane's folder, as libghostty resolves one
        if (!link.startsWith(QLatin1Char('/')) && !link.startsWith(QLatin1Char('~')))
            link = cwd + QLatin1Char('/') + link;
    }
    QJsonArray mods{QStringLiteral("command")}; // Ctrl plays the Mac's ⌘ for a link
    if (effective & Qt::ShiftModifier)
        mods << QStringLiteral("shift");
    if (effective & Qt::AltModifier)
        mods << QStringLiteral("option");
    const QByteArray request = compactJson({{"raw", link},
                                            {"mode", m_store.settings.linkOpenMode},
                                            {"origin", overlay ? "overlay" : "pane"},
                                            {"session", "00000000-0000-0000-0000-000000000000"}, // a route names no Linux id
                                            {"cwd", overlay ? QString() : cwd},
                                            {"modifiers", mods},
                                            {"captured", tracking}});
    if (type != KonsolePrivate::File) {
        // a web link names no file to stat: routed now, so a link Elis does not follow stays Konsole's
        const QJsonObject route = bridgeReply(elis_link_route(request.constData()));
        if (const QString kind = route.value("route").toString(); kind == QLatin1String("ignore") || kind == QLatin1String("session"))
            return effective;
        QTimer::singleShot(0, this, [this, id, route] { followLink(id, route); });
        return effective & ~Qt::ControlModifier;
    }
    // a file's route stats the files it may name, and its page reads it, so both run off the GUI thread
    offThread(this,
              [request] {
                  QJsonObject route = bridgeReply(elis_link_route(request.constData()));
                  if (const QJsonObject check = fileCheck(route); !check.isEmpty())
                      route.insert("checked", bridgeReply(elis_page_open_check(compactJson(check).constData())));
                  return route;
              },
              [this, id](const QJsonObject &route) { followLink(id, route); });
    return effective & ~Qt::ControlModifier; // Konsole's own open stays out of it
}

bool MainWindow::releaseHiddenClickedPage(const QString &id)
{
    const QString key = id + QStringLiteral("|session");
    const Overlay ov = m_overlays.value(key);
    if (!ov.page || !ov.hidden || !ov.clicked)
        return false;
    closeOverlay(key);
    return true;
}

void MainWindow::followLink(const QString &id, const QJsonObject &route)
{
    auto open = PageOverlay::openExternally ? PageOverlay::openExternally : [](const QUrl &u) { QDesktopServices::openUrl(u); };
    const QString kind = route.value("route").toString(), path = route.value("path").toString();
    const QUrl url(route.value("url").toString());
    auto reveal = [&] { PageOverlay::reveal(path); };
    if (kind == QLatin1String("browser"))
        return open(url);
    if (kind == QLatin1String("reveal"))
        return reveal();
    const bool web = kind == QLatin1String("overlay");
    if (!web && !QStringList{"image", "markdown", "text", "document"}.contains(kind))
        return; // a session link names a Mac's UUID, never a Linux row
    const auto fallback = [&] { web ? open(url) : reveal(); };
    // a HUD the open would close for good
    if (!m_store.session(id) || m_huds.value(id))
        return fallback();
    QJsonObject args{{"clicked", true}};
    if (route.contains("sizePercent"))
        args.insert("sizePercent", route.value("sizePercent"));
    if (web) {
        args.insert("page", QJsonObject{{"kind", "url"}, {"url", url.toString()}});
        for (const char *flag : {"browse", "javascript", "navigation", "persistent"})
            args.insert(QLatin1String(flag), true);
        if (!PageOverlay::persistentStoreFailure().isEmpty())
            return fallback(); // refused before it could replace a hidden page
    } else {
        const QJsonObject check = fileCheck(route);
        args.insert("page", check.value("source"));
        args.insert("navigation", check.value("navigation"));
        if (route.contains("log"))
            args.insert("pageLog", route.value("log"));
        if (!route.value("checked").toObject().value("ok").toBool())
            return fallback();
        args.insert("checked", route.value("checked")); // read on the worker, so openPage does not read the file again
    }
    releaseHiddenClickedPage(id); // after every check that could still refuse, so a refused click keeps the old page
    QJsonObject result;
    QString error;
    if (!openPage(id, {}, args, &result, &error))
        fallback();
}
