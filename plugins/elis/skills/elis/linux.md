<!-- elis-skill -->

# Elis on Linux

The Linux desktop app is Qt 6 and KDE Frameworks with a Konsole terminal per pane.
SKILL.md and reference.md hold for it except where this file says otherwise.
An elis-server host is not this app: SKILL.md's "Remote windows and elis-server" covers it.

## Environment and paths

- There is no `ELIS_ENABLED` and no `TERM_PROGRAM=elis`: `ELIS_SESSION_ID` being set is the test.
- `ELIS_PANE` is `main` or `right`; an overlay's shell gets `overlay`.
- `ELISCTL` is the absolute path of the app's own `elisctl`, and the app prepends its binary directory to the
  pane's `PATH`. If plain `elisctl` reports an unknown command this skill documents, a login profile put an older
  one first: call `"$ELISCTL"`. Add `-u ELISCTL` when scrubbing the variables.
- Socket: `--socket PATH`, else `$ELIS_STATE_DIR/elis.sock`, else `~/.local/share/elis/elis.sock`.
- An installed build links `elisctl` into `~/.local/bin` and installs the status hooks and this skill at its first
  launch and after each update; `elis --install agent-hooks|skill|cli|all` runs them by hand.
- Config is `~/.config/elis/` (or `$ELIS_STATE_DIR/config`): `keymap.conf`, `hooks.conf`, `restore-denylist.conf`.
  There is no Ghostty config: colours, font and scrollback come from the Konsole profile.

## Behaves differently

- `session get` (Linux only) prints the session node plus `pid`, `foreground`, `foregroundPid`, `liveCwd`
  (from `/proc`) and `profile` (the Konsole profile).
- `session|workspace tint` take no `--on`, and `new` takes no `--tint-on` (both deprecated and ignored on the Mac).
- `session search` drives Konsole's search bar and prints the match count.
- `theme list|set` lists and sets Konsole colour schemes.
- `session overlay open` runs the program in a temporary Konsole terminal; `--background-color` tints only the
  floating frame.
- Most mutations print nothing rather than `ok`; create commands still print the new id.
- `tree` carries no pane ids (`surfaces[].paneID`) and no per-pane status: a receiver tells its peers its own
  `$ELIS_PANE_ID`, or senders address a role.
- `msg send --all` reaches the addressed window only.
- A terminal-style `ask` is a dialog over the window, not drawn in the pane; `pick` rows show no status glyph.
- The `pane.focused`, `pane.scratch` and `remote.*` event kinds are accepted and never fire.
- `keymap.conf`: `--repeat` is accepted with a diagnostic and not honoured; `global-hotkey` is skipped.
- On Wayland `window move` is refused and `window list` omits `x`/`y`.
- Live restore keeps each shell in an `elis-session-host` daemon, not zmx.
- The phone: Settings ▸ Connect a Phone…, or `elisctl mobile serve [--port N] [--bind ADDR] [--host NAME]`, which
  runs the relay and prints the pairing QR code and link; `mobile reset` replaces the token. There is no `phone …` command.

## Not supported

These answer `<cmd> is not supported on this platform (<reason>)`:

- quick terminal (`quick …`) and scratch terminal (`session scratch`);
- every `zmx …` command, remote sessions and pane leads (`session lead`), `session restart`;
- `session background`, `surface cursor`, `config reload`;
- the built-in browser (`browser …`), page overlays (`session overlay open --html|--url`,
  `overlay reload|navigate|submit|copy`) and page companions: they need Qt WebEngine.
  There is no inline image, rendered markdown or file-at-line view either: never pass `--image`, `--markdown` or
  `--text` to `overlay open` (`--markdown FILE` would run FILE as the command).
  Show a file by running a viewer as the overlay program (`less +N file`, `glow file`).

Also absent from the CLI: `session wait` (use `events`), `clipboard set` (use `wl-copy`/`xclip`), `terminfo`, `overlay copy`,
`session info` as an activity line, per-call status colour, shape, sound and pane, and
`session new --wait|--after|--before`.

## Keys

⌘ is Ctrl+Shift (Konsole's convention); ⌘⇧ and ⌘⌃ are Ctrl+Alt+Shift; ⌃ stays Ctrl; ⌥ is Alt.
`keymap.conf` reads the `cmd`/`opt` words by the same table, and `elisctl keymap list` prints every binding.

| Key | Action |
| --- | --- |
| Ctrl+Shift+N / Ctrl+Alt+Shift+N | New session / new workspace |
| Ctrl+Alt+N | New window |
| Ctrl+Shift+O | Open directory as a session |
| Ctrl+Shift+W / Ctrl+Shift+Z | Close session / undo the close within 3 s |
| Ctrl+Alt+Shift+T | Reopen last closed session |
| Ctrl+Shift+D / Ctrl+Alt+Shift+D | Split side by side / top and bottom |
| Ctrl+Alt+Shift+← / → | Focus left / right pane |
| Ctrl+Alt+Shift+Return / F11 | Terminal zoom / full screen |
| Ctrl+Alt+Shift+S / Ctrl+Alt+Shift+E | Toggle sidebar / file panel |
| Ctrl+Alt+Shift+↑ / ↓ | Previous / next session |
| Ctrl+Alt+↑ / ↓ | Previous / next session needing attention |
| Ctrl+P / Ctrl+Shift+P / Ctrl+Tab | Session palette / action palette / recent sessions |
| Ctrl+Alt+O | Custom-commands palette |
| Ctrl+Alt+Shift+F | Flag session |
| Ctrl+Alt+Shift+J | Hide / show overlays |
| Ctrl+Alt+Shift+G | Dashboard of recent sessions |
| Ctrl+Shift+F | Search the scrollback |
