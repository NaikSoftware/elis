#include "pageoverlay.h"
#include "elis_bridge.h"
#include "pagecontent.h"
#include "textpage.h"

#include <algorithm>

#include <QApplication>
#include <QClipboard>
#include <QDesktopServices>
#include <QDir>
#include <QDragEnterEvent>
#include <QFile>
#include <QFileInfo>
#include <QHBoxLayout>
#include <QJsonDocument>
#include <QKeyEvent>
#include <QLabel>
#include <QMimeData>
#include <QPushButton>
#include <QShortcut>
#include <QTimer>
#include <QToolButton>
#include <QVBoxLayout>
#include <QWebEngineHistory>
#include <QWebEngineLoadingInfo>
#include <QWebEngineNewWindowRequest>
#include <QWebEnginePage>
#include <QWebEngineProfile>
#include <QWebEngineScript>
#include <QWebEngineScriptCollection>
#include <QWebEngineSettings>
#include <QWebEngineUrlRequestInfo>
#include <QWebEngineUrlRequestInterceptor>
#include <QWebEngineView>
#if QT_VERSION >= QT_VERSION_CHECK(6, 8, 0)
#include <QWebEnginePermission>
#endif

static QJsonObject bridge(char *raw)
{
    const QJsonObject reply = QJsonDocument::fromJson(raw ? QByteArray(raw) : QByteArray()).object();
    elis_free(raw);
    return reply;
}

static QByteArray compact(const QJsonObject &o)
{
    return QJsonDocument(o).toJson(QJsonDocument::Compact);
}

static double s_zoom = 1;
static QList<QPointer<PageOverlay>> s_pages;

// a page Elis builds from a file named by untrusted output, loaded from its own scheme with no file grant or bridge
static bool built(const QString &kind)
{
    return kind == QLatin1String("image") || kind == QLatin1String("markdown") || kind == QLatin1String("text") || kind == QLatin1String("document");
}

// a page Elis shows from a file wears the theme as its default look, the Mac's `styled`
static bool styled(const QString &kind)
{
    return built(kind) ? kind != QLatin1String("image") : kind == QLatin1String("file");
}

// Every navigation the page or the user starts goes to ElisCore's policy; dialogs, file pickers and popups never open.
class PolicyPage : public QWebEnginePage
{
public:
    PolicyPage(QWebEngineProfile *profile, PageOverlay *owner)
        : QWebEnginePage(profile, owner)
        , m_owner(owner)
    {
    }
    bool ownLoad = false; // loadOriginal's own document, which the policy never sees as the page's navigation

protected:
    bool acceptNavigationRequest(const QUrl &url, NavigationType type, bool isMainFrame) override
    {
        // the text a grantless file page shows is a data: document, and a built page's its scheme's root: only
        // loadOriginal and its own history reach them
        const bool own = url.scheme() == QLatin1String("data") || url == PageScheme::url(m_owner->m_pageID);
        if (isMainFrame && own && (ownLoad || type == NavigationTypeReload || type == NavigationTypeBackForward)) {
            ownLoad = false;
            return true;
        }
        ownLoad = false;
        // a redirect keeps the click that started it, as WebKit reuses the triggering action
        const bool clicked = type == NavigationTypeLinkClicked || (type == NavigationTypeRedirect && m_owner->m_clickedLoad);
        const bool allowed = m_owner->decide(url, isMainFrame ? QStringLiteral("mainFrame") : QStringLiteral("subframe"), clicked);
        if (allowed && isMainFrame && type != NavigationTypeRedirect)
            m_owner->m_clickedLoad = clicked;
        return allowed;
    }
    void javaScriptAlert(const QUrl &, const QString &) override {}
    bool javaScriptConfirm(const QUrl &, const QString &) override { return false; }
    bool javaScriptPrompt(const QUrl &, const QString &, const QString &, QString *) override { return false; }
    QStringList chooseFiles(FileSelectionMode, const QStringList &, const QStringList &) override { return {}; }

private:
    PageOverlay *m_owner;
};

