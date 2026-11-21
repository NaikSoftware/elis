# Linux Phase 2: `session.transcript` (Chat on the phone)

Roadmap: [2026-11-21-linux-elis-migration.md](2026-11-21-linux-elis-migration.md), Phase 2.
The spec [2026-11-20-phone-chat-mode-design.md](../specs/2026-11-20-phone-chat-mode-design.md) owns the shapes;
`macos/ElisCore` is the reference code and its `ClaudeTranscript*Tests.swift` are the fixtures.

Status 2026-11-21: the C++ reader port (tasks 2-3) is paused. The owner keeps shared logic in one place, and ElisCore
already builds on Linux, so the reader will most likely be Swift ElisCore behind `transcriptPage` (`src/core/transcript.h`).
Until then a valid read answers the Mac's `the Elis on this host is too old for session.transcript`.

## Layout

- `linux/src/core/transcript.{h,cpp}` in `elis-core`: a C++ port of `ClaudeTranscript`, `ClaudeTranscriptIndex`,
  `ClaudeTranscriptItems`, `ClaudeTranscriptMessages`, `ClaudeCommandCatalog` and `ClaudeHome`.
  Items, pending calls, meta and commands are `QJsonObject`s shaped as the Swift wire types encode them.
- `linux/tests/test_transcript.cpp`, ctest `transcript`: every case of the five `ClaudeTranscript*Tests.swift` files,
  same names, same fixture literals and expected values.
- `session.transcript` in `src/core/commands.cpp`; its cases mirroring `ControlDispatcherTranscriptTests` in `test_core`.

## API the dispatcher calls

`Transcript::Reader::instance(claudeHome(CLAUDE_CONFIG_DIR, HOME)).page(Request{id, after, before, held, maxBytes})`,
then `Page::result()` is the reply's `result`; `nullopt` is `transcript not found`.
The read runs on the GUI thread: Linux dispatch is synchronous, the index is built once per file and extended per poll.
A first scan of a large file is timed below; a pool-thread read comes only if that number calls for it.

## Tasks

1. Header, stub `transcript.cpp`, `test_transcript` target (this commit and the next).
2. Port the Swift reader tests 1:1 (Antigravity), check names and literals, commit red.
3. Implement `transcript.cpp` against the frozen tests (Antigravity hand-off); review for stubs and fakes.
4. Session fields `agentSessionId`, `agentPane` from `sampleAgents` over both panes (Mac `applyAgentSamples`),
   on the tree's session node.
5. `session.transcript`: Mac argument names, errors and refusals (`ControlDispatcher+Transcript.swift`,
   `Session.transcriptSource`); `elisctl session transcript` with the Mac's human output; dispatcher tests; smoke step.
6. Docs: `linux/README.md`, `linux/docs/PARITY.md`, `linux/share/skill/elis`, elisctl usage, `mobile/README.md`,
   the spec's Linux lines.

## Done when

- ctest `core`, `transcript`, `ui`, `filepanel` pass; `scripts/smoke.sh` passes.
- An offscreen build-tree Elis with a fake `claude` (`exec -a claude`) and its `sessions/<pid>.json` and
  `projects/<slug>/<id>.jsonl` under a temp `CLAUDE_CONFIG_DIR` shows `agent: claude`, `agentSessionId`, `agentPane`
  in `tree`, answers `elisctl session transcript` with the Swift page shape, and pages back with `--before <start>`.
- The phone e2e on the emulator runs later, outside this plan.
