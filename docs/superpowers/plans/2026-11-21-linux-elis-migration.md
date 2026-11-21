# Linux (Qt) app: migration to today's Elis — roadmap

Status: draft for the owner's review, 2026-11-21.
This is a roadmap of sub-projects, not a task plan: each phase below gets its own spec and plan
(`superpowers:writing-plans`) when it starts, because each one ships and tests on its own.

**Goal:** bring `linux/` level with the Mac app and the phone app as they are on `master` now: the Elis brand and
look, adapted to Qt/KDE, and the phone link the phone app now speaks (Chat and Term views, direct input,
Bluetooth), with a clean upgrade for people running the old agterm-qt.

## Where `linux/` stands

Done already, verify only:
- Name, paths, env vars, `elisctl`, `elis://pair` links (`d680dbcd`), app icon (`fda717db`).

Missing (found by reading the code, 2026-11-21):
- Upgrade from an installed agterm-qt. This machine runs one:
  `~/.local/bin/{agterm-qt,agtermctl,agterm-session-host}`, `~/.local/share/agterm-qt`, `~/.config/agterm-qt`,
  `~/.config/agterm-qtrc`, `~/.local/share/applications/agterm-qt.desktop`.
  Elis reads none of them, and its hook installer only recognises `elis-*-status.sh`
  (`src/core/installers.cpp:139`), so the old agterm hooks stay in `~/.claude/settings.json` beside the new ones.
- The Mac look: workspace bands, the selection pill, the title-bar session pill, the copper accent.
  `linux/docs/images/elis.png` is still an agterm-qt screenshot.
- Phone link: the Linux relay (`src/ctl/mobile.cpp`) is the pre-mux line protocol.
  The phone falls back to its text view there (`mobile/lib/model.dart:202`).
  The tree lacks `agentSessionId`, `agentPane` and `surfaces[]` (`backedByZmx`, `phoneViewers`, `phoneLead`).
  There is no `session.transcript` or `session.attach`, and no Bluetooth.
- The Live daemon `elis-session-host` serves one client, and the newest attach wins (`src/host/sessionhost.cpp:170`).
  It replays raw output and has no leader/viewer roles.
  The phone's Term view and direct input need all three.

## Decisions

The owner's rule (2026-11-21): Linux works as the Mac version does; the Mac code is the reference, adapted only
where Qt/KDE has its own idiom.

- **D1. Phone connection.** As on the Mac: the phone attaches to a Live pane's daemon as a viewer or a leader
  (`session.attach`), through the mux relay. Remote sessions in the Qt app (another Mac, elis-server rows) follow
  the Mac too; they are the next roadmap after this one.
- **D2. Accent.** As on the Mac, the app accent is the brand copper, set as the app palette's Highlight:
  `#C8742F` on light, `#E08A45` on dark (the phone's and the site's dark-tuned value).
  Everything else comes from the KDE palette and Breeze.
- **D3. Live daemon.** As on the Mac: the patched zmx replaces `elis-session-host`.
  `macos/scripts/setup-zmx-linux.sh` already builds it for `x86_64` and `aarch64` musl.
  It brings roles (`ZMX_MANAGED`, `_CLAIM`, `_FOLLOW`, `_SCREEN_ONLY`), `zmx screen`, `zmx type`, and a rendered
  screen on reattach, which the Mac relay reads directly (`PhoneLinkClaim.swift`, `PhoneLinkTerminal.swift`,
  `PhoneLinkTitleFilter.swift`), so the C++ port follows it line for line.
- **D4. Bluetooth.** As on the Mac, the relay offers TLS and Bluetooth; Bluetooth is required, not optional.
  A spike on BlueZ (LE peripheral, L2CAP CoC listener) comes first to pick the working mechanism, not to decide
  whether to ship it: if one route fails, the spike tries the next until one works.

Settled earlier and not reopened:
- The relay and Chat are C++ ports that reuse the golden vectors
  (`phone-link-vectors.json`, `ble-vectors.json`; the transcript cases are inline in `ClaudeTranscript*Tests.swift`).
