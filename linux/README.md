# Elis

A terminal for Linux/KDE organised as named workspaces of sessions, with a control API so coding agents and scripts
can drive it and report whether they are working, blocked, or done.

Elis is a Qt6/KDE Frameworks 6 port of [agterm](https://github.com/umputun/agterm) by
[@umputun](https://github.com/umputun), a native macOS terminal. It tracks our macOS fork,
[NaikSoftware/elis](https://github.com/NaikSoftware/elis), which adds the file panel, agent logos and launchers,
remembered workspace folders and more on top of upstream. It follows Elis's model, keys (translated to Linux
conventions), config files, agent-status hooks and `elisctl` wire protocol, so agents and scripts written for Elis
work here. It is an independent project: report bugs here, not upstream. Not ported yet: markdown, image and text pages,
the page bridge, page sessions and companions, overlay-opened terminal links and remote sessions.

Each terminal is a Konsole KPart, so Konsole's profiles, colour schemes, scrollback, search and copy/paste work as
in Konsole.

![Elis: workspaces of agent sessions with status dots, a split session running Claude Code and tests](docs/images/elis.png)

## Build and install

Needs Qt 6 (Widgets, Network, DBus, Svg), KDE Frameworks 6 (CoreAddons, XmlGui, Config, Notifications, KParts,
SyntaxHighlighting, WindowSystem) and `konsole-kpart`. Install `wl-clipboard` (or `xclip` on X11) too: agents like Claude Code read a pasted image
(Ctrl+V) through `wl-paste`/`xclip`, and without them the paste does nothing, in Elis and plain Konsole alike.
Building also needs Swift 6.3 (the swift.org tarball or `swiftly`) on PATH, or `-DSWIFT=/path/to/swift`: `linux/bridge`
builds the shared `ElisCore` (`shared/ElisCore`) into `libElisBridge.so` with the Swift runtime linked in, so running Elis needs no Swift.
The first build of it takes a few minutes; it installs to `lib/elis` beside the binaries' `bin`.
The Swift `elisctl` helper's phone relay links the system OpenSSL, libsystemd and zlib: building needs `libssl-dev`,
`libsystemd-dev` and `zlib1g-dev`, running it `libssl3` and the `openssl` command, which makes the relay's certificate.
Its Bluetooth link needs BlueZ (`bluetoothd`) and an adapter that can advertise.
Page overlays (`session overlay open --html|--url`) need Qt WebEngine (`qt6-webengine-dev`); a build without it refuses
them, and `-DELIS_WEBENGINE=OFF` leaves it out even when it is installed.
Live sessions run under the Mac's patched zmx, which the build makes from source with zig 0.16, git and `shasum`
(`macos/scripts/setup.sh --zmx-only`, network on the first build) and installs it to `libexec/elis`, off PATH. Unpack
[zig 0.16.0](https://ziglang.org/download/) into `~/.local/opt`, where configure finds it, or pass `-DZIG=/path/to/zig`;
the build patches that zig's `float.h` once, as the Mac build does.

```sh
cd linux
sudo apt install libssl-dev libsystemd-dev zlib1g-dev
sudo apt install libkf6parts-dev   # or, without root: scripts/fetch-kparts-headers.sh
cmake -S . -B build -DCMAKE_INSTALL_PREFIX=~/.local   # the menu entry gets an absolute Exec
cmake --build build -j
ctest --test-dir build              # core, file panel, offscreen UI tests
scripts/smoke.sh                    # end-to-end over the control socket
cmake --install build && kbuildsycoca6 --noincremental
```

## What it does

- Workspaces of sessions in a sidebar. A workspace remembers the folder its sessions last worked in (or pins a project
  folder with `workspace folder set DIR` / `workspace new --folder DIR` so `session new --cwd` under it routes there),
  and new sessions open there. Its "+" (on hover) starts Terminal, Claude Code, Codex, OpenCode or Antigravity (whichever
  your login shell finds), and the button beside it repeats the last choice.
- A session row shows the logo of the agent running in it, its status dot (active, blocked, completed), an unseen
  notification count, and a filled icon when flagged. Companions sit indented under their parent; Duplicate as
  Companion copies a session's split layout and the program in each pane.
- Tint a session or workspace row (row menu ▸ Tint: the Mac's twelve colours; a `#rrggbb` set with `elisctl` shows as
  Custom). A tint colours the icon and the name; a workspace's draws a band around its sessions, a session's washes
  its row, and both wash the terminal very lightly.
- Rename inline (double-click), multi-select, drag to reorder or move between workspaces, and drop folders from the
  file manager to open sessions there. Drop a session on a terminal to type its Elis session id. The footer has New Session, New Workspace, the workspace filter and the
  flagged view. Mark workspaces with Focus / Add to Focus in their row menu; the grid button applies or suspends
  the filter, and selecting a session outside it suspends it.
- The flagged view is a flat list (with or without workspace names) or a workspace tree (Settings ▸ General); View ▸
  Edit Flagged Sessions… and Edit Focused Workspaces… tick rows on and off.
- Auto-follow (Settings ▸ Agent Status) moves to the oldest blocked session once you have been idle for a chosen time.
- Splits, terminal zoom, full screen.
- Session (Ctrl+P, or the title bar's session pill) and action (Ctrl+Shift+P) palettes and a Ctrl-Tab recent-session
  switcher. The session palette groups one-line rows (agent logo, detail, workspace, status glyph) under Needs you
  (across open windows), Recent and Recently closed (kept across restarts; a Claude Code one resumes its conversation),
  and typing searches all sessions under one Sessions list. A close can be undone for 3 seconds.
- A file panel (the session folder as a tree with file-type icons, a built-in viewer that highlights source code as
  Kate does, clipboard, drag and drop).
- Settings (Ctrl+Shift+,) with Elis's six pages; terminal font, colour scheme and cursor apply to every open
  terminal on top of the Konsole profile. View ▸ Select Theme… previews schemes live (Enter keeps, Esc reverts).
- While an agent's status is active, KDE neither suspends the computer nor blanks and locks the screen on its own (Settings ▸ General, on by
  default, or `elisctl settings keep-awake on|off|toggle`, read back as the tree's `keepAwake`).
- Glass window (Settings ▸ Appearance ▸ Window): background transparency (0–90%) while text stays solid, and KWin's
  blur behind it.
- `keymap.conf` and `hooks.conf` in `~/.config/elis/` (or `$ELIS_STATE_DIR/config`): rebind built-ins, add custom
  shell commands with `{AGT_*}` tokens (Ctrl+Alt+O lists them), and run scripts on control events. Both files start
  as commented references; File ▸ Edit Keymap… / Reload Keymap and the Hooks pair apply them.
- Programs in a pane can raise notifications with OSC 9 or OSC 777 (`printf '\e]9;done\a'`).
- Several windows, each with its own workspaces (File ▸ New Window, Open Window); the ones open at quit come back.
- A dashboard (Ctrl+Alt+Shift+G, the title-bar grid button, or `elisctl dashboard <ids>`) shows up to nine live panes
  side by side, view-only, with each session's name in its status colour; Enter or a click opens one.
- Restore sessions (Settings ▸ General): fresh shells; re-run commands, which records what each pane runs at quit
  and types it into its new shell on the next launch (`restore-denylist.conf` lists programs to leave out); or live
  sessions, where each pane's shell keeps running in a zmx daemon and the next launch reattaches it. A live pane
  led by another zmx client or the phone ("In use on your phone") is covered until a key takes it back.
- Overlays: `elisctl session overlay open <command>` runs a program in a temporary terminal over a session (full,
  floating with `--size-percent`, or one split pane with `--pane`); it closes when the program exits and
  `overlay result` (or `--block`) returns the status. Ctrl+Alt+Shift+J hides and shows them. `session hud` puts a
  passive message panel over a session that stays typable; keymap `--error-hud` commands report failures in one.

## Beyond Elis

What Elis adds on top of Elis and Konsole:

- The file viewer highlights source code with Kate's syntax engine and numbers its lines in a gutter.
- Rows of sessions with an agent at work drift with a soft aurora; a quiet row shows its close button on hover.
- Background tint on rows and terminals (see above).
- Drop a session row on a terminal to type its Elis session id; a click selects on release, so the
  drag leaves the shown terminal in place.
- Smooth, accelerated mouse-wheel scrolling in terminal panes, where Konsole jumps whole lines.
- The dashboard hides the sidebar and file panel while it is open and gives them back on close.
- The agent hooks, skill and `elisctl` link install themselves on the first launch and after each update (below),
  instead of from the Help menu.
- A phone app, Elis Mobile, paired from Settings ▸ Connect a Phone… ([below](#phone-app)).

## Keys

Elis's ⌘ is Ctrl+Shift here (Konsole's convention); ⌘⇧ and ⌘⌃ are Ctrl+Alt+Shift; ⌃ stays Ctrl; ⌥ is Alt.
`keymap.conf` reads Elis's `cmd`/`opt` words by the same table (`cmd` alone = ctrl+shift, `cmd` with another modifier =
ctrl+alt+shift), next to plain `ctrl`, `shift`, `alt` and `super`.

| Key | Action |
| --- | --- |
| Ctrl+Shift+N / Ctrl+Alt+Shift+N | New session / new workspace |
| Ctrl+Alt+N | New window (Elis's ⌥⌘N; its literal mapping is taken by New Workspace) |
| Ctrl+Shift+O | Open directory as a session |
| Ctrl+Shift+W | Close the HUD or the overlay in front, then leave terminal zoom, then close the session |
| Ctrl+Shift+Z | Undo a close within its 3 s grace (Settings can turn the grace off) |
| Ctrl+Alt+Shift+T | Reopen last closed item |
| Ctrl+Shift+= / - / 0 | Terminal font size larger / smaller / reset |
| Ctrl+Shift+D / Ctrl+Alt+Shift+D | Split side by side / top and bottom (again: hide; the other: transpose) |
| Ctrl+Alt+Shift+← / → | Focus left / right pane |
| Ctrl+Alt+Shift+Return | Terminal zoom |
| F11 | Full screen |
| Ctrl+Alt+Shift+S / Ctrl+Alt+Shift+E | Toggle sidebar / file panel |
| Ctrl+Alt+Shift+↑ / ↓ | Previous / next session |
| Ctrl+Alt+↑ / ↓ | Previous / next session needing attention |
| Ctrl+P / Ctrl+Shift+P / Ctrl+Tab | Session palette / action palette / recent sessions |
| Ctrl+Alt+O | Custom-commands palette (Elis's ⌃⇧O; Ctrl+Shift+O is Open Directory here) |
| Ctrl+Alt+Shift+F | Flag session |
| Ctrl+Alt+Shift+J | Hide / show overlays |
| Ctrl+Alt+Shift+G | Dashboard: recent sessions' live panes in a grid (arrows, Enter, Esc) |

## Agent status, skill and CLI

The first launch of an installed Elis, and the first launch after an update or a move to another prefix, installs
three extras in the background (log: `~/.local/share/elis/extras-install.log`). The agent status hooks: the status
package goes to `~/.config/elis/agent-status` and is wired into Claude Code (`~/.claude/settings.json`), Codex
(`~/.codex/config.toml`), Pi, OpenCode, Antigravity CLI (`~/.gemini/config/plugins/elis-status`) and your shell rc files; each file it edits is backed up as `.bak`, and running it
again changes nothing. The agent skill (which teaches Claude Code and Codex to drive Elis) goes into
`~/.claude/skills` and `~/.codex/skills`. `elisctl` is linked into `~/.local/bin` unless one is already there. A
build-tree run installs nothing. By hand: `elis --install agent-hooks|skill|cli|all [--home DIR]`
(`scripts/install-claude-hooks.sh` runs the hooks one).

The hooks run Elis's own status adapter (a no-op outside Elis). Typing into a blocked or completed session
clears its dot (Settings sets on the first key, on Enter, or never).

## Control API

Every pane exports `ELIS_WINDOW_ID`, `ELIS_SESSION_ID`, `ELIS_WORKSPACE_ID`, `ELIS_PANE`, `ELIS_PANE_ID`, `ELIS_SOCKET`
and `ELISCTL`, so
`elisctl` inside a pane addresses its own session. Targets are an id, a unique id prefix, an exact name, or
`active`; `--window` picks a window other than the frontmost. `elisctl --help` lists the commands; the wire format is Elis's (one JSON request line, one response
line) on `<state dir>/elis.sock`. The state dir is `~/.local/share/elis`, or `ELIS_STATE_DIR`.
Beyond sessions and workspaces it streams events (`elisctl events`), shows pickers and questions (`pick`, `ask`),
passes messages between panes (`msg`, addressed by `ELIS_PANE_ID`), drives the pinned Elis assistant chat and sends tagged messages to sessions (`assistant ask|send|read|provider|show|seen|clear`, and `reply` from inside a session), reads a pane's screen or scrollback
(`session text --all`), types into either pane (`session type --pane right`), zooms a pane's font
(`font inc|dec|reset`), attaches a terminal to a Live pane (`session attach [--claim]`), sets a pane's grid apart from its window (`session grid <cols>x<rows>`, `--reset`), and wheels a pane as a mouse
would (`session scroll <lines>`). Commands for features Elis
lacks answer "not supported on this platform".

## Phone app

Elis Mobile ([mobile/](../mobile/README.md), Flutter, Android) watches and drives Elis from a phone, over a relay
on the computer that runs only while you want it.

<p align="center">
  <img src="docs/images/mobile-sessions.png" width="270" alt="Sessions: a blocked agent's question with answer buttons, a finished session, workspaces of agent sessions">
  <img src="docs/images/mobile-new-session.png" width="270" alt="New session: pick Terminal, Claude Code, Codex, OpenCode or Antigravity, a workspace and a folder">
  <img src="docs/images/mobile-session.png" width="270" alt="A Claude Code session fitted to the phone">
</p>

- **Sessions.** The workspace tree with status dots (a working agent's dot pulses, as in the sidebar), agent logos and
  context lines. Needs you leads with the sessions that wait for you: an agent's question shows the screen's tail and
  its options as answer buttons, so a permission prompt is one tap; finished sessions follow. Filters for blocked,
  done and flagged sessions.
- **New session.** Terminal or any agent, in a workspace and folder, quietly or also selected on the computer; a new
  workspace on the way. The row and workspace menus (rename, flag, tint, move, split, companion, close) match the
  sidebar's.
- **A session's screen.** A Live pane as a live terminal while a full-screen program runs, its history otherwise; a key
  bar (esc, tab, ⇧tab, ^C, arrows, paste, …) and a composer, hidden until the session's ⋯ menu shows it; both panes of a split. One finger
  scrolls the program, two fingers zoom and pan, a double tap resets the zoom.
- **Direct input.** The phone takes a Live pane's lead when it opens, resumes or switches to it, and again at its next input after a key on the computer took it back: the program runs at the
  phone's size and takes the phone's keys, while the computer shows the pane as in use on your phone. Leaving the screen
  or a key on the computer returns the lead. A pane that is not Live is typed into through the computer.
- **Fit to phone** is on while a session's screen is open: it gives the program the phone's own grid (`session grid`): as many columns and rows as the phone shows
  at a readable size, so it redraws for the phone and nothing wraps, while the computer's font stays as it was. While
  fitted, dragging the screen scrolls the program itself (wheel notches through `session scroll`), so Claude Code
  scrolls its own transcript. Leaving the screen or sending the app to the background gives the grid back, and coming
  back fits it again; after the computer takes a pane back, it stops fitting until you leave. On the computer, Session ▸ Restore Terminal Size
  (also on the row's right-click menu while it applies) does the same, and is disabled once the window has taken the
  grid back by itself (resized or shown).
- **Alerts in the background.** A notification per session when its agent blocks, finishes or notifies; tapping one
  opens that session.

Settings ▸ Connect a Phone… switches it on: the window shows the QR code to scan in the app, the `elis://pair?…` link
to copy, the address the code points the phone at (pick your LAN or VPN address, or type a name such as the machine's
Tailscale name) and the port, the Bluetooth state (Open Bluetooth Settings while the adapter is powered off), and
Revoke Paired Phones. While switched on, the relay starts with Elis and stops with
it. The same relay runs from a terminal too, while the command runs:

```sh
elisctl mobile serve [--port 8765] [--bind ADDR] [--host NAME] [--no-qr] [--no-bluetooth]
```

It prints the QR code and the link; Ctrl+C stops it. Nothing listens unless one of the two runs.

`elisctl phone status|on|off|toggle|port|host|revoke|link [--qr]` drives the window's relay from a script, as on the Mac; `tree` reports it as `phone`.

- The connection is TLS with a self-signed certificate (made with the `openssl` CLI on the first run, kept in
  `<state dir>/mobile/`); the phone pins its SHA-256 fingerprint from the link, so no CA is involved.
- Each connection must first present the link's 256-bit token (`<state dir>/mobile/token`, mode 0600). Anyone with
  the link controls your terminals: Revoke Paired Phones (or `elisctl mobile reset`) makes a new token and cuts off every phone holding the old
  one at once.
- `serve` listens on all interfaces by default; `--bind` restricts it. It reaches the phone over your LAN or a VPN such
  as Tailscale; `--host` only sets the address written into the link (e.g. the machine's Tailscale name or IP).
- The relay also offers Bluetooth, as the Mac does, so the phone works without Wi-Fi: BlueZ advertises a service UUID that rotates every 15 minutes and the phone opens an LE L2CAP channel,
  encrypted with a key from the pairing token. Its stderr reports `bluetooth: advertising` or `bluetooth: off (<reason>)`;
  `--no-bluetooth` turns it off. One relay per state directory advertises.
- A pane running Claude Code or agy opens in Chat, read from its transcript (`session transcript`).
  Files attached in Chat (up to 10, 20 MiB each) land in `<state dir>/uploads/<session id>/` (`session upload`);
  old uploads are swept at launch (retention: `site/docs.html`).
  A page a Linux session opens shows in the app only, never on the phone.

## Credits and license

The design, the control model and the agent-status adapters come from [agterm](https://github.com/umputun/agterm)
(MIT, © Umputun). Terminal emulation is [Konsole](https://konsole.kde.org)'s KPart. MIT licensed, see [LICENSE](LICENSE).
