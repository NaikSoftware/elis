# Elis assistant: Linux host — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Elis assistant works in the Linux Qt app: a pinned Elis row above the workspaces opens a chat; messages go to a long-lived provider process; the assistant messages sessions through `elisctl`; agents reply with `elisctl reply`; the full `assistant.*` control API and its docs ship.

**Architecture:** All assistant logic stays in `shared/ElisCore`. Task 1 extracts a synchronous `AssistantCommands` core from `ControlDispatcher+Assistant` (send becomes plan → host types → finish), so the Mac's async dispatcher and Linux's synchronous C++ dispatch share one implementation. `linux/bridge/Sources/ElisBridge/Chat.swift` exposes it as JSON-in/out `@_cdecl` functions; C++ keeps only Qt widgets, the socket, `QProcess` and typing.

**Tech Stack:** Swift 6 (ElisCore, ElisBridge), C++17 Qt6/KF6 (linux/), CMake/ctest, swift-testing, QTest.

**Spec:** `docs/superpowers/specs/2026-11-21-elis-assistant-design.md` (read "Design", "Control API", "Host requirements").
**Mockup:** variant B on https://claude.ai/artifact/MPaCn2CEsFnrsQ1MFCFsd5 (pinned dog row, chat column, right rail, composer with chips and provider picker showing names only).

## Global Constraints

- Linux decisions follow the Mac app where the Mac answers them; the Mac has no assistant UI yet, so the mockup and spec rule.
- Bridge functions go in `ElisBridge/Chat.swift` only (another session edits `Bridge.swift`, `store.cpp` move logic, `commands.cpp`/`control.cpp` parity); keep C++ edits in new files where possible (`linux/src/core/assistant.{h,cpp}`, `linux/src/app/assistantrunner.{h,cpp}`, `linux/src/app/assistantview.{h,cpp}`) and only hook lines in shared files.
- Every bridge result is freed with `elis_free`; nothing in ElisCore with `dispatchPrecondition(.notOnQueue(.main))` runs on the GUI thread.
- Host requirements from the spec are binding: one provider input per turn (queue host-side); `turnEnded()`/`providerFailed()`; cached providers; `AssistantPeer.sessionID` equals the tree node `id`; strip `ELIS_*`/`CLAUDE*` from the provider env; per-input providers get `/dev/null` stdin; `session.type` sends its final Return in its own write.
- Group tags reach only agent sessions; `blocked` sessions are never typed into; nothing is queued for sessions.
- Linux gates: CMake build, `ctest --test-dir build`, `linux/scripts/smoke.sh` (bash); ElisCore `swift test` (only the known zsh/tcsh/csh failures); strict SwiftLint (Linux binary, `LINUX_SOURCEKIT_LIB_PATH=/home/naik/.local/opt/swift-6.3.2-RELEASE-ubuntu24.04/usr/lib`) on `shared/ElisCore` and `macos/` zero findings. macOS GitHub CI is not waited for.
- Never run `elis`/`elisctl` against the default socket; manual and smoke runs use a short `/tmp` `ELIS_STATE_DIR`.
- Comments only for non-obvious constraints; no doc comment longer than its body.

## Review Focus

- Elis row selected and the user presses a terminal shortcut: keys go to the composer, never to the hidden session.
- Provider binary missing or exits at once: the chat shows an error entry, `running` clears, `ask --wait` returns.
- An agent replies while a turn runs: the reply waits host-side and is written after `turnEnded`, never merged into the running turn.
- A session closed between the model's `send` and the typing: it is reported skipped `failed: …`, not a crash.
- A very long assistant answer streamed in many chunks: one transcript entry per turn, the view stays responsive.

---

### Task 1: Synchronous assistant core shared by both hosts

**Files:** Create `shared/ElisCore/Sources/ElisCore/AssistantCommands.swift`; Modify `ControlDispatcher+Assistant.swift`; Test `Tests/ElisCoreTests/AssistantCommandsCoreTests.swift` (existing `ControlDispatcherAssistantTests` must stay green unchanged).

