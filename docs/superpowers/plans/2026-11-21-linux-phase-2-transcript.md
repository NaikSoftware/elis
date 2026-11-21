# Linux Phase 2: `session.transcript` (Chat on the phone)

Roadmap: [2026-11-21-linux-elis-migration.md](2026-11-21-linux-elis-migration.md), Phase 2.
The spec [2026-11-20-phone-chat-mode-design.md](../specs/2026-11-20-phone-chat-mode-design.md) owns the shapes.

## Route

The reader is not ported. The owner keeps shared logic in one place, and `ElisCore` builds on Linux, so `linux/shared`
builds ElisBridge: a dynamic library with the Swift stdlib linked in, exposing a C ABI of JSON strings
(`linux/shared/include/elis_bridge.h`). The Mac's own `ClaudeTranscript*Tests.swift` test the reader, also on Linux CI.

## Layout

- `linux/shared`: the SwiftPM package; CMake builds it into `build/swift/release/libElisBridge.so` and installs it to
  `lib/elis`, with the binaries' rpath pointing there.
- `src/core/transcript.{h,cpp}`: `transcriptArguments` (the Mac's argument check) and `transcriptPage` (one page).
- `src/core/commands.cpp`: `session.transcript` checks the arguments through the bridge, resolves the target and the
  agent's pane as the Mac's `Session.transcriptSource` does, then defers the read (`takeDeferred`). The control server
  (`src/app/main.cpp`) runs it on `QThreadPool` and replies from the GUI thread: ElisCore traps on the main thread.
- Tree: `agentSessionId`, `agentPane`, sampled from both panes as the Mac's `applyAgentSamples`.

## Tasks

1. Tree fields and the sampler over both panes.
2. `session.transcript` arguments, refusals, `elisctl session transcript` with the Mac's human output.
3. ElisBridge in CMake, the deferred read, `ControlDispatcherTranscriptTests`' cases in `test_core`.
4. Smoke: a fake `claude` (`exec -a claude`) with its `sessions/<pid>.json` and a three-line transcript under a temp
   `CLAUDE_CONFIG_DIR`; a tail page, then `--before <start>` pages back.
5. Docs and a CI job that builds ElisBridge in `swift:6.3.2-noble`.

## Done when

- ctest and `scripts/smoke.sh` pass on a clean build; `elis` runs with no Swift on PATH.
- The phone e2e on the emulator (Chat opens, pages back, answers a permission card) runs outside this plan.
