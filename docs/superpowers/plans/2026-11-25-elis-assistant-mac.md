# Elis assistant: Mac host — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Mac app hosts the Elis assistant: the pinned Elis row, the chat with its composer, the provider process and the `ControlActions` adapter, so every `assistant.*` command, the tree stamp and the phone's Elis row work on the Mac socket.

**Architecture:** All chat logic stays in `shared/ElisCore` (done). The app target adds an `@Observable AssistantModel` that owns the file-backed `AssistantChat` and an `AssistantRunner` (the provider `Process`); `ControlServer+Assistant.swift` implements the assistant members of `ControlActions` over it; the sidebar gets a pinned node and the detail area an `AssistantView`. Four small ElisCore additions carry the window state, the keymap action, the palette row and the selection fallback.

**Tech Stack:** Swift 6, SwiftUI + AppKit (`NSOutlineView`, `NSTextView`), Foundation `Process`, swift-testing (ElisCore), XCTest (hosted `ElisTests`, `ElisUITests`), xcodegen/xcodebuild, SwiftLint strict.

**Spec:** `docs/superpowers/specs/2026-11-25-elis-assistant-mac-design.md` (Mac host). Product spec: `docs/superpowers/specs/2026-11-21-elis-assistant-design.md`. Reference host: `linux/src/app/assistantrunner.cpp`, `linux/src/core/assistant.cpp`, `linux/src/app/assistantview.cpp`, `linux/src/app/mainwindow.cpp` (`showAssistant`, `chromeState`).

## Global Constraints

- Paths are repo-root relative; app commands run in `macos/`, ElisCore commands in `shared/ElisCore/`.
- Delegated agents receive verbatim: "never execute `elis`/`elisctl` against the default socket, never launch or quit the app, static reading only." The executor itself launches only isolated Debug instances (Tasks 5, 6, 8, 9), never touches `~/Applications/Elis.app`, never `pkill Elis` or `osascript … quit`; it stops only its own instance's pid with SIGTERM.
- `ElisCore` imports no AppKit/CoreGraphics. ElisCore changes are exactly: `AppStore.assistantShown`, `ControlTree.assistantShown`, `BuiltinAction.showAssistant`, `PaletteCommand.showAssistant`, and the nil-selection snapshot fallback. `ElisCore` is a public library for the `agterm-linux` fork: add, never narrow, `public` symbols.
- Read-back: `assistantShown` is a TREE top-level field (`true` while the chat shows in that window, omitted otherwise), as Linux's `chromeState()` and `site/commands.html:699` already define it. The spec's "`ControlWindowNode.assistantShown`" would be the cached `window.list` node; this plan follows Linux and the shipped doc instead (lead to confirm with the owner).
- Line budgets under `make lint` (`file_length` warning 1000, strict): `macos/Elis/Control/ControlServer.swift` is at 1000 and gets net zero lines; `shared/ElisCore/Sources/ElisCore/AppStore.swift` is at 999 and gets at most one; `macos/Elis/AppActions.swift` (993) at most two; `macos/Elis/Views/WorkspaceSidebar.swift` (972) at most 20. New code goes into new extension files. If a budget cannot hold, stop and ask the owner through the lead before splitting a file (CLAUDE.md); never raise a limit.
- One model of state: `AssistantModel` lives on `AppActions` (`actions.assistant`), the seam the menu, palette, sidebar and `ControlServer` already share; `ControlServer.swift:720` becomes `ControlDispatcher(actions: self, chat: actions.assistant.chat)`. This replaces the spec's "ControlServer owns the chat" because `ControlServer.swift` has no line budget; behavior is identical.
- Hosted-test isolation: the default `AssistantModel` (built by `AppActions(library:)`) has an in-memory `AssistantChat()` (never `.shared`, never a file) and no state directory, and its runner refuses to spawn. Only `elisApp` passes `<stateDir>/assistant/chat.jsonl`; only a test that injects `standIn` runs a provider.
- Provider host requirements (product spec "Host requirements", binding): one input per turn, the rest queued host-side (`inputQueued`/`turnEnded` pairs); `turnEnded()` per finished turn, `providerFailed(_:now:)` when none can start or it dies; providers cached, never detected on the tree path; `AssistantPeer.sessionID` byte-identical to the tree node `id`; environment strips every `ELIS_*` and Linux's eleven Claude Code markers (`assistantrunner.cpp:139-149`), keeps `CLAUDE_CONFIG_DIR`, sets `ELIS_STATE_DIR` to this app's state dir; PATH = bundle `Contents/MacOS`, then the detected login-shell PATH; per-input providers get `/dev/null` stdin.
- Remote exception (owner, 2026-11-25): local only. `assistantPeers()` skips every session with `remoteHost != nil` and every row of a remote window (`library.remoteNode(for:) != nil`); such a row has no `handle`, no `@` completion, no drop. `ServerCommandPolicy` keeps refusing every `assistant.*`.
- Control contract (`.claude/rules/control-api.md`): protocol, dispatcher, CLI and `EventFormatter.human` already exist; this work adds the host, read-back, hosted tests and the docs/skill mirrors. Events go out through the public `library.emitAppEvent(ControlEventDraft(kind:window:session:payload:))` (`AppStore.emitControlEvent` is internal): `assistant.message` payload `kind`, `from`, `handle`, `text`, window = the sender's window when `from` is set; `assistant.cleared` empty.
- Sidebar (`.claude/rules/sidebar.md`): the row is a cached `SidebarNode` in the `NSOutlineView`, not a SwiftUI overlay; it is absent from `navigableSessions`, MRU, recent, session search, multi-selection, context menus, tints and bands. `reselectIfSelectionHidden` leaves a nil selection alone; keep it so.
- Menus (`.claude/rules/menu-actions.md`, `keymap.md`): menu item, palette row and keymap name share `BuiltinAction.showAssistant`; enablement only through `PaletteCommand.isEnabled(in:)`. Navigate ▸ Show Elis, palette "Show Elis", no default chord. No `InterfaceElement`/Settings entry (owner).
- Selection rule (owner): while the chat shows, the window's `selectedSessionID` is nil and keys go to the chat. Any non-nil selection hides the chat, enforced once in `AppStore`'s `selectedSessionID` setter path.
- Tests (`.claude/rules/tests.md`, `ui-tests.md`): deadlines use an injected clock; real waits on subprocesses are bounded (30 s ceiling), with the failure asserted by name beside the wait; every test-owned `NSWindow` sets `isReleasedWhenClosed = false`; UI tests use `app.launchForUITest()` and a temporary `ELIS_STATE_DIR`; SwiftLint rejects `master`/`slave` identifiers.
- Fake provider: reuse `linux/tests/fixtures/fake-provider.sh` through `#filePath` with `ELIS_ASSISTANT_PROVIDER_CMD="/bin/bash <abs path>"`; no copy, no project.yml resource. It is builtin-only bash, but its fractional `read -t` needs Task 2's one-line fix under macOS bash 3.2.
- Gates (`make test`, `make test-app`, `make lint`, build) run once, in Task 9. Every other run is targeted: `swift test --filter`, `xcodebuild … -only-testing:<Target>/<Class>[/<test>]`. Run `xcodegen generate` in `macos/` after adding a file.
- Design: every UI task (Tasks 4, 5) builds to the approved Mac mockup (a Claude Design project; the lead supplies its link before execution). Reproduce its layout, positions, content and colour treatments exactly, in light and dark. Keeping existing app styling where the mockup differs is a defect. Any visual choice the mockup does not settle is asked of the owner through the lead, never improvised. Where this plan's UI wording and the mockup disagree, the mockup wins.
- Comments: only non-obvious constraints, one line; no doc comment longer than its body; test comments rare and one line.

