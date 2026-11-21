# Linux Phase 0: upgrade from agterm-qt

Roadmap: `2026-11-21-linux-elis-migration.md`, Phase 0. Model: `macos/scripts/migrate-from-agterm2.sh`.

## What agterm-qt left on a machine

- State `~/.local/share/agterm-qt`: `windows.json`, `windows/`, `mobile/` (cert, key, token), plus the install payload
  (`agent-status/`, `skill/`), `agterm.lock` (a QLockFile: the live app holds a flock on it), `agterm.sock`,
  `extras-installed`, `extras-install.log`.
- Config `~/.config/agterm-qt`: `keymap.conf`, `hooks.conf`, `restore-denylist.conf`, `agent-status/` (what the hooks run).
- `~/.config/agterm-qtrc` (`DefaultProfile=agterm-qt.profile`) and `~/.local/share/konsole/agterm-qt.profile`.
  Elis reads `~/.config/elisrc` and seeds `elis.profile`.
- Daemons `agterm-session-host <rt>/agterm-qt-<sha1(state)[:8]>/<session>.<pane> -- <shell>`, rt = `$XDG_RUNTIME_DIR`.
- `~/.local/bin/{agterm-qt,agtermctl,agterm-session-host}`, `~/.local/share/applications/agterm-qt.desktop`,
  `~/.local/share/icons/hicolor/*/apps/agterm-qt.png`.
- Agent extras: Claude hooks and swarm-companion dir, the `# >>> agterm agent-status >>>` rc and Codex blocks,
  `~/.pi/agent/extensions/agterm-status.ts`, OpenCode `plugins/agterm-status.js` and `plugins/agterm-v2/tui.js`,
  skills `~/.claude/skills/agterm` and `~/.codex/skills/agterm`.

## Tasks

1. `linux/scripts/migrate-from-agterm-qt.sh`: refuse while a flock is held on the old `agterm.lock` or on `elis.lock`
   (scoped to these state dirs, never by process name); stop the old state's daemons through their own `--kill`;
   move state and config entry by entry, renaming agterm names only in config text; convert the rc and profile;
   remove binaries, desktop entry, icons and install payload; run `kbuildsycoca6` (`KBUILDSYCOCA` overrides it).
2. `installers.cpp`: the same pass that installs the Elis extras removes the agterm ones, each only when it is ours
   (its marker, or its command under `agent-status/agterm-*`). Unit tests in `tests/test_core.cpp`.
3. `tools/elis/skip.txt`: keep the old names in the script, its test and the installer code.
4. `linux/README.md`: "Upgrading from agterm-qt", including pairing the phone again.
5. `linux/scripts/tests/migrate-from-agterm-qt-test.sh` on a synthetic home with real session-host daemons, in ctest.

## Done when

- On a copy of this machine's state, migrated, a build-tree Elis opens the same windows and sessions,
  `settings.json` holds one set of status hooks after `elis --install all`, and the copy's `~/.local/bin` holds no agterm.
- cmake build, `ctest --test-dir build` and `scripts/smoke.sh` pass; `tools/elis/check-names.sh` passes.