// file: reads stay inside a file page's grant; a URL page or a grantless file page reads none
class GrantInterceptor : public QWebEngineUrlRequestInterceptor
{
public:
    GrantInterceptor(const QJsonObject &source, QObject *parent)
        : QWebEngineUrlRequestInterceptor(parent)
        , m_source(source)
    {
    }
    void interceptRequest(QWebEngineUrlRequestInfo &info) override
    {
        // a built page reads nothing but what its scheme answers: a clicked HTML file's links and pictures resolve
        // there, and its policy alone would not stop a prefetch or a link hint
        if (built(m_source.value("kind").toString()))
            return info.block(info.requestUrl().scheme() != QLatin1String("elis-page") && info.requestUrl().scheme() != QLatin1String("data"));
        if (info.requestUrl().scheme() != QLatin1String("file"))
            return;
        const QJsonObject request{{"source", m_source},
                                  {"action", QJsonObject{{"url", info.requestUrl().toString()}, {"target", "subframe"}, {"userActivated", false}}}};
        if (bridge(elis_html_navigation_decide(compact(request).constData())).value("decision").toString() != QLatin1String("allow"))
            info.block(true);
    }

private:
    QJsonObject m_source;
};

PageOverlay::PageOverlay(const QJsonObject &source, const QJsonObject &flags, const QString &pageID, const QJsonObject &theme, QWidget *parent)
    : QWidget(parent)
    , m_source(source)
    , m_flags(flags)
    , m_pageID(pageID)
{
    setObjectName(QStringLiteral("elisPage"));
    s_pages << this;
    m_profile = new QWebEngineProfile(this); // off the record: storage lives exactly as long as the page
    m_profile->setUrlRequestInterceptor(new GrantInterceptor(source, m_profile));
    m_page = new PolicyPage(m_profile, this);
    QWebEngineSettings *settings = m_page->settings();
    settings->setAttribute(QWebEngineSettings::JavascriptEnabled, flags.value("javascript").toBool());
    settings->setAttribute(QWebEngineSettings::JavascriptCanOpenWindows, false);
    settings->setAttribute(QWebEngineSettings::ScreenCaptureEnabled, false);
    connect(m_page, &QWebEnginePage::newWindowRequested, this, [this](QWebEngineNewWindowRequest &request) {
        decide(request.requestedUrl(), QStringLiteral("newWindow"), request.isUserInitiated()); // never opened here
    });
#if QT_VERSION >= QT_VERSION_CHECK(6, 8, 0)
    connect(m_page, &QWebEnginePage::permissionRequested, this, [](QWebEnginePermission permission) { permission.deny(); });
#else
    connect(m_page, &QWebEnginePage::featurePermissionRequested, this, [this](const QUrl &origin, QWebEnginePage::Feature feature) {
        m_page->setFeaturePermission(origin, feature, QWebEnginePage::PermissionDeniedByUser);
    });
#endif
    connect(m_page, &QWebEnginePage::windowCloseRequested, this, [this] {
        QTimer::singleShot(0, this, [this] { Q_EMIT closeRequested(); }); // the page is mid-call
    });

    const bool file = source.value("kind").toString() == QLatin1String("file");
    installTheme(theme);
    // no canvas: the frame paints the theme behind it, so an authored body background still fills the canvas.
    // An opaque colour would not do: under the theme's color-scheme Chromium swaps it for its own dark canvas.
    if (styled(kind()) || kind() == QLatin1String("image"))
        m_page->setBackgroundColor(Qt::transparent);
    if (built(kind())) {
        settings->setAttribute(QWebEngineSettings::DnsPrefetchEnabled, false);
        m_scheme = new PageScheme(pageID, source.value("links").toObject(), m_profile);
        m_profile->installUrlSchemeHandler("elis-page", m_scheme);
        m_textLoaded = !source.contains("links"); // a link page shows real addresses; every other built page its file
    }
    if (kind() == QLatin1String("markdown")) {
        QWebEngineScript renderer;
        renderer.setName(QStringLiteral("elis-markdown"));
        renderer.setSourceCode(markdownAssets().value("script").toString());
        renderer.setInjectionPoint(QWebEngineScript::DocumentReady);
        renderer.setWorldId(QWebEngineScript::ApplicationWorld);
        m_page->scripts().insert(renderer);
    }
    if (kind() == QLatin1String("text")) {
        m_text = new TextPageHost(m_page, source, [this](const QByteArray &html) { showBuilt(html); }, [this](const QString &e) { fail(e); }, this);
        connect(m_text, &TextPageHost::changed, this, &PageOverlay::changed);
        auto *find = new QShortcut(QKeySequence(Qt::CTRL | Qt::Key_F), this, this, [this] {
            m_view->setFocus();
            m_text->focusSearch();
        });
        find->setContext(Qt::WidgetWithChildrenShortcut);
        // the app's find chord too, as Ctrl+Shift+F finds in a terminal
        find = new QShortcut(QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_F), this, this, [this] {
            m_view->setFocus();
            m_text->focusSearch();
        });
        find->setContext(Qt::WidgetWithChildrenShortcut);
    }

    m_view = new QWebEngineView(this);
    m_view->setPage(m_page);
    m_view->setZoomFactor(s_zoom);
    m_view->setAcceptDrops(false);
    setFocusProxy(m_view);

    auto *box = new QVBoxLayout(this);
    box->setContentsMargins({});
    box->setSpacing(0);
    if (!flags.value("chromeless").toBool()) {
        m_strip = new QWidget(this);
        m_strip->setObjectName(QStringLiteral("elisPageStrip"));
        m_strip->setFixedHeight(28);
        m_strip->setAutoFillBackground(true);
        auto *row = new QHBoxLayout(m_strip);
        row->setContentsMargins(8, 0, 2, 0);
        row->setSpacing(6);
        m_identity = new QLabel(m_strip);
        m_identity->setObjectName(QStringLiteral("elisPageIdentity"));
        m_identity->setTextFormat(Qt::PlainText);
        QFont bold = m_identity->font();
        bold.setBold(true);
        m_identity->setFont(bold);
        m_title = new QLabel(m_strip);
        m_title->setObjectName(QStringLiteral("elisPageTitle"));
        m_title->setTextFormat(Qt::PlainText); // the page writes it: never markup
        m_title->setForegroundRole(QPalette::PlaceholderText);
        m_title->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Preferred);
        row->addWidget(m_identity);
        row->addWidget(m_title, 1);
        auto button = [this, row](const QString &name, const QString &icon, const QString &tip, auto slot) {
            auto *b = new QToolButton(m_strip);
            b->setObjectName(name);
            b->setAutoRaise(true);
            b->setIcon(QIcon::fromTheme(icon));
            b->setToolTip(tip);
            b->setFocusPolicy(Qt::NoFocus);
            connect(b, &QToolButton::clicked, this, slot);
            row->addWidget(b);
            return b;
        };
        auto go = [this](const QString &to) {
            return [this, to] {
                QString e;
                navigate(to, &e);
            };
        };
        if (flags.value("navigation").toBool()) {
            m_back = button(QStringLiteral("elisPageBack"), QStringLiteral("go-previous"), tr("Back"), go(QStringLiteral("back")));
            m_forward = button(QStringLiteral("elisPageForward"), QStringLiteral("go-next"), tr("Forward"), go(QStringLiteral("forward")));
            button(QStringLiteral("elisPageReload"), QStringLiteral("view-refresh"), tr("Reload"), [this] { reload(true); });
            if (file || kind() == QLatin1String("url")) // a built page hands nothing on
                button(QStringLiteral("elisPageBrowser"), QStringLiteral("internet-web-browser"), tr("Open in Browser"), go(QStringLiteral("browser")));
            if (file)
                button(QStringLiteral("elisPageFolder"), QStringLiteral("folder-open"), tr("Show in Folder"), go(QStringLiteral("finder")));
            else if (kind() == QLatin1String("url"))
                button(QStringLiteral("elisPageCopy"), QStringLiteral("edit-copy"), tr("Copy Link"),
                       [this] { QApplication::clipboard()->setText(browserUrl().toString()); });
        }
        button(QStringLiteral("elisPageClose"), QStringLiteral("window-close"), tr("Close"), [this] {
            QTimer::singleShot(0, this, [this] { Q_EMIT closeRequested(); }); // the close deletes this button mid-click
        });
        box->addWidget(m_strip);
        auto *rule = new QFrame(this);
        rule->setFrameShape(QFrame::HLine);
        rule->setFixedHeight(1);
        box->addWidget(rule);
    }
    box->addWidget(m_view, 1);

    m_errorPanel = new QWidget(this);
    m_errorPanel->setObjectName(QStringLiteral("elisPageError"));
    m_errorPanel->setAutoFillBackground(true);
    auto *errorBox = new QVBoxLayout(m_errorPanel);
    errorBox->addStretch();
    m_error = new QLabel(m_errorPanel);
    m_error->setTextFormat(Qt::PlainText);
    m_error->setWordWrap(true);
    m_error->setAlignment(Qt::AlignCenter);
    errorBox->addWidget(m_error);
    auto *retry = new QPushButton(tr("Reload"), m_errorPanel);
    connect(retry, &QPushButton::clicked, this, [this] { reload(false); });
    errorBox->addWidget(retry, 0, Qt::AlignHCenter);
    errorBox->addStretch();
    m_errorPanel->hide();

    m_prompt = new QFrame(this);
    m_prompt->setObjectName(QStringLiteral("elisPagePrompt"));
    static_cast<QFrame *>(m_prompt)->setFrameShape(QFrame::StyledPanel);
    m_prompt->setAutoFillBackground(true);
    auto *promptRow = new QHBoxLayout(m_prompt);
    m_promptText = new QLabel(m_prompt);
    m_promptText->setTextFormat(Qt::PlainText);
    m_promptText->setWordWrap(true);
    promptRow->addWidget(m_promptText, 1);
    auto *open = new QPushButton(tr("Open"), m_prompt);
    auto *cancel = new QPushButton(tr("Cancel"), m_prompt);
    cancel->setDefault(true);
    connect(open, &QPushButton::clicked, this, [this] { answerPrompt(true); });
    connect(cancel, &QPushButton::clicked, this, [this] { answerPrompt(false); });
    promptRow->addWidget(cancel);
    promptRow->addWidget(open);
    m_prompt->hide();

    connect(m_page, &QWebEnginePage::loadingChanged, this, [this](const QWebEngineLoadingInfo &info) {
        switch (info.status()) {
        case QWebEngineLoadingInfo::LoadStartedStatus:
            m_loadPending = true;
            m_failed = false;
            m_state = QStringLiteral("loading");
            m_errorText.clear();
            break;
        case QWebEngineLoadingInfo::LoadSucceededStatus:
            m_loadPending = false;
            if (!m_failed) {
                m_state = QStringLiteral("loaded");
                m_shown = m_page->url();
                m_contentShown = true;
            }
            break;
        case QWebEngineLoadingInfo::LoadStoppedStatus:
        case QWebEngineLoadingInfo::LoadFailedStatus:
            m_loadPending = false;
            if (m_failed) // a policy cancel already named its reason
                break;
            if (info.status() == QWebEngineLoadingInfo::LoadStoppedStatus && m_contentShown)
                m_state = QStringLiteral("loaded"); // a cancelled navigation leaves the shown document in place
            else
                fail(info.status() == QWebEngineLoadingInfo::LoadStoppedStatus ? tr("load stopped") : info.errorString());
            break;
        }
        syncStrip();
        Q_EMIT changed();
    });
    connect(m_page, &QWebEnginePage::urlChanged, this, [this] {
        syncStrip();
        Q_EMIT changed();
    });
    connect(m_page, &QWebEnginePage::titleChanged, this, [this] {
        syncStrip();
        Q_EMIT changed();
    });
    m_view->installEventFilter(this);
    if (m_view->focusProxy())
        m_view->focusProxy()->installEventFilter(this);
    connect(m_view, &QWebEngineView::loadStarted, this, [this] { // the render widget comes and goes with the renderer
        if (QWidget *proxy = m_view->focusProxy())
            proxy->installEventFilter(this);
    });
    loadOriginal();
    syncStrip();
}