- Scratch and the quick terminal stay dropped.

## Phases

The order follows the tightest dependency.
Chat needs neither the mux nor the daemon change: the phone's `TypeWriter` types through `session.type`, and its
prompt cards read the grid from `session.text` (`mobile/lib/screens/session.dart:226-236`).
So Chat, the owner's top phone priority, comes first after the upgrade and the look.

### Phase 0 — Upgrade from agterm-qt

- `linux/scripts/migrate-from-agterm-qt.sh`, modelled on `macos/scripts/migrate-from-agterm2.sh` and covered by a
  test on a copy of real state. It is safe to run twice, and it refuses while agterm-qt or Elis runs.
  - Stop the old `agterm-session-host` daemons.
    Their panes come back through the captured re-run command, so their output is lost and their commands are not.
  - Move the state directory (windows, `mobile/` cert and token) and the config directory (`keymap.conf`,
    `hooks.conf`, `restore-denylist.conf`), and convert `agterm-qtrc`.
  - Remove the old binaries, the `agtermctl` link and the `.desktop` entry, then run `kbuildsycoca6`.
- The installers drop agterm-named hooks, the shell rc block, the Codex block, the OpenCode plugin and the skill,
  in the same pass that installs the Elis ones.
  Add the old names to `tools/elis/skip.txt` as the Mac migration script does, so `rename.sh` leaves them alone.
- The phone has to pair again, because both the app id and the link scheme changed.
  The README says so.
- Done when, on a copy of this machine's state, Elis opens the same windows and sessions with exactly one set of
  hooks, and `which agtermctl` finds nothing.

### Phase 1 — Brand and look, in Qt terms

Reference: `site/assets/shot-desktop-{main,files,switcher}.webp`, `mobile/lib/theme.dart`,
`macos/Elis/Views/{SidebarRowViews,WorkspaceSidebar+Bands,WindowContentView+Titlebar}.swift`.
Rule: take the Mac's structure and proportions.
First step: a per-surface audit against the Mac code (sidebar, title strip, palette, switcher, settings, dashboard,
file panel), since the list below was read off screenshots; the fourth title-bar button in particular may be
scratch, which Linux dropped.
Each new title-bar element asks the owner whether it joins Settings ▸ Interface (`CLAUDE.md`).
Colours come from `QPalette` (D2), icons from Breeze where an equivalent exists, and KDE keeps its window
decoration and menu bar.
- Sidebar, in the `sidebar.cpp` delegate:
  - Workspace bands: a rounded group outline over a tinted workspace's rows, the tint at 10% fill and 16% stroke.
  - Selection pill: radius 8, accent at 20% fill (12% unfocused) with a 55% (35%) hairline; hover at 7%.
  - The Mac's workspace glyph.
  - A context line under the session name.
  - The density setting (default or compact).
- Title strip: the existing toolbar row carries a centred session pill
  (agent logo · workspace › session · context · Ctrl+P hint) that opens the session palette.
  On the right go the layout buttons: single, split, dashboard and overlay.
  It is not a client-side title bar.
- Footer icons as in the shots.
- Retake `linux/docs/images/elis.png` and the README shot under the screenshot rules in `CLAUDE.md`.
- Show the owner the running result before writing tests (`CLAUDE.md`), in light and dark Breeze.

### Phase 2 — Chat on the phone (`session.transcript`)

- `src/core/transcript.{h,cpp}`: a C++ port of `ClaudeTranscript*` and `ClaudeCommandCatalog` from `ElisCore`
  (index, items, byte-offset cursor, ~48 KiB pages, tool output clipped at ~4 KiB, the record allowlist).
  The spec `2026-11-20-phone-chat-mode-design.md` owns the shapes, and the ported Swift fixtures test it.
- Tree: `agentSessionId` (the Claude conversation id the app already tracks for drop and reopen) and
  `agentPane`.
- Protocol, dispatcher, `elisctl session transcript` and its read-back, then the docs listed in Phase 7.
- Done when the phone on a Linux relay opens a Claude session in Chat, pages back through history, and answers a
  permission prompt with a card.

