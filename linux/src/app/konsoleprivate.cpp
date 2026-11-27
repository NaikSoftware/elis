#include "konsoleprivate.h"

#include <QAtomicInt>
#include <QHash>
#include <QMetaObject>
#include <QPointer>
#include <QScrollBar>
#include <QSharedPointer>
#include <QSize>
#include <QStringList>
#include <QWidget>

#include <dlfcn.h>

// the plugin loads libkonsoleprivate privately, so symbols are found through the library holding a Konsole meta-object
static void *symbol(const QObject *konsoleObject, const char *mangled)
{
    Dl_info info{};
    if (!konsoleObject || !dladdr(konsoleObject->metaObject(), &info) || !info.dli_fname)
        return nullptr;
    void *lib = dlopen(info.dli_fname, RTLD_NOW | RTLD_NOLOAD);
    void *sym = lib ? dlsym(lib, mangled) : nullptr;
    if (lib)
        dlclose(lib); // NOLOAD only took a reference
    return sym;
}

template<typename F>
static F fn(const QObject *o, const char *mangled)
{
    return reinterpret_cast<F>(symbol(o, mangled));
}

namespace KonsolePrivate {

QObject *emulation(QObject *session)
{
    auto get = fn<QObject *(*)(const QObject *)>(session, "_ZNK7Konsole7Session9emulationEv");
    QObject *e = get ? get(session) : nullptr;
    return e && e->inherits("Konsole::Emulation") ? e : nullptr;
}

// The view's ScreenWindow is parentless and unreachable, so we read through a window of our own on the same emulation;
// the selection lives on the Screen, which every window shares. The emulation deletes its windows.
static QObject *ownWindow(QObject *session)
{
    static QHash<QObject *, QPointer<QObject>> windows;
    if (QPointer<QObject> w = windows.value(session))
        return w;
    QObject *e = emulation(session);
    auto create = fn<QObject *(*)(QObject *)>(e, "_ZN7Konsole9Emulation12createWindowEv");
    QObject *w = create ? create(e) : nullptr;
    windows.insert(session, w);
    return w;
}

QSize gridSize(QObject *session)
{
    QObject *e = emulation(session);
    auto size = fn<QSize (*)(const QObject *)>(e, "_ZNK7Konsole9Emulation9imageSizeEv");
    return size ? size(e) : QSize();
}

bool fitToView(QObject *session)
{
    auto update = fn<void (*)(QObject *)>(session, "_ZN7Konsole7Session18updateTerminalSizeEv");
    if (update)
        update(session);
    return update;
}

QString scrollback(QObject *session, QWidget *display, bool *ok)
{
    // Session::getAllDisplayedText reads the lines the view shows, so paging the view's scrollbar walks the history
    *ok = false;
    QScrollBar *bar = display ? display->findChild<QScrollBar *>() : nullptr;
    if (!bar)
        return {};
    const int was = bar->value(), page = qMax(1, bar->pageStep());
    // the range lags new output until Konsole's next update, and paging refreshes it: a view following the output
    // goes back to the new bottom, or `was` would leave it pinned above it
    const bool following = was == bar->maximum();
    QStringList out;
    for (int top = 0;; top = qMin(top + page, bar->maximum())) {
        bar->setValue(top);
        QStringList lines;
        if (!QMetaObject::invokeMethod(session, "getAllDisplayedTextList", Q_RETURN_ARG(QStringList, lines), Q_ARG(bool, true)))
            break;
        out = out.mid(0, bar->value()) + lines;
        if (top >= bar->maximum()) {
            *ok = true;
            break;
        }
    }
    bar->setValue(following ? bar->maximum() : was);
    // setValue is silent on an unchanged value, and paging can leave output tracking off; Konsole's handler resets it
    QMetaObject::invokeMethod(bar, "scrollBarPositionChanged", Q_ARG(int, bar->value()));
    // the handler's update can grow the range under the view it just placed at the old bottom, and the next read would
    // then take it for a view scrolled up; each setValue runs the handler again
    for (int i = 0; following && i < 3 && bar->value() != bar->maximum(); ++i)
        bar->setValue(bar->maximum());
    return out.join(QLatin1Char('\n'));
}

QString selectedText(QObject *session)
{
    QObject *w = ownWindow(session);
    auto text = fn<QString (*)(const QObject *, int)>(w, "_ZNK7Konsole12ScreenWindow12selectedTextE6QFlagsINS_6Screen14DecodingOptionEE");
    return w && text ? text(w, 0x2 | 0x8) /* PreserveLineBreaks | TrimTrailingWhitespace */ : QString();
}

bool usesMouseTracking(QWidget *display, bool *ok)
{
    auto get = fn<bool (*)(const QObject *)>(display, "_ZNK7Konsole15TerminalDisplay17usesMouseTrackingEv");
    *ok = get && display->inherits("Konsole::TerminalDisplay");
    return *ok && get(display);
}

static QObject *terminalColor(QWidget *display)
{
    if (display)
        for (QObject *c : display->children())
            if (c->inherits("Konsole::TerminalColor"))
                return c;
    return nullptr;
}

double terminalOpacity(QWidget *display)
{
    QObject *c = terminalColor(display);
    auto get = fn<double (*)(const QObject *)>(c, "_ZNK7Konsole13TerminalColor7opacityEv");
    return get ? get(c) : -1;
}

void setTerminalOpacity(QWidget *display, double opacity)
{
    QObject *c = terminalColor(display);
    auto set = fn<void (*)(QObject *, double)>(c, "_ZN7Konsole13TerminalColor10setOpacityEd");
    if (set && !qFuzzyCompare(terminalOpacity(display), opacity)) {
        set(c, opacity);
        display->update();
    }
}

QString linkAt(QWidget *display, const QPoint &pos, bool edge, int *type)
{
    *type = 0;
    if (!display || !display->inherits("Konsole::TerminalDisplay"))
        return {};
    auto process = fn<void (*)(QObject *)>(display, "_ZN7Konsole15TerminalDisplay14processFiltersEv");
    auto chainOf = fn<void *(*)(const QObject *)>(display, "_ZNK7Konsole15TerminalDisplay11filterChainEv");
    auto cell = fn<std::pair<int, int> (*)(const QObject *, const QPoint &, bool)>(display, "_ZNK7Konsole15TerminalDisplay20getCharacterPositionERK6QPointb");
    // QSharedPointer<HotSpot>: HotSpot's first base is QObject, so the pointer and the refcount block match
    auto spotAt = fn<QSharedPointer<QObject> (*)(const void *, int, int)>(display, "_ZNK7Konsole11FilterChain9hotSpotAtEii");
    auto kind = fn<int (*)(const QObject *)>(display, "_ZNK7Konsole7HotSpot4typeEv");
    auto texts = fn<QStringList (*)(const QObject *)>(display, "_ZNK7Konsole19RegExpFilterHotSpot13capturedTextsEv");
    if (!process || !chainOf || !cell || !spotAt || !kind || !texts)
        return {};
    process(display); // the press handler refreshes the hotspots, and this filter runs before it
    const void *chain = chainOf(display);
    const auto [line, column] = cell(display, pos, edge);
    const QSharedPointer<QObject> spot = chain ? spotAt(chain, line, column) : QSharedPointer<QObject>();
    if (!spot)
        return {};
    *type = kind(spot.data());
    // File, Link, EMailAddress come from a regular expression; an escape-sequence link's address has no accessor
    if (*type != File && *type != Link && *type != EMailAddress)
        return {};
    return texts(spot.data()).value(0);
}

bool underlineFiles(QObject *session, QObject *part)
{
    // a Profile::Ptr returned by value: one pointer, and Profile's vtable puts QSharedData's count right after it
    struct ProfilePtr {
        void *d = nullptr;
        ~ProfilePtr() {}
    };
    auto instance = fn<QObject *(*)()>(session, "_ZN7Konsole14SessionManager8instanceEv");
    auto profileOf = fn<ProfilePtr (*)(const QObject *, QObject *)>(session, "_ZNK7Konsole14SessionManager14sessionProfileEPNS_7SessionE");
    auto update = fn<void (*)(QObject *, const ProfilePtr &)>(
        session, "_ZN7Konsole17SessionController16updateFilterListERK28QExplicitlySharedDataPointerINS_7ProfileEE");
    QObject *controller = nullptr;
    for (QObject *o : part ? part->findChildren<QObject *>() : QList<QObject *>())
        if (o->inherits("Konsole::SessionController"))
            controller = o;
    if (!instance || !profileOf || !update || !controller || !instance())
        return false;
    // the session's own override profile, as OSC 50 makes one; the filters are rebuilt only for a profile Konsole saves,
    // so the controller is asked to read them again
    QMetaObject::invokeMethod(session, "profileChangeCommandReceived", Q_ARG(QString, QStringLiteral("UnderlineFilesEnabled=true")));
    ProfilePtr profile = profileOf(instance(), session);
    if (!profile.d)
        return false;
    update(controller, profile);
    // the session manager still holds the profile, so the count never reaches zero here
    reinterpret_cast<QAtomicInt *>(static_cast<char *>(profile.d) + sizeof(void *))->deref();
    return true;
}
}