PageOverlay::~PageOverlay()
{
    s_pages.removeAll(this);
    if (m_text)
        m_text->stop();
    // the page before its profile, which Qt refuses to release while a page still uses it
    m_view->setPage(nullptr);
    delete m_page;
}

void PageOverlay::loadOriginal()
{
    m_loadPending = true;
    m_failed = false;
    m_shown.clear();
    const QString path = m_source.value("path").toString();
    if (built(kind())) { // read and built off the GUI thread, as the Mac's loadBuilt
        const int build = ++m_build;
        if (m_source.contains("links"))
            return m_page->load(PageScheme::url(m_pageID, m_source.value("links").toObject().value("path").toString()));
        if (m_text)
            return m_text->loadDocument(true);
        const QByteArray request = compactJson({{"path", path}, {"style", markdownAssets().value("style")}});
        offThread(
            this,
            [k = kind(), request] {
                return bridgeReply(k == QLatin1String("markdown") ? elis_markdown_page(request.constData())
                                   : k == QLatin1String("image")  ? elis_image_page(request.constData())
                                                                  : elis_document_page(request.constData()));
            },
            [this, build](const QJsonObject &page) {
                if (build == m_build)
                    page.contains("html") ? showBuilt(page.value("html").toString().toUtf8()) : fail(page.value("error").toString());
            });
        return;
    }
    if (m_source.value("kind").toString() == QLatin1String("url")) {
        m_page->load(QUrl(m_source.value("url").toString()));
    } else if (m_source.contains("cwd")) {
        m_page->load(QUrl::fromLocalFile(path)); // its folder reads come through the grant interceptor
    } else {
        // no grant: the text alone, since a file URL would read its whole folder
        QFile f(path);
        if (!f.open(QIODevice::ReadOnly)) {
            fail(tr("cannot read %1").arg(path));
            return;
        }
        const QByteArray html = f.readAll();
        // shortcut: setHtml travels as a data: URL Chromium caps at 2 MB; a custom scheme handler would lift it
        if (html.toPercentEncoding().size() + 32 > 2 * 1024 * 1024) { // 32: the data:text/html;charset=UTF-8, prefix
            fail(tr("%1 is too large to show without --cwd").arg(path));
            return;
        }
        m_textLoaded = true;
        m_page->ownLoad = true;
        m_page->setHtml(QString::fromUtf8(html));
    }
}