### Phase 3 — Live panes on zmx (D3)

- Build: `setup-zmx-linux.sh` or a shared script stages zmx for the host arch, and CMake installs it beside
  `elis`.
  zig 0.16 becomes a build dependency, or the build fetches the release tarball's zmx.
- Konsole panes run `zmx attach <name>` with `ZMX_MANAGED`.
  The app reads the role reports and covers a pane while a phone leads it (the Mac's `PaneLeadCover`).
- The tree gains `surfaces[]`, with `backedByZmx` set as the phone reads it.
- Moving to the new daemon: the first launch on zmx reaps the `elis-session-host` daemons through the captured
  command fallback, then the host and its sources are deleted.
- Restore, reap and delete behave as PARITY documents them today.
  The smoke test and `test_core` cover each.

### Phase 4 — `session.attach`

- Add `session.attach [--pane] [--claim] [--json]` to the protocol, dispatcher and CLI, matching
  `control-api.md` ("It is a zmx viewer attach…") and its refusal texts.
- Read-backs `phoneViewers` and `phoneLead`.
- Events `phone.attached|detached|claimed|released`, with their human lines and `hooks.conf` names.

### Phase 5 — Relay mux in C++ (Term view, direct input)

- Split `src/ctl/mobile.cpp` like the Swift relay:
  - session: auth, order, revoke;
  - frame codec and scheduler: ctest against `phone-link-vectors.json`;
  - terminal: watch attach on an openpty, 512 KiB buffer, RESYNC, watchdog, grid poll;
  - claim: role report, DA responder, 16 KiB input window, RESIZE plus SIGWINCH;
  - events on channel 1.
- `control-api.md`'s "Relay mux" and "Direct input" sections are the contract, caps and CLOSE reasons included.
- Done when the phone's emulator e2e (Memroot procedure, new binary names) shows Term in colour, takes the lead
  on open, types, and gives the lead back.

### Phase 6 — Bluetooth (D4)

- Spike: BlueZ over D-Bus (`LEAdvertisingManager1` and `GattManager1`) with an LE L2CAP CoC socket on a dynamic
  PSM, on this machine's adapter and a Pixel; if a route is refused (user permissions, bluetoothd policy, adapter
  limits), the spike finds the setup that makes it work and the install documents it.
  Measure connect time and throughput against the Mac's numbers.
- Then:
  - Noise `NNpsk0` (OpenSSL 3: X25519, ChaCha20-Poly1305, HKDF) with raw-DEFLATE frames: ctest against
    `ble-vectors.json`.
  - The advertised UUID rotates every 900 s.
  - `bluetooth.lock` lets one relay per state directory advertise.
  - `--bluetooth` / `--no-bluetooth`, `b=1` in the link, `phone.status.bluetooth`.
  - The Bluetooth line in Connect a Phone.
- The spec `2026-11-16-phone-bluetooth-design.md` owns the security model.

### Phase 7 — Docs (lands with each phase)

- Update `linux/README.md`, `linux/docs/PARITY.md`, `share/skill/elis`, `mobile/README.md` and the specs' "Linux
  keeps the text view" lines.
- Add Linux notes where `site/docs.html` and `site/commands.html` describe a feature differently on Linux.

## Out of this migration

- Phone pages (`present` channels).
  They need the presentation hub and page overlays; Linux has neither, and its own page overlays are blocked on
  Qt WebEngine.
  A later option is to show pages on the phone only, which needs no WebEngine on the desktop.
- Remote sessions in the Qt app: the next roadmap (D1).
- Other Mac features after the import (`git log 32bafca2..HEAD -- macos`). Not audited yet: PARITY predates them,
  so a command-by-command diff of `site/commands.html` against `src/core/{commands,control}.cpp` comes first and
  feeds PARITY before anything here is called complete.

## Gates per phase

- `cmake --build build`, `ctest --test-dir build` and `scripts/smoke.sh` in `linux/`.
- Phases 2, 5 and 6 also run the phone e2e on the emulator.
- `mobile/` changes, if any, pass `flutter analyze --no-pub` and `flutter test --no-pub`.
