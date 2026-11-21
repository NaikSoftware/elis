# Linux Phase 3: Live panes on zmx (D3)

Roadmap: [2026-11-21-linux-elis-migration.md](2026-11-21-linux-elis-migration.md), Phase 3.
The Mac is the reference: `ZmxSupport`, `ZmxLead`, `ZmxLifecycle`, `ZmxReplayScript`, the app's `PaneLead` and
`PaneLeadCover`, and elis-server's `ZmxRunner`/`ServerPanes`, which already run zmx on Linux.

## What ElisCore already gives

- Naming: `ZmxSupport.daemonName(for:)` (`elis-<32 hex>`), `isDaemonName`, and
  `socketDirectory(forStateDirectory:runtimeDirectory:)` (elis-server's `$XDG_RUNTIME_DIR/elis-zmx-<hash>`).
- `ZmxListParser` and `ZmxLeaderMap` for `zmx list`, `ZmxReapPolicy.namesToKill` for the launch reap.
- `ZmxLeadAttachment` (nonce, claim, the `ZMX_MANAGED*` variables), `ZmxLeadNotice` (the `zmx-role;` title) and
  `ZmxLeadState` (nonce and generation checks, `covered`).
- `ControlSurfaceNode`, the tree's `surfaces[]` entry the phone reads.

Added to ElisCore: `ZmxSupport.clientEnvironment(socketDirectory:)` (the four `ZMX_*` values every client sets, now
also used by `configuration`), and `ZmxReplayScript.plainShellArguments(commandLine:shell:)`, the create-only payload
for a pane whose terminal loads no ghostty shell integration (Konsole): it runs the line, then becomes the login
shell, for zsh, bash, fish and any other shell.

## What the bridge exposes (`linux/bridge`, JSON in and out)

- `elis_zmx_attach`: the attach argv, the variables to set and unset, the daemon name and socket directory, for a
  pane identity, a shell, an optional payload line or creation command, and a claim; it begins the pane's lead state.
- `elis_zmx_list`: parsed `zmx list` rows, or an error for a listing the Mac would not trust.
- `elis_zmx_reap`: the names a launch kills, `null` when no reap is safe.
- `elis_zmx_lead_report`: applies a title to the pane's lead state; says whether it was a role report and what
  changed. `elis_zmx_lead_state` and `elis_zmx_lead_forget` read and drop it. The states live in the bridge under a
  lock, since `ZmxLeadBook` is main-actor.
- `elis_zmx_surface`: one `surfaces[]` entry encoded by `ControlSurfaceNode`.

## What C++ does

- CMake stages zmx with `macos/scripts/setup.sh --zmx-only` for the host arch (zig 0.16, its stamp in the build dir),
  copies it beside `elis`, installs it to `bin` with its licence; configure fails with what to install when it cannot.
- `src/core/zmx.{h,cpp}`: runs `zmx list` and `zmx kill` with the bridge's environment, caches each pane's shell pid
  from the listing, and keeps the one-time reaper of the old `elis-session-host` sockets (the `k` frame).
- Store: each session persists `paneId` and `splitPaneId`, the pane identities behind the daemon names and
  `ELIS_PANE_ID`; a swap or a promoted split exchanges them.
- Panes: Konsole runs `zmx attach` with the payload; role reports are taken off the OSC titles of both panes; a pane
  that does not lead gets a cover (Qt palette), a key takes the lead with a fresh claiming attach in a new part.
- Delete, split close and window delete read the foreground job, `zmx kill --force`, then hang it up as
  `ServerPanes.end` does. Launch: the old daemons go first, then `ZmxReapPolicy` over every window file.
- Removed: `src/host/sessionhost.cpp`, its target, install entry and tests.

## Tests

- ElisCore: `ZmxReplayScriptTests` and `ZmxSupportTests` cases for the additions.
- `test_core`: a real zmx daemon in a temp socket directory (attach payload runs once, list, shell pid, kill ends a
  job ignoring SIGHUP, reap keeps claimed and kills unclaimed); the lead report state machine through the bridge;
  `surfaces[]` in the tree; pane ids persisted, swapped and promoted; the legacy reaper against a fake listener.
- smoke: live launch replays the captured command once as payload, a reattach keeps the program and the shell, a
  session delete ends its daemon, a Fresh shells launch reaps the rest, and the old daemon socket is reaped at launch.
- The migrate test keeps a stand-in for the old daemon protocol.

## Done when

- Clean configure and build, `ctest --test-dir build`, `bash scripts/smoke.sh`, and `swift test --filter` for the
  touched ElisCore suites pass; no daemon of the live install is touched by any run.