Targeted hosted command (referred to below as HOSTED):
`cd macos && xcodegen generate && xcodebuild test -project Elis.xcodeproj -scheme ElisTests -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:ElisTests/<Class>`

## Review Focus

- A session closed, a session created in the background, or a sidebar rebuild (mode switch, focus filter) while the chat shows: the chat stays and nothing gets selected; only an explicit selection leaves it. Test in Task 3.
- Typing in the composer while a session turns blocked: auto-follow must see the user as active, so the composer notes user activity on its window's store. Test in Task 5.
- Provider binary missing, or exiting at once: one error entry, `running` false, `elisctl assistant ask --wait` returns. Test in Task 2.
- An agent's reply arriving while a turn runs: written to the provider after that turn ends, never into it. Test in Task 2.
- A remote row (attached Mac session or server window) in `@` completion, as a drop, or by `--to` id: never a target. Tests in Task 3 (tree, send) and Task 5 (drop refused).

---

### Task 0: Isolated worktree

**Files:** none tracked.

- [ ] **Step 1:** `git fetch origin master`, then create a native Claude worktree (EnterWorktree) forked from `origin/master`; never `git worktree add` by hand.
- [ ] **Step 2:** Copy the Mac spec and this plan from the main checkout (`/Users/n.savchenko/IdeaProjects/elis/docs/superpowers/{specs/2026-11-25-elis-assistant-mac-design.md,plans/2026-11-25-elis-assistant-mac.md}`; the plan is not committed on any branch) into the same paths, and the product spec too if `diff` shows the main checkout's copy differs from `origin/master`'s. Commit `docs: Mac assistant spec and plan`.
- [ ] **Step 3:** Artifacts. In the worktree's `macos/`, compute what `scripts/setup.sh` would stamp: `GHOSTTY_REV` + `cat scripts/ghostty-patches/*.patch | shasum -a 256 | cut -c1-16`; `ZMX_REV` + `ZMX_TARGET` + `cat scripts/zmx-patches/*.patch scripts/zmx-patches/ghostty/*.patch | shasum -a 256 | cut -c1-16`. Compare with the main checkout's `macos/.ghostty-build-stamp` and `macos/.zmx-build-stamp`.
  - Ghostty set matches: symlink `GhosttyKit.xcframework`, `Elis/Resources/ghostty`, `Elis/Resources/terminfo`, `.ghostty-build-stamp` (absolute targets).
  - zmx set matches: symlink `Elis/Resources/zmx`, `.zmx-build-stamp`.
  - A set that differs: link none of it; `scripts/setup.sh` builds it locally.
- [ ] **Step 4:** `cd macos && ./scripts/setup.sh && xcodegen generate`. Expected: exit 0, no libghostty or zmx rebuild for a linked set.

### Task 1: ElisCore — window state and selection fallback

**Files:**
- Modify: `shared/ElisCore/Sources/ElisCore/AppStore.swift` (one stored line; the setter's call; the `controlTree` return's last argument line)
- Modify: `shared/ElisCore/Sources/ElisCore/AppStore+SidebarSelection.swift`, `AppStore+Snapshot.swift:39-43`, `ControlProjection+Tree.swift` (`ControlTree`)
- Test: create `shared/ElisCore/Tests/ElisCoreTests/AssistantShownTests.swift`

**Interfaces — Produces:**
- `AppStore.assistantShown: Bool` (public, observable, transient: not in `Snapshot`).
- `AppStore.selectionDidChange(previous: UUID?)` (internal, in `AppStore+SidebarSelection.swift`): sets `assistantShown = false` when the new selection is non-nil and `restoringSelection` is false, then calls `emitSessionSelected(previous:)`. The `selectedSessionID` setter calls it in place of `emitSessionSelected`.
- `ControlTree.assistantShown: Bool?` with init parameter `assistantShown: Bool? = nil` (last); `controlTree(...)` passes `assistantShown ? true : nil`.
- `persistedSelection`: a nil selection falls back like an unpersistable one (MRU, then first persistable).