void PageOverlay::showBuilt(const QByteArray &html)
{
    m_scheme->setDocument(html);
    m_loadPending = true;
    m_page->ownLoad = true;
    m_page->load(PageScheme::url(m_pageID));
}

void PageOverlay::installTheme(const QJsonObject &theme)
{
    m_theme = theme;
    QJsonObject themed = theme;
    themed.insert("themed", styled(kind()));
    for (const QWebEngineScript &old : m_page->scripts().find(QStringLiteral("elis-theme")))
        m_page->scripts().remove(old);
    QWebEngineScript script;
    script.setName(QStringLiteral("elis-theme"));
    // Chromium runs a document-creation script before the root element exists, which WebKit's has; the shared
    // script prepends to it, so it waits for the root here
    script.setSourceCode(QStringLiteral("(() => { const run = () => { %1 }; if (document.documentElement) run(); else new MutationObserver("
                                        "(_, o) => { if (document.documentElement) { o.disconnect(); run(); } }).observe(document, {childList: true}); })();")
                             .arg(bridge(elis_html_theme_script(compact(themed).constData())).value("script").toString()));
    script.setInjectionPoint(QWebEngineScript::DocumentCreation);
    script.setWorldId(QWebEngineScript::ApplicationWorld);
    m_page->scripts().insert(script);
}

