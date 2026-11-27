# Mac and Linux desktop parity

What the Linux desktop app (`linux/`, Qt 6 + KDE Frameworks) does differently from the macOS app (`macos/`).
The Mac app is the reference: a behavior not listed here works on Linux as `site/docs.html` describes it.
elis-server and the phone app are out of scope except where the desktop side differs.
`plugins/elis/skills/elis/linux.md` is the agent-facing copy of the CLI differences and must agree with this file;
flags, output fields and error texts live there.

## Platform

| | macOS | Linux |
| --- | --- | --- |
| Terminal | libghostty surface | Konsole KPart |
| Terminal config | `ghostty.conf` (elis-scoped Ghostty config) | the Konsole profile; Settings applies font, colour scheme and cursor on top |
| Themes | Ghostty themes in the theme picker | Konsole colour schemes in View ▸ Select Theme… |
| Keys | ⌘-based | ⌘ is Ctrl+Shift, ⌘⇧ and ⌘⌃ are Ctrl+Alt+Shift; new window is Ctrl+Alt+N, custom commands Ctrl+Alt+O |
| State dir | `~/Library/Application Support/elis` | `~/.local/share/elis` |
| Settings | Elis ▸ Settings | Ctrl+Shift+Comma; the same six pages |
| Phone pairing | Elis ▸ Connect a Phone… | Settings ▸ Connect a Phone…; Bluetooth through BlueZ |
| Attention | Dock badge, bounce and Dock menu | taskbar entry highlight, no Dock menu |
| Keep awake | the display still sleeps and locks | the screen also stays on and unlocked |
| Saved browser store (`--persistent`) | under `~/Library/WebKit`, by the profile id | `<state dir>/QtWebEngine/<id>/<n>`; `browser clear` moves it to the next numbered folder |
| Open links in | Settings ▸ General ▸ Mouse | Settings ▸ General ▸ Sessions |

## Mac only

Commands for these answer `<cmd> is not supported on this platform (<reason>)` on Linux
(`unsupportedReason` in `linux/src/core/commands.cpp`).

- Quick terminal and scratch terminal.
- Remote sessions: attaching another Mac's session, remote windows, elis-server hosts, remote overlay jobs,
  a remote parent's page companion (`session companion page attach`).
- Without Qt WebEngine: every page (overlays, page sessions and companions, link pages) and `browser …`.
  Pages never show on the phone.
- The `zmx …` commands, Reset Live Sessions, `session restart` and `session lead`
  (a covered Live pane takes the lead back with a key).
- Per-session background (`session background`): Konsole takes it from the profile.
- `surface cursor`, `config reload`, `session wait`, `clipboard set`, `terminfo`,
  `session new --wait|--after|--before`, per-call status colour, shape, sound and pane.
- Global hotkey; keymap `--repeat` is parsed and not honoured.
- Settings ▸ Interface elements: Window name, Remote host, Scratch terminal, Quick terminal, Workspace chevrons.
- The `pane.focused`, `pane.scratch` and `remote.*` events are accepted and never fire.

## Linux only

- The Elis assistant (pinned Elis chat, `assistant …`, `reply`, the phone's Ask Elis…). The Mac gets it later.
- `session get`: the session node plus `/proc` process details and the Konsole profile.
- Settings ▸ Interface ▸ File panel toggle.
- Smooth, accelerated mouse-wheel scrolling in panes (Konsole scrolls whole lines).

## Behaves differently

- A terminal-style `ask` is a dialog over the window, not drawn in the pane; `pick` rows show no status glyph.
- `session overlay open` runs the program in a temporary Konsole terminal; `--background-color` tints only the
  floating frame.
- Page overlays need a build with Qt WebEngine and open local pages only (no remote overlay jobs).
  Ctrl+F or Ctrl+Shift+F moves the keys into a text page's search field.
  A markdown link whose file cannot be read once followed fails the page instead of keeping the one shown.
  A file page without `--cwd` whose percent-encoded text passes 2 MB (as little as 700 KB of non-ASCII text) fails
  instead of showing.
- Ctrl+Shift+W closes the HUD or the overlay in front before it leaves terminal zoom, which hides only the chrome
  around them; ⌘W leaves zoom first.
  For the same reason a clicked link opens in its session's page under terminal zoom, where the Mac sends it to the browser.
- Terminal link clicks: a plain click at a prompt opens a web link, and Ctrl+click is ⌘-click; Ctrl+Shift+click is ⌘⇧
  (the browser), Ctrl+Alt+click is ⌘⌥ (reveal), and under mouse capture Ctrl+click and Ctrl+Alt+Shift+click.
  Reveal opens the folder in the file manager without selecting the file. File paths are links whatever the Konsole
  profile's Underline files says; a relative name is a link only once Konsole has seen the pane's folder.
  Escape-sequence (OSC 8) links stay Konsole's and open in the system's handler.
- `session search` drives Konsole's search bar.
- `tree` surfaces carry no per-pane status or `pendingMessages`.
- `msg send --all` reaches the addressed window only.
- Most mutations print nothing rather than `ok`.
- On Wayland `window move` is refused and `window list` omits `x`/`y`.
- `session attach` returns no `origin`.

## Decided differences

The owner chose these; they are not porting gaps.

- No per-part tint placement: Linux has no `--tint-on`, the Mac ignores it, and a tint paints icon, name and
  background on both.
- No Hide overlays button in Settings ▸ Interface on Linux.