- [ ] **Step 1: Write the failing tests** (`AssistantShownTests`, swift-testing):
  - `selectingASessionHidesTheChat`: `store.assistantShown = true; store.selectedSessionID = id` → `#expect(store.assistantShown == false)`.
  - `clearingTheSelectionKeepsTheChat`: shown, selection set to nil → `#expect(store.assistantShown)`.
  - `restoreDoesNotHideTheChat`: shown, then `restore(from:)` of a snapshot with a selection → `#expect(store.assistantShown)` (a reload is not a selection).
  - `treeReadsBackAssistantShownOnlyWhenTrue`: encoded `controlTree(...)` JSON has `"assistantShown":true` when shown and no `assistantShown` key otherwise.
  - `nilSelectionPersistsTheMostRecentSession`: two sessions, select A then B, set selection nil → `#expect(store.snapshot().selectedSessionID == B)`.
- [ ] **Step 2: Run** `cd shared/ElisCore && swift test --filter AssistantShownTests`. Expected: FAIL (missing members).
- [ ] **Step 3: Implement** the Interfaces above.
- [ ] **Step 4: Run** the Step 2 command. Expected: PASS. Then `wc -l Sources/ElisCore/AppStore.swift` ≤ 1000.
- [ ] **Step 5: Commit** `feat(core): assistantShown and the nil-selection fallback`.

### Task 2: `AssistantRunner` and `AssistantModel`

**Files:**
- Create: `macos/Elis/AssistantRunner.swift`, `macos/Elis/AssistantModel.swift`
- Modify: `macos/Elis/SessionLaunchers.swift` (keep the detected PATH and the detection task)
- Modify: `linux/tests/fixtures/fake-provider.sh:40`: macOS `/bin/bash` 3.2 rejects `read -t 0.3` ("invalid timeout specification"), so the fake never marks ` early` there. Use `-t "$wait"` with `wait=0.3`, and `wait=1` when `BASH_VERSINFO[0] < 4`; Linux behavior is unchanged.
- Test: create `macos/ElisTests/AssistantRunnerTests.swift`

**Interfaces — Consumes:** ElisCore `AssistantChat`, `AssistantProvider.launch/turn/choices`, `AssistantStream.encode/decode`, `AssistantPrompt.system/inline`, `AssistantDirectory`.