**Interfaces — Produces:**
- `@MainActor public struct AssistantCommands { public init(chat: AssistantChat); public func run(_ request: ControlRequest, peers: [AssistantPeer]?, providers: [SessionLauncher]?) -> AssistantStep; public func finishSend(_ plan: AssistantSendPlan, failures: [String: String]) -> AssistantStep; public func stamp(_ tree: ControlTree, peers: [AssistantPeer]?, providers: [SessionLauncher]?) -> ControlTree }`
- `public enum AssistantStep: Sendable { case reply(ControlResponse, effects: [AssistantEffect]); case send(AssistantSendPlan) }`
- `public enum AssistantEffect: Sendable, Equatable { case input(AssistantEntry, streamText: String); case sent(AssistantEntry); case providerChanged(SessionLauncher); case show(window: String?) }`
- `public struct AssistantSendPlan: Sendable, Codable, Equatable { targets: [AssistantPeer]; line: String; body: String; cut: Bool; skipped: [AssistantSkip]; skippedIDs: [String]; handles: [String: String] }` (`handles` maps target session id → handle for the result).
- Behavior is exactly today's dispatcher (all error texts unchanged); `show` returns `.reply(ok, [.show(window)])` and the caller marks seen only when its own show succeeded — `finishShow()` helper or the dispatcher calls `chat.markSeen()` as today.
- `ControlDispatcher+Assistant` becomes: build `AssistantCommands(chat:)`, `run`, perform effects through `actions` (`assistantInput`, `assistantSent`, `assistantProviderChanged`, `showAssistant`), for `.send` await `typeSession` per target and call `finishSend` with failures keyed by session id; `stampAssistant` delegates to `stamp`.

- [ ] Tests first (`AssistantCommandsCoreTests`): ask returns `.reply` with one `.input` effect; send returns a plan whose `line` equals `AssistantLine.typed(text).line`; `finishSend` with one failure yields `delivered`/`deliveredIDs` of the rest, `skipped` reason `failed: <msg>`, a `.sent` effect and `cut` passthrough; reply's effect carries `[reply from @<handle> <id>] <text>`; nil peers refuse with `ControlActionsUnsupported.message`; `stamp` equals today's `stampAssistant` output for the same inputs.
- [ ] RED → implement → GREEN; whole `ControlDispatcherAssistantTests` unchanged and green; commit `refactor(assistant): one synchronous core for every host`.

### Task 2: ElisBridge `Chat.swift`

**Files:** Create `linux/bridge/Sources/ElisBridge/Chat.swift`; Modify `linux/bridge/include/elis_bridge.h` (declarations only); Test: a bridge test target if the package has one, else `linux/tests/test_core.cpp` cases driving the functions through a small C++ wrapper (`linux/src/core/assistant.{h,cpp}` created here with only the JSON wrappers).

**Interfaces — Produces (all `char*` JSON results freed with `elis_free`, called on the GUI thread):**
- `elis_assistant_open(const char *stateDir)` → `{}`: creates the process-wide `AssistantChat(file: <stateDir>/assistant/chat.jsonl)`; idempotent.
- `elis_assistant_run(const char *requestJSON, const char *peersJSON, const char *providersJSON)` → `{"reply": <ControlResponse>, "effects":[…]}` or `{"plan": <AssistantSendPlan>}`.
- `elis_assistant_finish_send(const char *planJSON, const char *failuresJSON)` → `{"reply":…, "effects":[…]}`.
- `elis_assistant_stamp(const char *treeJSON, const char *peersJSON, const char *providersJSON)` → stamped tree JSON (top-level `assistant`, node `handle`, `assistantMark`).
- `elis_assistant_turn_ended()`, `elis_assistant_provider_failed(const char *message)`, `elis_assistant_mark_seen()`, `elis_assistant_append_assistant(const char *text)` (stores an `.assistant` entry, returns it).
- `elis_assistant_launch(const char *provider, const char *promptJSONPeers)` → `{argv, mode, environment, preamble}` using `AssistantPrompt.system`, the stored resume id and `AssistantLaunch`; `elis_assistant_turn_argv(provider, input)` for per-input providers; `elis_assistant_encode(provider, text)`; `elis_assistant_decode(provider, line)` → `[{"text"|"conversation"|"turnEnded":…}]` (a `conversation` event stores the resume id); `elis_assistant_recap()` → `AssistantPrompt.inline(entries(last: 50))`.
- Isolation: wrap each body in `MainActor.assumeIsolated`. FIRST STEP: a spike test proving `assumeIsolated` holds on the Qt/process main thread under the static-stdlib build; if it traps, keep the bridge's own chat instance behind a `Mutex` and mark the needed ElisCore members `nonisolated` — the spike picks the route, it never drops the feature.

