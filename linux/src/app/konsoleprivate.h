#pragma once

#include <QPoint>
#include <QSize>
#include <QString>

class QObject;
class QWidget;

// Konsole internals the part exposes no API for, reached through libkonsoleprivate's exported symbols.
// Every helper takes a Konsole::Session and degrades to an empty/failed answer when a symbol is missing.
namespace KonsolePrivate {
QObject *emulation(QObject *session);
// the whole history plus the screen, paged through the view (display) and scrolled back; empty on failure
QString scrollback(QObject *session, QWidget *display, bool *ok);
QString selectedText(QObject *session);
// the emulation's grid, columns x rows (what the program sees); invalid when the symbol is missing
QSize gridSize(QObject *session);
// gives the emulation the size its shown views have again (Session::updateTerminalSize); false when the symbol is missing
bool fitToView(QObject *session);
// whether the program in the view asked for mouse reports; *ok is false when the symbol is missing
bool usesMouseTracking(QWidget *display, bool *ok);
// the view's background alpha, 0..1 (Konsole takes it from the colour scheme); -1 when the symbol is missing
double terminalOpacity(QWidget *display);
void setTerminalOpacity(QWidget *display, double opacity);
// Konsole::HotSpot::Type values linkAt reports
enum { File = 1, Link = 2, EMailAddress = 3, EscapedUrl = 5 };
// the link hotspot under a display point (edge as the view's own mouse handlers pass it): its text as printed, with
// *type its HotSpot::Type; empty with *type set for a hotspot whose text cannot be read, *type 0 for none
QString linkAt(QWidget *display, const QPoint &pos, bool edge, int *type);
// turns on the part's file-path links (the profile's Underline files) for this session alone; false when a symbol is missing
bool underlineFiles(QObject *session, QObject *part);
}