**Interfaces — Produces:**
- `SessionLaunchers.path: String?` (the PATH the last detection searched; nil before the first one finishes) and `static func settled() async` (awaits the in-flight detection).
- `@MainActor final class AssistantRunner`:
  - `init(chat: AssistantChat, stateDirectory: URL?, standIn: [String]?, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, now: @escaping () -> Date = Date.init)`; `standIn` replaces argv[0] (tests), parsed from `ELIS_ASSISTANT_PROVIDER_CMD` by `static func standInFromEnvironment() -> [String]?`.
  - Hooks set by the host: `var peers: () -> [AssistantPeer]`, `var emit: (AssistantEntry) -> Void`, `var changed: () -> Void`.
  - `func providers() -> [SessionLauncher]`: with a `standIn`, `AssistantProvider.choices(SessionLauncher.allCases)` (the stand-in plays every provider, so tests, the UI-test app and the show-me instance need no installed agent); else `AssistantProvider.choices(SessionLaunchers.available)`. With a `standIn` the runner neither waits for `SessionLaunchers.settled()` nor needs `SessionLaunchers.path` (it falls back to the app's PATH).
  - `func enqueue(_ streamText: String)`, `func providerChanged(_ provider: SessionLauncher)`, `func clear()`, `func stopForQuit()` (SIGTERM, wait ≤ 2 s, SIGKILL), `func checkWatchdog()` (fails the turn with "the assistant stopped responding" when `now()` is ≥ 10 min past the last output of a busy turn; a 30 s repeating `Timer` calls it), `var pid: Int32?` (test read-back).
  - `static func environment(base: [String: String], stateDirectory: String, path: String, launch: [String: String]) -> [String: String]`.
- `@MainActor @Observable final class AssistantModel`: `let chat: AssistantChat`, `let runner: AssistantRunner`, `private(set) var entries: [AssistantEntry]`, `unread: Int`, `running: Bool`, `provider: SessionLauncher?`, `providers: [SessionLauncher]`; `var perform: (ControlRequest) async -> ControlResponse` (installed by Task 3; default answers unsupported); `init(stateDirectory: URL?, standIn: [String]? = AssistantRunner.standInFromEnvironment())` builds `AssistantChat(file: stateDirectory?/assistant/chat.jsonl)`; `func refresh()` copies chat state; the runner's `changed` calls it.

Behavior follows `assistantrunner.cpp` case by case: lazy start on the first input after `SessionLaunchers.settled()`; saved provider, else the first available saved through `chat.provider`; no provider → `providerFailed("no assistant provider installed")`; `stateDirectory` nil → `providerFailed("the assistant is off in this instance")`; cwd and created dir `<stateDir>/assistant/`; argv[0] resolved on the new PATH; stream mode keeps one `Process` with stdin a `Pipe`, per-input mode one `Process` per turn with `/dev/null` stdin; the first input of a fresh process carries `preamble`, plus `AssistantPrompt.inline(chat.settledEntries(last: 50))` after a provider change or a lost conversation; stdout split on `\n`, decoded, text collected per turn into one `.assistant` entry (none for a turn with no text), then `turnEnded()`; an error turn → `turnFailed`; a stream process that dies before naming its conversation after a resume forgets that resume id and retries the input once fresh with the chat inlined, else `providerFailed` with the exit reason and the last stderr line; provider change: SIGTERM, SIGKILL after 3 s, the cut turn goes to the new provider; clear: stop, drop the queue.

- [ ] **Step 1: Write the failing tests** (`AssistantRunnerTests`, XCTest, temp state dir per test, fake provider via `#filePath`, every wait bounded at 30 s and polling `chat`):
  - `testTwoQueuedAsksRunAsTwoTurnsInOrder`: enqueue "a", "b" → entries `.assistant` texts `["pid N: a", "pid N: b"]`, same pid, `chat.running == false`.
  - `testFakeMarksAnEarlyLine`: pipe two input lines straight into `/bin/bash fake-provider.sh` → the first answer ends with ` early` (proves the next test can fail).
  - `testSecondInputWaitsForTheTurnEnd`: enqueue "a" and "r" back to back → neither answer ends with ` early`.
  - `testEnvironmentScrubsElisAndClaudeMarkers`: `AssistantRunner.environment(base: ["ELIS_SESSION_ID": "x", "CLAUDECODE": "1", "CLAUDE_CONFIG_DIR": "/c", "HOME": "/h"], stateDirectory: "/s", path: "/p", launch: ["K": "v"])` == `["CLAUDE_CONFIG_DIR": "/c", "HOME": "/h", "ELIS_STATE_DIR": "/s", "PATH": "/p", "K": "v"]`; and an end-to-end `env` input answers `"<stateDir> <bundle Contents/MacOS>:…"` without ` leaked`.
  - `testMissingBinaryYieldsOneErrorAndStopsRunning`: `standIn: ["/nonexistent/elis-fake-provider"]` → exactly one `.error` entry, `running == false`.
  - `testCrashMidTurnYieldsOneErrorAndNextInputRestarts`: enqueue "crash" → one `.error` entry; enqueue "x" → answer from a new pid.
  - `testGoneResumeRetriesFreshWithTheChatInlined`: `chat.resume[.claude] = "gone"`, enqueue "x" → one `.assistant` entry, no `.error`, `chat.resume[.claude] != "gone"`.
  - `testProviderChangeRestartsWithTheRecap`: after one turn, `providerChanged(.codex)` → next answer comes from the `exec` path and its text contains the first turn's input (the inlined recap).
  - `testWatchdogFailsASilentTurn`: injected clock; enqueue "quiet-forever" (a stand-in `sleep 600` script written in the test), advance the clock 10 min + 1 s, `checkWatchdog()` → one `.error` "the assistant stopped responding", `running == false`.
  - `testClearAndQuitLeaveNoChild`: after a turn, `clear()` → `kill(pid, 0) != 0` within 5 s; same for `stopForQuit()`.
  - `testNoStateDirectoryRefusesToSpawn`: `stateDirectory: nil` → one `.error`, no pid.
- [ ] **Step 2: Run** HOSTED with `-only-testing:ElisTests/AssistantRunnerTests`. Expected: FAIL (types missing).
- [ ] **Step 3: Implement** the Interfaces. `Process.terminationHandler` and pipe `readabilityHandler` closures are `@Sendable` and hop with `DispatchQueue.main.async` (CLAUDE.md libdispatch rule); never `assumeIsolated` from them.
- [ ] **Step 4: Run** the Step 2 command. Expected: PASS, 11 tests. The fixture change is Linux-neutral; the lead decides whether a Linux `ctest` run is needed for it.
- [ ] **Step 5: Commit** `feat(macos): assistant provider runner and model`.

### Task 3: `ControlActions` adapter, show action, menu, palette, quit

**Files:**
- Create: `macos/Elis/Control/ControlServer+Assistant.swift`, `macos/Elis/AppActions+Assistant.swift`
- Modify (ElisCore): `shared/ElisCore/Sources/ElisCore/BuiltinAction.swift`, `PaletteCatalog.swift`; tests `BuiltinActionTests.swift:48,151`, `PaletteCatalogTests.swift:77`; `.claude/rules/keymap.md:73` (count, stale at 57, becomes 59). They land here, not in Task 1, because the app's exhaustive `switch` in `AppActions+Palette.swift` must gain its arm in the same commit.
- Modify: `macos/Elis/Control/ControlServer.swift:720` (one argument, zero lines), `macos/Elis/AppActions.swift` (`var assistant`), `macos/Elis/elisApp.swift` (model with state dir, `controlServer.installAssistant()` beside `installRemoteLinkClicks()`), `macos/Elis/AppDelegate.swift:394` (`actions?.assistant.runner.stopForQuit()` before `controlServer?.stop()`), `macos/Elis/elisApp+Menus.swift` (Navigate ▸ Show Elis after Dashboard), `macos/Elis/AppActions+Palette.swift` (`case .showAssistant`), `macos/Elis/Views/SessionSwitcher.swift` (`begin`)
- Docs: `.claude/rules/control-api.md` (one bullet after "Message bus": the Mac host's assistant members live in `ControlServer+Assistant`, the model on `AppActions`, events through `emitAppEvent`), `macos/ARCHITECTURE.md` (one line each: `AssistantRunner`, `AssistantModel`), `site/commands.html:4102`, `plugins/elis/skills/elis/SKILL.md:181,759`, `reference.md:2144`, `linux.md:35` (drop "macOS later": "in the macOS and Linux apps"); `show_assistant` at every place `git grep -n show_attention -- site plugins README.md` lists built-in names (`site/docs.html:1430` at least)
- Test: create `macos/ElisTests/ControlServerAssistantTests.swift`, `macos/ElisTests/SessionSwitcherStartTests.swift`

**Interfaces — Consumes:** Task 1 `assistantShown`; Task 2 `AssistantModel`, `AssistantRunner` hooks.

**Interfaces — Produces:**
- `BuiltinAction.showAssistant = "show_assistant"`, `defaultChord` nil.
- `PaletteCommand.showAssistant`: `title` "Show Elis", `builtinAction` `.showAssistant`; in `isCoveredByModal` it joins the `.dashboard` arm (`terminalZoomActive || pickerActive`), because showing the chat closes an open dashboard; no presence term.
- `AssistantModel.onScreen: () -> Bool` (default `{ false }`): `refresh()` calls `chat.markSeen()` first when it is true, as Linux's `refreshAll` does ("a reply in front of you is not unread"). `installAssistant()` sets it to: some open window's store has `assistantShown`, and its `NSWindow` is key and not miniaturized.
- `AppActions.assistant: AssistantModel` (default `AssistantModel(stateDirectory: nil)`); `AppActions(library:)` unchanged; `elisApp` assigns `AssistantModel(stateDirectory: stateDirectory)` before building `ControlServer`.
- `AppActions.showAssistant(in store: AppStore)`: closes that window's dashboard (`DashboardControllerRegistry`), sets `selectedSessionID = nil`, `assistantShown = true`, `assistant.chat.markSeen()`, `assistant.refresh()`, posts `.elisFocusAssistantComposer` with `object: store`.
- `AssistantModel.peers: () -> [AssistantPeer]` (default `{ [] }`), added here.
- `ControlServer.installAssistant()`: wires the runner's `peers` and `emit`, and the model's `peers` and `perform` (`{ await self.dispatch($0) }`).
- `ControlServer` `ControlActions` members: `assistantPeers()` (open windows in `library.openIDs()` order, workspaces and sessions in sidebar order, local terminal sessions only (no page rows: they have no shell to type into; companions are peers as on Linux), ids as the tree spells them, `agent`/`status` as the tree node carries them), `assistantProviders()` (`actions.assistant.runner.providers()`, the one source), `assistantInput` (emit, `runner.enqueue`, refresh), `assistantSent` (emit, refresh), `assistantProviderChanged` (`runner.providerChanged`, refresh), `assistantSeen` (refresh), `assistantCleared` (`runner.clear`, emit `assistant.cleared`, refresh), `showAssistant(window:)` (`resolver.resolvePlacementStore(window)` → `actions.showAssistant(in:)`; any open window, a remote window included).
- `func emitAssistantMessage(_ entry: AssistantEntry)` (handle from `AssistantDirectory(assistantPeers() ?? [])`).
- `SessionSwitcher.startIndex(hasSelection: Bool, count: Int) -> Int?`: `hasSelection` → 1 when `count > 1`; no selection → 0 when `count > 0`; else nil. `begin()` uses it, so one Ctrl-Tab from the chat returns to the most recent session.

- [ ] **Step 1: Write the failing tests** (`ControlServerAssistantTests`, built like `ControlServerMessagesTests.setUp` with `AppActions(library:)` whose `assistant` is `AssistantModel(stateDirectory: stateDir, standIn: fake)`, then `server.installAssistant()`):
  - `testShowReadsBackAndClearsSelection`: `assistant.show` → tree `assistantShown == true`, `selectedSessionID == nil`, a `session.selected` event with no session; `session.go` to a session → `assistantShown` absent.
  - `testShowClosesTheDashboard`: open `dashboard --mru`, `assistant.show` → tree `dashboardMembers` empty.
  - `testChatSurvivesBackgroundCloseAndModeSwitch` (Review Focus 1): shown; `session.close` of a non-selected session, `session.new --no-select`, `sidebar.mode flagged` then `tree` → still `assistantShown == true`, selection nil.
  - `testRemoteRowIsNoPeer` (Review Focus 5): one local and one `remoteHost: "mac2"` session → tree `handle` set only on the local node; `assistant.send --to <remote id> hi` fails naming the tag; nothing typed.
  - `testAskRunsATurnThroughTheFakeProvider`: `assistant.ask hi` → within 30 s `assistant.read` ends with an `assistant` entry, tree `assistant.running == false`; `events.read` has `assistant.message` kinds `user`, `assistant`.
  - `testProviderDeathYieldsOneErrorEntry`: `assistant.ask crash` → exactly one `error` entry; `assistant.provider codex` then `assistant.ask x` → answer via `exec`.
  - `testClearStopsTheProcessAndEmitsCleared`: after a turn, `assistant.clear` → runner `pid` nil within 5 s, event `assistant.cleared`, `assistant.read` empty.
  - `testChatPersistsAndReloads`: after a turn, a new `AssistantModel(stateDirectory: stateDir)` has the same entries; `<stateDir>/assistant/chat.jsonl` exists.
  - `testReplyWhileTheChatIsOnScreenIsNotUnread`: `model.onScreen = { true }`, `assistant.reply` from a session → tree `assistant.unread == 0`; with `{ false }` → 1.
  - `SessionSwitcherStartTests.testStartIndex`: `(true, 1) == nil`, `(true, 3) == 1`, `(false, 1) == 0`, `(false, 0) == nil`.
  - ElisCore: `BuiltinActionTests` count `58` → `59`, chord table gains `.showAssistant: nil`, `BuiltinAction(rawValue: "show_assistant") == .showAssistant`; `PaletteCatalogTests` count `66` → `67`, `.showAssistant` enabled with no active session and with only the dashboard open, disabled under terminal zoom and an open picker.
- [ ] **Step 2: Run** `cd shared/ElisCore && swift test --filter 'BuiltinActionTests|PaletteCatalogTests'`, then HOSTED with `-only-testing:ElisTests/ControlServerAssistantTests -only-testing:ElisTests/SessionSwitcherStartTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the Interfaces. Then `grep -rn "keys.sorted()\|Set(.*\.keys)" macos/ElisTests macos/ElisUITests` and update any test pinning the full tree key set (the tree now carries `assistant` and `handle`).
- [ ] **Step 4: Run** the Step 2 commands. Expected: PASS. `wc -l macos/Elis/Control/ControlServer.swift` = 1000, `macos/Elis/AppActions.swift` ≤ 995. `assistant.show --window` on a remote window has no test (building one is heavy); the PR says so.
- [ ] **Step 5: Docs** listed under Files, one clause each; no catalog count anywhere.
- [ ] **Step 6: Commit** `feat(macos): assistant control host, Show Elis and the quit stop`.

### Task 4: Pinned Elis row in the sidebar

**Files:**
- Create: `macos/Elis/Views/WorkspaceSidebar+Assistant.swift`
- Modify (hooks only; the exact hook sites in the Coordinator are the builder's call, per the spec): `macos/Elis/Views/WorkspaceSidebar.swift` (≤ 20 lines: data source child 0, expandability, selection sync, selection delegate), `WorkspaceSidebar+RowRendering.swift` (row view), `WorkspaceSidebar+DragDrop.swift` (no drag from it, no drop on or above it), `WorkspaceSidebar+ContextMenu.swift` (no menu), `WorkspaceSidebar+Bands.swift` (skip)
- Test: create `macos/ElisTests/SidebarAssistantRowTests.swift`

**Mockup frames:** pinned row unselected; pinned row selected; row with unread badge; each in light and dark.

**Interfaces — Consumes:** the approved Mac mockup frames above, `store.assistantShown`, `actions.showAssistant(in:)`, `actions.assistant.unread`.

**Interfaces — Produces:** a `SidebarNode` kind `.assistant` cached once per Coordinator, always the outline's first root row in tree, flat and flagged modes (both flagged layouts). Content: the app's dog icon (the asset the About panel and Linux `:/elis.png` use), "Elis", the unseen badge view sessions use with `unread`. Accessibility identifier `assistant-row` (Task 5's UI test clicks it). Selecting it calls `showAssistant(in:)`; `syncSelection` selects it exactly while `assistantShown`, and selects no row when selection is nil and the chat is hidden; programmatic selection never calls `showAssistant` again.

- [ ] **Step 1: Write the failing tests** (mounted outline as `SidebarDensityTests` does):
  - `testRowIsFirstInEveryMode`: `outline.item(atRow: 0)` is the assistant node in tree, flat, flagged-tree and flagged-flat.
  - `testClickShowsTheChat`: selecting row 0 → `store.assistantShown`, `selectedSessionID == nil`, `outline.selectedRow == 0`.
  - `testSessionClickHidesTheChat`: then select a session row → `assistantShown == false`, the pill on that row.
  - `testReloadWithNilSelectionSelectsNothing`: chat hidden, selection nil, `rebuildAndReload()` → `selectedRow == -1`, selection still nil.
  - `testRowIsNotDraggableNorADropTarget`: `pasteboardWriterForItem` nil; validate-drop of a session above or on row 0 → `[]`.
  - `testUnreadBadgeRepaints`: `chat.append(.reply, …)`, `assistant.refresh()` → the row's badge shows "1".
- [ ] **Step 2: Run** HOSTED with `-only-testing:ElisTests/SidebarAssistantRowTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Row-index sweep.** The pinned row shifts every row index. `grep -rln "outlineRows.firstMatch\|outlineRows.element(boundBy\|outlineRows.count\|item(atRow:\|numberOfRows\|row(forItem:" macos/ElisTests macos/ElisUITests` (about 20 files today: the `Sidebar*Tests`, `WorkspaceSidebar*Tests`, `RestoreTerminalSizeTests`, `FileTreeViewTests`, `ControlSidebarStatusUITests`). Fix each index assumption (skip the assistant row, never hard-code +1 where an identifier can find the row).
- [ ] **Step 5: Run** HOSTED with `-only-testing:ElisTests/SidebarAssistantRowTests` plus one `-only-testing:ElisTests/<Class>` per hosted class the sweep found, then `cd macos && xcodebuild test -project Elis.xcodeproj -scheme Elis -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:ElisUITests/ControlSidebarStatusUITests` (`make test-app` does not run UI tests). Expected: PASS.
- [ ] **Step 6: Commit** `feat(macos): pinned Elis row`.

### Task 5: Chat view, composer, key routing

**Files:**
- Create: `macos/Elis/Views/AssistantView.swift`, `macos/Elis/Views/AssistantComposer.swift`
- Modify: `macos/Elis/Views/WindowContentView+Detail.swift` (show `AssistantView` while `store.assistantShown`; `deckInteractive` also requires `!store.assistantShown`), `site/docs.html:582-590` (state Mac and Linux; the row drop and `show_assistant`)
- Test: create `macos/ElisTests/AssistantComposerTests.swift`, `macos/ElisUITests/AssistantUITests.swift`

**Mockup frames:** chat empty state; conversation with user messages, markdown answers, reply cards and a sent-to card; composer with tag chips; `@` completion; provider picker; drag-onto-composer drop highlight; clear-chat affordance; each in light and dark.

**Interfaces — Consumes:** the approved Mac mockup frames above, `AssistantModel` (`entries`, `running`, `provider`, `providers`, `perform`, `peers`), `AssistantDirectory(model.peers())` for handles, `sessionPasteboardType`, `workspacePasteboardType`.

**Interfaces — Produces:**
- `AssistantView(model:store:)`: cards — user and sent on the right, assistant and reply on the left, error as an error card; a reply card names its session handle and a "go to session" control that runs `session.go`; markdown through `Text(AttributedString(markdown:options: .init(interpretedSyntax: .full)))`; clear-chat button (confirm, then `assistant.clear`, disabled when empty).
- `AssistantComposer` (`NSViewRepresentable` over an `NSTextView` subclass in the chrome of `AskFormViews.swift`'s field): tags shown as chips (attributed background) in place in the text; `@` completion over local handles, `@ws:<handle>`, `@all`; provider picker listing `model.providers` by `title` (runs `assistant.provider <raw>`); send button; Return sends `assistant.ask <text>`, Shift-Return inserts a newline; Escape closes an open completion or picker, else nothing; registers `sessionPasteboardType` and `workspacePasteboardType`: a local session drop inserts `@<handle> `, a workspace drop `@ws:<handle> `, a remote or unknown row returns `[]` from `draggingEntered`; every edit calls `store.noteUserActivity()`; becomes first responder on `.elisFocusAssistantComposer` for its store.

- [ ] **Step 1: Implement** the Interfaces to the mockup frames above; reuse existing components (the ask field, the sidebar's badge) only where the mockup shows them as they are. If native markdown cannot match the mockup's lists or code blocks, switch the cards to `HudMarkdown.lines` (made `public`) mapped to SwiftUI runs and say so in the PR.
- [ ] **Step 2: Design check, then the owner.** Run Task 6 against this build until its reviewer reports no defect. Then show the owner (CLAUDE.md: the rendered result before tests): leave the Task 6 instance running, send the lead how to reach it, and wait for the owner's go. Stop that instance by its pid before the next build.
- [ ] **Step 3: Write the hosted tests** (`AssistantComposerTests`):
  - `testReturnSendsAndShiftReturnInsertsANewline`: Return with "hi" → `perform` got `.assistantAsk` text "hi", field empty; Shift-Return → text contains "\n", nothing sent.
  - `testRemoteRowDropIsRefused`: a pasteboard with a remote session id → `draggingEntered` `[]`, text unchanged; a local id → text `"@<handle> "`.
  - `testEditNotesUserActivity` (Review Focus 2): after an edit, the window's tree `idleMs` < 1000.
- [ ] **Step 4: Write the UI test** `AssistantUITests` (`launchForUITest`, temp state dir, launch environment `ELIS_ASSISTANT_PROVIDER_CMD="/bin/bash <#filePath-derived abs path>/linux/tests/fixtures/fake-provider.sh"`, which also makes every provider available):
  - `testChatAnswersAndTheTerminalGetsNothing`: select a session, click `assistant-row`, type `marker-123⏎` → an assistant card containing `pid` and `marker-123` appears within 30 s; `elisctl session text --target <that session> --socket <test socket>` does not contain `marker-123`.
  - `testDraggingASessionRowAddsItsChip`: drag the session row onto the composer → the composer's value starts with `@<handle>`.
- [ ] **Step 5: Run** HOSTED with `-only-testing:ElisTests/AssistantComposerTests`, then `cd macos && xcodebuild test -project Elis.xcodeproj -scheme Elis -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:ElisUITests/AssistantUITests`. Expected: PASS. A test that passes at once is checked by breaking its behavior once (e.g. drop the `noteUserActivity` call) and seeing it fail. Then `lsappinfo list | grep -A4 elis.debug`: no `exited-with-subordinates` entry with `relatedCoalitionPIDs`.
- [ ] **Step 6: Commit** `feat(macos): Elis chat view and composer`.

### Task 6: Design verification against the approved Mac mockup

**Files:** none new; fixes land in the Task 4/5 files. Captures go to the scratchpad, never the repo.

**Interfaces — Consumes:** the approved Mac mockup (every frame Tasks 4 and 5 name), the Task 9 Step 4 launch recipe.

- [ ] **Step 1: Launch** an isolated Debug instance by the Task 9 Step 4 recipe, plus `--env ELIS_ASSISTANT_PROVIDER_CMD="/bin/bash <abs path>/linux/tests/fixtures/fake-provider.sh"`. Announce each action on it to the lead.
- [ ] **Step 2: Stage each frame's state** through the instance's own socket (`--socket /tmp/elis-asst/elis.sock`, Debug binary's full path): empty chat (`assistant clear`); a conversation (`assistant ask` with a markdown answer, `assistant send --to @<handle>`, `reply` from a session's `ELIS_SESSION_ID`); unread badge (reply while a session is selected); row selected and unselected; tag chips, `@` completion, provider picker, drop highlight, clear-chat affordance by hand in the composer. Do each in light and dark (`theme.set` or the system appearance).
- [ ] **Step 3: Capture in-process.** The Debug instance captures its own window (`CGWindowListCreateImage` through `dlsym`, or `cacheDisplay` of the content view), because `screencapture` from the live terminal can be TCC-denied. One PNG per frame and appearance, named after the frame.
- [ ] **Step 4: Designer review.** Send the lead the capture paths and the mockup frame names; the lead hands them to a separate designer reviewer (never the implementer). The reviewer compares frame by frame, light and dark: layout, positions, spacing, type, colours, content, states. It returns a list of differences, each marked defect or acceptable.
- [ ] **Step 5: Fix** every difference marked a defect in the Task 4/5 files, rebuild (stop the instance and its daemons by pid first), and repeat Steps 1-4 for the affected frames.
- [ ] **Step 6: Pass** when the reviewer reports no defect. Rerun the targeted Task 4 and Task 5 test commands once after the last fix. Expected: PASS. Commit the fixes `fix(macos): match the Elis assistant to the mockup`.

### Task 7: Remote exception in docs and the server policy

**Files:**
- Modify: `docs/superpowers/specs/2026-11-21-elis-assistant-design.md` "Remote and phone" (~171-178): local only; remote rows are no targets and have no handle; no reply route; elis-server refuses every `assistant.*`; the phone connected to a host gets the row through that host's tree. Delivery item 3: Mac, local sessions only.
- Delete: `macos/docs/backlog/assistant-remote-reply-route.md`
- Modify: `server/Tests/ElisServerTests/ServerCommandPolicyTests.swift:40` key → `"the assistant is local only"`
- Modify: `.claude/rules/control-api.md` (one bullet: the remote exception and its owner date), `plugins/elis/skills/elis/SKILL.md:181` ("local sessions only"), `site/docs.html` assistant section and `site/commands.html` tree `handle` line (remote rows have no handle)

- [ ] **Step 1:** Edit the files. `git grep -n "assistant-remote-reply-route"` → no hits.
- [ ] **Step 2: Run** `cd server && swift test --filter ServerCommandPolicyTests`. Expected: PASS.
- [ ] **Step 3: Commit** `docs: the Elis assistant is local only`.

### Task 8: Manual checks — stdin EOF and TCC

**Files:** none unless the fallback triggers (`macos/Elis/AssistantRunner.swift`, `AssistantRunnerTests.swift`).

Use an isolated Debug instance (Task 9 Step 4 recipe) WITHOUT the provider stand-in, with the real installed providers. Announce each action on the instance to the lead before doing it. Stop it only by its pid; after each `kill -9`, stop that instance's leftover daemons by pid (`ps` for its `zmx`/`elis-session-host` under `/tmp/elis-asst`) before any relaunch or rebuild, and confirm `lsappinfo list | grep elis.debug` shows no lingering tile.

- [ ] **Step 1: stdin EOF.** For each installed provider (`claude`, `agy` stream; `codex`, `opencode` per-input): pick it, ask "count slowly to 200, one number per line", note the provider's pid (`ps -o pid,ppid,command` children of the instance), then `kill -9 <instance pid>` and poll `kill -0 <provider pid>` every second. Pass: every provider process is gone within 10 s. Record the result per provider in the PR.
- [ ] **Step 2: Fallback, only if Step 1 failed for any provider:** the runner writes `<stateDir>/assistant/provider.pid` (`<pid> <start time from proc_pidinfo>`) on every spawn and removes it on exit; `AssistantModel.init` terminates that pid when both still match. Test `testStalePidfileProcessIsTerminatedOnLaunch` (spawn `sleep 600`, write its pidfile, new model → process gone within 5 s; a pidfile whose start time differs leaves the process alone). Run HOSTED `-only-testing:ElisTests/AssistantRunnerTests`; commit `fix(macos): end a provider left by a killed app`.
- [ ] **Step 3: TCC per service.** A TCC prompt needs a person at the Mac (the owner may have only the phone): ask the lead to schedule this step with the owner before starting it. In the instance, `log stream --predicate 'subsystem == "com.apple.TCC"' --style compact` in a separate terminal. For Documents, Desktop, Downloads, a removable volume, and Local Network (a LAN `curl`): first run the access from a pane, then ask the assistant to do the same ("list ~/Documents", …). Record, per service, the responsible process and the subject tccd logs for the provider. Pass: the subject is `ua.naiksoftware.elis.debug` as for the pane, and after the pane's grant the provider gets no further prompt and no denial. For Local Network, wait 30 s after a fresh build before judging (nehelper cache).
- [ ] **Step 4: If Step 3 fails** (a prompt per launch, or a silent denial): stop, send the lead the tccd lines; the spec's fallback (spawn the provider through the `elis-session-host` path panes use, `ZmxLaunch.swift:61`) becomes a new task the lead plans. Do not open the PR before it lands.

### Task 9: Gates, review, show me, PR

- [ ] **Step 1: Gates, once.** In `macos/`: `make build`, `make test`, `make test-app`, `make lint`. Expected: all exit 0, zero lint findings. Look up any intermittent failure in `docs/ci-flakes.md` first. Then `lsappinfo list | grep -A4 elis.debug` (stop only leaked test pids; report anything else).
- [ ] **Step 2: Independent review.** Report the branch to the lead, who runs `cross-model-review` (or `/code-review`) on `git diff origin/master...HEAD` (an executor spawns no agents); verify each finding against the code before acting.
- [ ] **Step 3: Rebuild** after review fixes: stop any isolated instance of this DerivedData first (its daemons too), then `make build`.
- [ ] **Step 4: Show me.** Write `{"workspaceGuideDone":true}` to `/tmp/elis-asst/settings.json`, then:
  ```bash
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      -u ELIS_SESSION_ID -u ELIS_SOCKET -u ELIS_STATE_DIR -u ELIS_WINDOW_ID \
      -u GHOSTTY_RESOURCES_DIR -u GHOSTTY_BIN_DIR -u GHOSTTY_SHELL_FEATURES \
      open -n --env ELIS_STATE_DIR=/tmp/elis-asst macos/build/DerivedData/Build/Products/Debug/Elis.app
  ```
  Name every `CLAUDE*`, `ELIS_*`, `GHOSTTY_*` variable `env | grep -E '^(CLAUDE|ELIS_|GHOSTTY_)'` shows, not only these. Verify with `ps eww -p <pid>` that only `ELIS_STATE_DIR=/tmp/elis-asst` remains of them. Wait ≤ 10 s for `/tmp/elis-asst/elis.sock`; if absent, stop that pid and relaunch without `-g`. Leave it running and tell the owner: click the Elis row; Navigate ▸ Show Elis; drag a session row onto the composer; CLI with the Debug binary's full path and `--socket /tmp/elis-asst/elis.sock`.
- [ ] **Step 5: PR.** Push the branch and open a PR to `master`: what the Mac host adds, the deviations from the spec (tree `assistantShown`, model on `AppActions`, five ElisCore changes, events through `emitAppEvent`, page rows not peers, no test for `assistant.show` on a remote window), Task 8's per-provider and per-service results, the markdown route taken. End the body with the session link from the attribution reminder. After merge: verify the merge commit on fetched `origin/master`, then remove the worktree without changing the main checkout's branch.