void PageOverlay::applyTheme(const QJsonObject &theme)
{
    if (theme == m_theme)
        return;
    // nothing runs in the live document: script the app evaluates there would hand the page a user gesture
    installTheme(theme);
    if (m_text)
        return m_text->loadDocument(false);
    if (styled(kind()))
        reloadShown();
}

bool PageOverlay::textCommand(const QJsonObject &action, const QString &sessionId, QJsonObject *result, QString *error)
{
    if (m_text)
        return m_text->command(action, sessionId, result, error);
    static const QJsonObject failures = bridge(elis_text_page_constants());
    const QString k = action.value("kind").toString();
    *error = failures.value(k == QLatin1String("follow")                                  ? "notLog"
                            : k == QLatin1String("changes") || k == QLatin1String("files") ? "notDiff"
                                                                                           : "notText")
                 .toString();
    return false;
}

void PageOverlay::showEvent(QShowEvent *event)
{
    if (m_text)
        m_text->setOnScreen(true);
    QWidget::showEvent(event);
}

void PageOverlay::fail(const QString &error)
{
    m_failed = true;
    m_loadPending = false;
    m_state = QStringLiteral("failed");
    m_errorText = error;
    m_error->setText(error);
    syncStrip();
    Q_EMIT changed();
}

bool PageOverlay::decide(const QUrl &url, const QString &target, bool userActivated)
{
    const QJsonObject request{{"source", m_source},
                              {"flags", m_flags},
                              {"id", m_pageID},
                              {"links", m_source.value("links")}, // null without a grant
                              {"action", QJsonObject{{"url", url.toString(QUrl::FullyEncoded)}, {"target", target}, {"userActivated", userActivated}}}};
    QString decision = bridge(elis_html_navigation_decide(compact(request).constData())).value("decision").toString();
    // the policy's link check is lexical; the canonical file is judged here too, since Chromium would replace the shown
    // document with an error page where WebKit keeps it
    if (decision == QLatin1String("allow") && url.scheme() == QLatin1String("elis-page") && m_source.contains("links")
        && bridge(elis_markdown_linked_document(compact({{"path", url.path(QUrl::FullyDecoded)}, {"links", m_source.value("links")}}).constData()))
               .value("path")
               .toString()
               .isEmpty())
        decision = QStringLiteral("cancel");
    if (decision == QLatin1String("openExternal"))
        ask(url);
    if (decision != QLatin1String("allow") && target == QLatin1String("mainFrame") && !userActivated && m_loadPending) {
        m_failed = true; // set now: the abort that follows reports nothing of its own
        QTimer::singleShot(0, this, [this, url] { fail(QStringLiteral("navigation blocked: %1").arg(url.toString(QUrl::FullyEncoded))); });
    }
    return decision == QLatin1String("allow");
}

