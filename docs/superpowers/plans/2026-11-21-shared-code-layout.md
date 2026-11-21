# Shared code outside the platform folders

Goal: code and data more than one app uses live once, outside `macos/`, `linux/` and `mobile/`.

## Layout

| New path | From | Used by |
| --- | --- | --- |
| `shared/ElisCore/` | `macos/ElisCore/` (whole SwiftPM package) | Mac app, elis-server, ElisBridge |
| `linux/bridge/` | `linux/shared/` (ElisBridge, renamed so "shared" means one thing) | Linux app |
| `shared/agent-status/` | `macos/Elis/Resources/agent-status/` + `linux/share/agent-status/` | Mac bundle, Linux install, elis-server package |
| `plugins/elis/skills/elis/` (+ new `linux.md`) | replaces `linux/share/skill/elis/` | Mac, Linux, elis-server |
| `shared/fixtures/` | `phone-link-vectors.json`, `ble-vectors.json` from ElisCore tests and `mobile/test/fixtures` | ElisCore tests, phone tests |

Installed layouts do not change: the Mac bundle keeps `Contents/Resources/agent-status`,
Linux keeps `share/elis/agent-status` and `share/elis/skill/elis`.

## Moves

1. `git mv macos/ElisCore shared/ElisCore`; fix `#filePath` chains in its tests (four hops now land on `shared/`).
2. `git mv linux/shared linux/bridge`; its path dependency becomes `../../shared/ElisCore`.
3. Agent-status: the Mac set is the base (a superset: crons, teammates, shell tasks); add python3 as a third JSON
   reader after plutil and jq so a Linux host without jq keeps working; drop the Linux copy.
4. Skill: delete `linux/share/skill/elis`; Linux-only facts go to `linux.md`, linked from SKILL.md.
5. Fixtures: one copy each; Swift reads them via `#filePath`, Dart via `../shared/fixtures`.
6. References: project.yml, scripts, Makefile, CI, lint configs, CMake, `bundled()`, docs.

## Risks

- project.yml and the Xcode scripts are proved only by macOS CI.
- `server-build.sh` mounted `macos/` as the source tree; it now mounts the package itself.
- Tests that skip when a file is missing can pass with a broken path: compare skip counts with the pre-move run.
- `melonamin/agterm-linux` carries its own `agtermCore`; nothing outside this repo builds from these paths.