- [ ] Spike test (call `elis_assistant_open` + `elis_assistant_run` with an ask from the test's main thread) → route decided and recorded in the report.
- [ ] Tests (via `assistant.{h,cpp}` wrappers in `test_core`): open/run ask round trip; send plan → finish with one failure; stamp adds handles; decode of each fixture in `shared/fixtures/assistant/` yields the expected events; launch for claude carries `--input-format stream-json`.
- [ ] Implement; ctest green; commit `feat(linux): assistant bridge`.

### Task 3: Linux control commands, events, tree, typing

**Files:** Create/extend `linux/src/core/assistant.{h,cpp}`; hook lines in `linux/src/app/library.cpp` (app-wide routing: peers across all windows), `linux/src/core/control.cpp` (`tree` passes through `elis_assistant_stamp`), `linux/src/core/hooks.cpp` (`EventSource::kinds` gains `assistant.message`), `linux/src/app/mainwindow.cpp` (`type`: non-zmx panes send the final Return in a separate `sendInput` after a 10 ms gap, matching `elis_zmx_type_bytes`). Test: `linux/tests/test_core.cpp`, `test_ui.cpp`.

**Interfaces:**
- Consumes Task 2. Produces `Assistant::dispatch(QJsonObject request, const Peers &, …) -> QJsonObject` used by `WindowLibrary::dispatch` for `assistant.*`; `assistant.send` performs the plan by calling each target window's `session.type` path, then `finish_send`.
- Peers: every session of every window: `{sessionID: Session::id, window, workspaceID, workspaceName, name: displayName(), agent, status}`; sessionID byte-identical to the tree's `id`.
- Effects: `.input` → `AssistantRunner::enqueue(streamText)` (Task 4); `.sent`/`.input` → `emitEvent("assistant.message", sessionId, {kind, from, handle, text})`; `.show` → select the Elis row (Task 5) — until Task 5 lands, answer ok without UI.
- Providers: cached `MainWindow::detectLaunchers()` result, never probed per request.

- [ ] Tests: `assistant.ask` appends and emits `assistant.message`; `assistant.send --to @all` types only into agent sessions and skips a `blocked` one; failure of one target is `skipped`; `tree` carries `handle` and `assistant`; `assistant.reply` from a session id; non-zmx `session.type` writes text then `\r` separately (FakeTerminals records two writes).
- [ ] Implement; ctest; commit `feat(linux): assistant commands`.

### Task 4: Provider process (`AssistantRunner`)

**Files:** Create `linux/src/app/assistantrunner.{h,cpp}`; hook in `MainWindow`/`main.cpp` lifetime; Test: `test_ui.cpp` with a fake provider script under `linux/tests/fixtures/fake-provider.sh` (echoes a stream-json result per input line).

**Behavior:** follows `PhoneRelay` (`QPointer<QProcess>`, `PR_SET_PDEATHSIG`, `aboutToQuit` cleanup, `\n` line buffering). Stream mode: one long-lived process from `elis_assistant_launch`; per-input mode: one process per input from `elis_assistant_turn_argv(provider, input, peersJSON)` (peers carry the system prompt), stdin `/dev/null`. Host-side FIFO: write the next input only after `turnEnded`. Prepend `preamble` and, after a provider switch, `elis_assistant_recap()` to the first input. Env: inherited minus `ELIS_*`/`CLAUDE*`, plus launch `environment`. Working dir `<stateDir>/assistant`. stdout lines → `elis_assistant_decode`; `.text` accumulates and on `turnEnded` becomes one `elis_assistant_append_assistant` entry + `assistant.message` event; `turnEnded` → `elis_assistant_turn_ended`; process error / unexpected exit → `elis_assistant_provider_failed(message)` (returns the stored error entry: emit it as `assistant.message`, then `elis_free` it) and restart on next input (resume id kept). No provider available → `provider_failed("no assistant provider installed")`.

- [ ] Tests (fake provider via a test-only provider override env `ELIS_ASSISTANT_PROVIDER_CMD`): two queued asks produce two turns in order; a reply arriving mid-turn is written after the first `result`; a missing binary yields an error entry and `running` false; quit leaves no child.
- [ ] Implement; ctest; commit `feat(linux): assistant provider process`.

### Task 5: Pinned Elis row, chat view, composer

**Files:** Create `linux/src/app/assistantview.{h,cpp}`; Modify `sidebar.{h,cpp}` (third kind `AssistantRow`, pinned first in every mode, dog icon `:/elis.png`, unread badge, not editable/draggable/drop target, a session-row drag onto the composer inserts its handle), `mainwindow.{h,cpp}` (chat page in `m_stack`, `showSelected`, key routing to the composer, `assistant.show`). Test: `test_ui.cpp`.

**UI (mockup variant B):** centered chat column (max ~760 px): user bubbles right, assistant text, `sent` cards listing recipients, reply cards with handle + "go to session" link (selects that session), error lines; right rail: sessions in the current exchange with their `assistantMark` dot and agent; composer: chips for tags, `@` completion over handles, `@ws:` and `@all`, drop target for sidebar rows, provider picker inside the composer listing detected providers by name only, send button; Enter sends, Shift+Enter newline. Reuse the app's palette, fonts and the sidebar's chip/badge painting; the row's unread badge clears on show.

- [ ] Show the owner the rendered result (offscreen screenshot of the real app per the "visual check" memory) BEFORE writing UI tests; adjust on feedback.
- [ ] Tests: row is first in tree, flagged and focus modes; selecting it shows the chat and keys reach the composer; a reply raises the unread badge and `assistant.show` clears it; dropping a session row adds its chip; `@` completion lists handles.
- [ ] Implement; ctest; commit `feat(linux): Elis row and chat`.

### Task 6: `elisctl` on Linux and smoke

**Files:** `linux/src/ctl/elisctl.cpp`; `linux/scripts/smoke.sh`.

`elisctl assistant ask TEXT [--wait [--timeout N]] | send --to TAG… TEXT|--stdin | read [--last N] | provider [NAME] | show` and top-level `elisctl reply TEXT|--stdin` (target from `ELIS_SESSION_ID`; outside a session: `elisctl reply runs inside an Elis session`). Same human output and exit codes as the Swift CLI (`HH:MM kind @from: text`; send fails when nothing delivered; `--wait` polls `tree` `assistant.running` with pick backoff, 124 on timeout). `--json` prints the server line unchanged.

- [ ] smoke.sh steps on an isolated state dir with the fake provider: ask → read shows user + assistant entries; reply from a session id; send to a fake agent session types the line; events show `assistant.message`.
- [ ] Implement; ctest + smoke; commit `feat(linux): elisctl assistant and reply`.

### Task 7: Docs, skill, catalog

**Files:** `site/docs.html` (new "Elis assistant" section: row, chat, tags, providers, reply, permissions note: providers run full-auto and other agents' messages reach the assistant), `site/commands.html` (`assistant.*`, `reply`, read-back fields, event), `plugins/elis/skills/elis/SKILL.md` (trigger: "message other sessions through Elis", "reply to Elis" + section), `reference.md`, `linux.md`, `.claude/rules/control-api.md` public catalog line, `docs/PARITY.md` if it lists commands, `linux/README.md` control list. Mirror an existing sibling (`msg.*`) at every hit (`git grep -n "msg send"`).

- [ ] Commit `docs: Elis assistant`.

---

## After this plan
Merge the combined PR (core + Linux) without waiting for macOS CI (owner); send elis-69 the merge commit; delete branches; remove the worktree. Plan 3 (Mac host) later.