void PageOverlay::ask(const QUrl &url)
{
    if (m_silenced || !m_promptUrl.isEmpty() || !isVisible())
        return; // one prompt per page; a decline holds until the user next acts in it
    m_promptUrl = url;
    m_promptText->setText(tr("Open %1 in the browser?").arg(url.toString(QUrl::FullyEncoded)));
    const int top = m_strip ? 29 : 0;
    m_prompt->setGeometry(8, top + 8, width() - 16, m_prompt->sizeHint().height());
    m_prompt->show();
    m_prompt->raise();
    for (auto *b : m_prompt->findChildren<QPushButton *>())
        if (b->isDefault())
            b->setFocus();
    Q_EMIT changed();
}

void PageOverlay::answerPrompt(bool open)
{
    const QUrl url = m_promptUrl;
    m_promptUrl.clear();
    m_prompt->hide();
    if (open && !url.isEmpty())
        (openExternally ? openExternally : [](const QUrl &u) { QDesktopServices::openUrl(u); })(url);
    else if (!url.isEmpty())
        m_silenced = true;
    if (isVisible())
        m_view->setFocus();
    Q_EMIT changed();
}

void PageOverlay::hideEvent(QHideEvent *event)
{
    if (m_text)
        m_text->setOnScreen(false); // a log out of sight reads nothing
    if (!m_promptUrl.isEmpty()) { // hiding ends the prompt without opening and without silencing the page
        m_promptUrl.clear();
        m_prompt->hide();
    }
    QWidget::hideEvent(event);
}

static bool carriesFiles(const QMimeData *data)
{
    return data && std::ranges::any_of(data->urls(), &QUrl::isLocalFile);
}

bool PageOverlay::eventFilter(QObject *watched, QEvent *event)
{
    switch (event->type()) {
    case QEvent::KeyPress:
    case QEvent::MouseButtonPress:
        m_silenced = false; // a native input event ends a decline's silence
        if (event->type() == QEvent::KeyPress) {
            auto *key = static_cast<QKeyEvent *>(event);
            if (key->matches(QKeySequence::Paste) && carriesFiles(QApplication::clipboard()->mimeData()))
                return true; // a paste carrying files never reaches the page
        }
        break;
    case QEvent::DragEnter:
    case QEvent::DragMove:
    case QEvent::Drop:
        if (carriesFiles(static_cast<QDropEvent *>(event)->mimeData())) {
            event->ignore();
            return true;
        }
        break;
    case QEvent::Resize:
        if (watched == m_view) {
            m_errorPanel->setGeometry(m_view->geometry());
            if (m_prompt->isVisible())
                m_prompt->setGeometry(8, m_view->y() + 8, width() - 16, m_prompt->sizeHint().height());
        }
        break;
    default:
        break;
    }
    return QWidget::eventFilter(watched, event);
}

QUrl PageOverlay::pageUrl() const
{
    if (m_textLoaded || m_page->url().scheme() == QLatin1String("data") || m_page->url().isEmpty())
        return m_source.value("kind").toString() == QLatin1String("url") ? QUrl(m_source.value("url").toString())
                                                                         : QUrl::fromLocalFile(m_source.value("path").toString());
    if (m_page->url().scheme() == QLatin1String("elis-page")) // a markdown link page's file
        return QUrl::fromLocalFile(m_page->url().path(QUrl::FullyDecoded));
    return m_page->url();
}

QUrl PageOverlay::browserUrl() const
{
    if (kind() != QLatin1String("url"))
        return QUrl::fromLocalFile(m_source.value("path").toString()); // the original file, as the Mac opens it
    const QUrl now = pageUrl();
    return now.scheme().startsWith(QLatin1String("http")) ? now : QUrl(m_source.value("url").toString());
}

QString PageOverlay::identity() const
{
    QJsonObject request{{"source", m_source}, {"flags", m_flags}};
    if (!m_shown.isEmpty() && !m_textLoaded)
        request.insert("page", m_shown.isLocalFile()                          ? m_shown.toLocalFile()
                               : m_shown.scheme() == QLatin1String("elis-page") ? m_shown.path(QUrl::FullyDecoded)
                                                                                : m_shown.toString());
    return bridge(elis_html_identity(compact(request).constData())).value("identity").toString();
}

void PageOverlay::syncStrip()
{
    m_errorPanel->setGeometry(m_view->geometry());
    m_errorPanel->setVisible(m_state == QLatin1String("failed"));
    if (m_errorPanel->isVisible())
        m_errorPanel->raise();
    if (m_prompt->isVisible())
        m_prompt->raise();
    if (!m_strip)
        return;
    m_identity->setText(identity());
    m_title->setText(m_page->title() == m_page->url().toString() || m_textLoaded && m_page->title().startsWith(QLatin1String("data:"))
                         ? QString()
                         : m_page->title());
    if (m_back) {
        m_back->setEnabled(m_page->history()->canGoBack());
        m_forward->setEnabled(m_page->history()->canGoForward());
    }
}

QJsonObject PageOverlay::readBack() const
{
    QJsonObject node;
    const bool file = m_source.value("kind").toString() == QLatin1String("file");
    if (file) {
        node.insert("file", m_source.value("path"));
        if (m_source.contains("cwd"))
            node.insert("cwd", m_source.value("cwd"));
    } else if (m_text) {
        node.insert("text", m_text->readBack());
    } else if (built(kind())) {
        node.insert(kind(), m_source.value("path")); // image | markdown | document
    } else {
        node.insert("url", m_source.value("url"));
    }
    node.insert("state", m_state);
    if (!m_errorText.isEmpty())
        node.insert("error", m_errorText);
    if (!m_page->url().isEmpty()) {
        const QUrl page = pageUrl();
        node.insert("page", page.isLocalFile() ? page.toLocalFile() : page.toString());
        const QString title = m_page->title();
        if (!title.isEmpty() && title != m_page->url().toString() && !title.startsWith(QLatin1String("data:")))
            node.insert("title", title);
        node.insert("canGoBack", m_page->history()->canGoBack());
        node.insert("canGoForward", m_page->history()->canGoForward());
    }
    if (m_flags.value("navigation").toBool())
        node.insert("navigation", true);
    node.insert("javascript", m_flags.value("javascript").toBool());
    node.insert("chromeless", m_flags.value("chromeless").toBool());
    node.insert("persistent", false);
    node.insert("browse", false);
    node.insert("zoom", s_zoom);
    node.insert("id", m_pageID);
    return node;
}

void PageOverlay::reload(bool current)
{
    if (!m_promptUrl.isEmpty())
        answerPrompt(false);
    current ? reloadShown() : loadOriginal();
    syncStrip();
}

void PageOverlay::reloadShown()
{
    // before a first commit there is nothing to reload, so the source is loaded again instead
    if (!m_textLoaded && !m_failed && !m_page->url().isEmpty()) {
        m_loadPending = true;
        m_page->triggerAction(QWebEnginePage::Reload);
    } else {
        loadOriginal();
    }
}

bool PageOverlay::navigate(const QString &to, QString *error)
{
    const bool file = m_source.value("kind").toString() == QLatin1String("file");
    auto open = openExternally ? openExternally : [](const QUrl &u) { QDesktopServices::openUrl(u); };
    if (to == QLatin1String("browser") || to == QLatin1String("finder"))
        if (const QJsonValue refused = bridge(elis_page_navigate_refusal(compact({{"kind", kind()}, {"to", to}}).constData())).value("error"); refused.isString())
            return *error = refused.toString(), false;
    if (to == QLatin1String("back") || to == QLatin1String("forward")) {
        const bool back = to == QLatin1String("back");
        if (!(back ? m_page->history()->canGoBack() : m_page->history()->canGoForward()))
            return *error = QStringLiteral("no page to go %1 to").arg(to), false;
        m_page->triggerAction(back ? QWebEnginePage::Back : QWebEnginePage::Forward);
        return true;
    }
    if (to == QLatin1String("browser")) {
        open(browserUrl());
        return true;
    }
    if (to == QLatin1String("finder")) {
        if (!file)
            return *error = QStringLiteral("show in Finder requires a file page"), false;
        open(QUrl::fromLocalFile(QFileInfo(pageUrl().toLocalFile()).absolutePath()));
        return true;
    }
    return *error = QStringLiteral("session.overlay.navigate requires back, forward, browser or finder"), false;
}

double PageOverlay::zoom()
{
    return s_zoom;
}

void PageOverlay::setZoom(double factor)
{
    s_zoom = factor > 0 ? qBound(0.5, factor, 3.0) : 1;
    for (const QPointer<PageOverlay> &page : std::as_const(s_pages))
        if (page) {
            page->m_view->setZoomFactor(s_zoom);
            Q_EMIT page->zoomChanged(s_zoom);
        }
}

bool PageOverlay::stepZoom(const QString &fontAction)
{
    const QJsonObject reply = bridge(elis_html_zoom(compact({{"action", fontAction}, {"zoom", s_zoom}}).constData()));
    if (!reply.value("zoom").isDouble())
        return false;
    setZoom(reply.value("zoom").toDouble());
    return true;
}
