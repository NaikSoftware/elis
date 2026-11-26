# Session Progress Fill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A session row in the sidebar fills left to right with the session's progress, from an agent's plan
(`elisctl session progress 3/7`) or from a program's OSC 9;4 progress report, on macOS, elis-server rows and Linux.

**Architecture:** `ElisCore` owns the progress value, its two parsers (control argument, OSC 9;4), the clear rules
and the fill/wave decision. Each app keeps only the side effects: the Mac's libghostty callback and `SidebarRowView`
layer, the Linux Konsole OSC hook and `SidebarDelegate` paint. Linux reaches the shared parsers and fill decision
through the JSON bridge (`linux/bridge`); its `Store` keeps a C++ mirror of the model field, as it does for status.

**Tech Stack:** Swift 6 (`ElisCore`, `elisctlKit`, elis-server, AppKit app), C++/Qt6 (Linux), bash (agent-status hooks).

**Spec:** this plan carries the owner's decisions (2026-11-26) below; there is no separate spec. Design canvas:
https://claude.ai/artifact/4UfLJ2bngZGQgTk3LZo7Fr — variant **A · Flat wash** was chosen.

## Decisions (the spec)

- **Two sources, one row.** `control` progress comes from `session.progress`; `terminal` progress comes from OSC 9;4.
  The row shows `control` when set, else `terminal`. Each source clears only itself.
- **Control argument:** `N/M` (steps, `1 ≤ M ≤ 10000`, `0 ≤ N ≤ M`), `P%` (`0…100`), `indeterminate`, `clear`.
  Anything else is refused with `invalid progress`.
- **OSC 9;4 states** (ConEmu numbering, same as `ghostty_action_progress_report_state_e`): `0` clears;
  `1`, `2` (error) and `4` (pause) set `P%` when `0 ≤ P ≤ 100`, else indeterminate; `3` sets indeterminate.
- **Clears itself:**
  - `control` clears on a status *change* into `completed` or `idle`, and on `clear`. The rule keys on the status
    the app receives, not on the hook event: `elis-claude-status.sh` rewrites a Stop with a busy teammate, a
    running background agent or a session cron to `active --blink`.
  - `terminal` clears on OSC state 0 from the same pane, when that pane closes, and 15 s after its last update.
- **Look (variant A):** fill width = fraction × row width, clipped to the row rect like the wave; one flat color at
  alpha `0.16` with a hard edge. Layers bottom to top: band, row wash, **progress fill**, wave,
  hover/selection, cell.
- **Color:** session tint → workspace tint → the `active` status color.
- **Blocked:** the row shows only the status: no fill, no wave.
- **Indeterminate:** no fill; the existing wave shows, even when the session has no agent status (status not
  `blocked`).
- **No Settings > Interface toggle.**
- **Remote:** `control` progress travels origin → viewer on the presentation stream. `terminal` progress needs no
  transport: OSC bytes reach the viewer Mac's own libghostty surface. elis-server parses no OSC.
- **Claude Code plan source** (probed on Claude Code 2.1.332): `PostToolUse` matcher `TodoWrite|TaskCreate|TaskUpdate`.
  `TodoWrite` carries the whole list in `tool_input.todos`; `TaskCreate`/`TaskUpdate` carry one task, so the hook
  counts `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tasks/<session_id>/*.json` with `"status":"completed"`. All done, or
  none, sends `clear`. A subagent's (`agent_id` set) todo tools never write the lead's row.

## Global Constraints

- `ElisCore` imports no AppKit/GhosttyKit/CoreGraphics; colors cross as `#rrggbb` hex strings (`SidebarBand.wave` style).
- A new `ControlActions` method gets a default in `ControlActionsDefaults.swift` (the `agterm-linux` fork conforms).
- New `PresentationSnapshot`/frame fields are optional, so an older peer decodes and ignores them.
- No existing `public` `ElisCore` signature narrows; `SidebarBand.wave` gains a defaulted parameter only.
- Comments: one line, only the non-obvious why. Test comments are rare.
- Run each full gate once at the end (Task 10); during tasks run only the named tests.
- Never execute `elis`/`elisctl` against the default socket; manual checks use an isolated Debug instance
  (short `/tmp` `ELIS_STATE_DIR`) per `CLAUDE.md`. Every delegated worker gets that rule verbatim.

## Review Focus

- Claude Code emits `OSC 9;4;3` and `9;4;0` around its own long operations (on by default,
  `terminalProgressBarEnabled`): its `9;4;0` must not erase plan progress set by `session.progress`. Test in Task 2.
- A hard-killed `cargo` leaves no `9;4;0`: the terminal fill must disappear after 15 s. Test in Task 2.
- Split panes: `9;4;0` from the right pane must not clear progress the left pane set. Test in Task 2.
- An older viewer or origin without the `progress` kind keeps decoding every other frame. Test in Task 4.
- A subagent's `TaskUpdate` (payload has `agent_id`) must not repaint the lead's row. Test in Task 7.

## Parallel execution

- Task 1 first; everything depends on it.
- Then in parallel: **Task 2** (store), **Task 3** (command), **Task 7** (hook script and installer table),
  **Task 8** (Linux bridge). They touch disjoint files.
- Task 4 after Task 2. Task 5 after Tasks 2 and 3. Task 9 after Task 8 (and Task 7's hook row for `installers.cpp`).
- Task 6 after Tasks 2, 3 and 4. Task 10 last.

---

## Before Task 1: worktree

- [ ] `git fetch origin master`, then create a native Claude worktree (EnterWorktree) named `session-progress`.
- [ ] Symlink the six ignored artifacts from the main checkout per `CLAUDE.md` "Worktrees and local builds", after the
  stamp check.

### Task 1: `SessionProgress` model, parsers and row decision (ElisCore)

**Files:**
- Create: `shared/ElisCore/Sources/ElisCore/SessionProgress.swift`
- Modify: `shared/ElisCore/Sources/ElisCore/SidebarBand.swift:29-34`
- Test: `shared/ElisCore/Tests/ElisCoreTests/SessionProgressTests.swift` (new), `SidebarBandTests.swift`

**Interfaces:**
- Produces:
  - `public enum SessionProgress: Sendable, Equatable, Codable { case steps(done: Int, total: Int); case percent(Int); case indeterminate }`
    with explicit coding `{"done":3,"total":7}` | `{"percent":40}` | `{"indeterminate":true}`.
  - `public var fraction: Double?` (nil for indeterminate), `public var label: String` (`"3/7"`, `"40%"`, `"indeterminate"`).
  - `public static func parse(_ text: String) throws(SessionProgressError) -> SessionProgress?` — nil means `clear`.
  - `public enum SessionProgressError: Error, Equatable { case invalid }` (message `invalid progress`).
  - `public enum TerminalProgressUpdate: Sendable, Equatable { case clear; case set(SessionProgress) }`
  - `public static func terminal(state: Int, progress: Int) -> TerminalProgressUpdate?` — nil for an unknown state.
  - `public static func conEmu(_ body: String) -> TerminalProgressUpdate?` — the OSC 9 body, e.g. `"4;1;40"`;
    nil when it does not start with `4;`.
  - `public enum ProgressSource: String, Sendable, Codable { case control, terminal }`
  - `public struct SidebarProgressFill: Sendable, Equatable { public let colorHex: String; public let fraction: Double; public static let alpha = 0.22; public static let feather = 26.0 }`
  - `SidebarBand.progressFill(progress: SessionProgress?, status: AgentStatus, sessionTintHex: String?, workspaceTintHex: String?, activeHex: String) -> SidebarProgressFill?`
  - `SidebarBand.wave(status:indeterminate:sessionTintHex:workspaceTintHex:activeHex:accentHex:)` — new
    `indeterminate: Bool = false` parameter after `status`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test(arguments: [("3/7", SessionProgress.steps(done: 3, total: 7)), ("0/1", .steps(done: 0, total: 1)),
                  ("40%", .percent(40)), ("100%", .percent(100)), ("indeterminate", .indeterminate)])
func parsesEachForm(text: String, expected: SessionProgress) throws { #expect(try SessionProgress.parse(text) == expected) }
@Test func clearParsesToNil() throws { #expect(try SessionProgress.parse("clear") == nil) }
@Test(arguments: ["8/7", "1/0", "-1/3", "101%", "40", "", "3/10001", "a/b"])
func refusesOutOfRange(text: String) { #expect(throws: SessionProgressError.invalid) { try SessionProgress.parse(text) } }
@Test func terminalStatesMapLikeConEmu() {
    #expect(SessionProgress.terminal(state: 0, progress: -1) == .clear)
    #expect(SessionProgress.terminal(state: 1, progress: 40) == .set(.percent(40)))
    #expect(SessionProgress.terminal(state: 2, progress: 70) == .set(.percent(70)))
    #expect(SessionProgress.terminal(state: 1, progress: -1) == .set(.indeterminate))
    #expect(SessionProgress.terminal(state: 3, progress: 0) == .set(.indeterminate))
    #expect(SessionProgress.terminal(state: 9, progress: 0) == nil)
}
@Test func conEmuBodyParses() {
    #expect(SessionProgress.conEmu("4;1;40") == .set(.percent(40)))
    #expect(SessionProgress.conEmu("4;0") == .clear)
    #expect(SessionProgress.conEmu("4;3;") == .set(.indeterminate))
    #expect(SessionProgress.conEmu("hello") == nil)
}
@Test func codingIsStable() throws // .steps(3,7) encodes to {"done":3,"total":7}; all three cases round-trip
```

In `SidebarBandTests.swift`:

```swift
@Test func fillUsesSessionThenWorkspaceThenActive() {
    #expect(SidebarBand.progressFill(progress: .steps(done: 3, total: 7), status: .active, sessionTintHex: "#a970ff",
            workspaceTintHex: "#ff9f43", activeHex: "#3ccf64")?.colorHex == "#a970ff")
    // nil session tint → "#ff9f43"; both nil → "#3ccf64"; fraction == 3.0 / 7
}
@Test func blockedAndIndeterminateDrawNoFill()   // .blocked → nil; .indeterminate → nil; nil progress → nil
@Test func fillFractionClampsToOne()             // .percent(100) → 1.0
@Test func indeterminateShowsTheWaveWithoutAgentStatus() {
    #expect(SidebarBand.wave(status: .idle, indeterminate: true, sessionTintHex: nil, workspaceTintHex: nil,
                             activeHex: "#3ccf64", accentHex: "#6b9bff") != nil)
    // .blocked with indeterminate: true → nil; .idle with indeterminate: false → nil
}
```

- [ ] **Step 2:** `cd shared/ElisCore && swift test --filter 'SessionProgressTests|SidebarBandTests'` — FAIL (types missing).
- [ ] **Step 3:** Implement. `parse` trims whitespace; percent needs the `%`; a bare number is refused.
  `progressFill` returns nil for nil/indeterminate progress or `.blocked`; fraction clamped to `0…1`.
  `wave` shows when `status == .active || (indeterminate && status != .blocked)`; colors unchanged.
- [ ] **Step 4:** Same command — PASS.
- [ ] **Step 5:** `git commit -m "feat(core): session progress model, parsers and row fill decision"`

### Task 2: Store state, clear rules, event and read-back (ElisCore)

**Files:**
- Create: `shared/ElisCore/Sources/ElisCore/AppStore+Progress.swift`
- Modify: `Session.swift` (fields), `AppStore+Status.swift:103-124` (`setAgentIndicator` edge), `AppStore+Status.swift:65`
  (`clearPaneStatus`), `ControlEvents.swift:5,69` (`ControlEventKind.progress`, payload fields),
  `ControlProjection.swift:203,330-352,448` (`ControlSessionNode.progress`), `AppStore.swift:455-461` (fill it)
- Test: `shared/ElisCore/Tests/ElisCoreTests/AppStoreProgressTests.swift` (new), `AppStoreTreeProjectionTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces:
  - `Session.controlProgress: SessionProgress?` and `Session.terminalProgress: TerminalProgressSlot?`, where
    `public struct TerminalProgressSlot: Sendable, Equatable { public let progress: SessionProgress; public let pane: StatusPane?; public let token: UUID }`.
  - `Session.shownProgress: (progress: SessionProgress, source: ProgressSource)?` — control first, then terminal.
  - `AppStore.setControlProgress(_ progress: SessionProgress?, forSession id: UUID)`
  - `AppStore.setTerminalProgress(_ update: TerminalProgressUpdate, forSession id: UUID, pane: StatusPane?)`
  - `AppStore.terminalProgressTimeout: Duration = .seconds(15)` (tests lower it).
  - Event `progress`; `ControlEventPayload` gains `progress: String?` (label, nil = cleared) and `source: String?`.
  - `ControlSessionNode.progress: ControlProgressNode?`, JSON `{"value":"3/7","fraction":0.4286,"source":"control"}`
    (`fraction` absent for indeterminate); the field is absent when nothing shows.

- [ ] **Step 1: Write the failing tests** (`AppStoreProgressTests`)

```swift
@Test func controlProgressShowsAndEmitsOneEvent()      // set .steps(3,7) → shownProgress source .control; one `progress` event "3/7"
@Test func controlWinsOverTerminal()                   // terminal .percent(40), control .steps(1,2) → control; clear control → terminal
@Test func completedEdgeClearsControlOnly()            // control + terminal set; active→completed → control nil, terminal kept
@Test func idleEdgeClearsControl()                     // active→idle clears; a later idle→idle write keeps a newly set control
@Test func activeRewriteOfStopKeepsControl()           // active→active (blink) keeps control
@Test func blockedKeepsControlForAfterTheBlock()       // active→blocked→active keeps control (only the row hides it)
@Test func terminalClearFromTheOtherPaneIsIgnored()    // set from .left, .clear from .right → kept; .clear from .left → gone
@Test func closingThePaneClearsItsTerminalProgress()   // clearPaneStatus(.right) clears a slot owned by .right
@Test func terminalProgressExpiresWithoutUpdates() async   // timeout .milliseconds(50); set; await 150 ms → nil, one cleared event
@Test func aTerminalUpdateRearmsTheExpiry() async      // set, 30 ms, set again, 30 ms → still shown
@Test func claudesOwnOSCClearKeepsPlanProgress()       // control .steps(3,7); terminal .set(.indeterminate) then .clear → control shown
```

In `AppStoreTreeProjectionTests`: `controlTreeReportsProgress` — node `progress == ControlProgressNode(value: "3/7",
fraction: 3.0 / 7, source: "control")`; absent when none.

- [ ] **Step 2:** `swift test --filter 'AppStoreProgressTests|controlTreeReportsProgress'` — FAIL.
- [ ] **Step 3:** Implement in `AppStore+Progress.swift`. Emit an event only when `shownProgress` changes.
  Expiry: each terminal set stores a fresh `token` and starts a `Task` that sleeps `terminalProgressTimeout`, then
  clears only if the slot still holds that token. In `setAgentIndicator`, after the assignment:
  `if previous.status != indicator.status, indicator.status == .completed || indicator.status == .idle` → clear control.
  `clearPaneStatus` clears a terminal slot whose `pane` equals the gone pane. `Session` fields are not persisted.
- [ ] **Step 4:** Same command — PASS. Also `--filter 'AppStoreStatusTests|AppStoreEventTests'` (status path touched).
- [ ] **Step 5:** `git commit -m "feat(core): session progress state, clear rules, event and tree read-back"`

### Task 3: `session.progress` command and CLI (ElisCore, elisctlKit)

**Files:**
- Modify: `ControlProtocol.swift:30` (`case sessionProgress = "session.progress"`), `ControlProtocol.swift:472-485`
  (`ControlArgs.progress: String?`), `ControlDispatcher.swift:28` (session group) and a handler next to `:239`,
  `ControlActions.swift:81` (new method), `ControlActionsDefaults.swift` (default refuses by name, like `:391`),
  `elisctlKit/SessionMetadataCommands.swift` (`Session.Progress`), `elisctlKit/SessionCommands.swift:21`,
  `elisctlKit/EventCommands.swift:91-98` (human line)
- Test: `ControlDispatcherSessionMetadataTests.swift`, `MockControlActions.swift`, `elisctlKitTests/CommandsTests.swift`,
  `elisctlKitTests/EventCommandsTests.swift`

**Interfaces:**
- Consumes: `SessionProgress.parse` (Task 1).
- Produces: `func setSessionProgress(_ target: String?, window: String?, progress: SessionProgress?) async -> ControlResponse`
  on `ControlActions`. CLI: `elisctl session progress <value> [--target <id>] [--window <id>]`.
  Human event line: `HH:mm:ss progress <name> 3/7 source=control`, or `… cleared source=control`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func sessionProgressRoutesParsedValueAndRejectsInvalid() // "3/7" → mock .sessionProgress(target, .steps(3,7)); "8/7" → "invalid progress"; "clear" → nil
@Test func sessionProgressRequest() throws {                   // CommandsTests
    let req = try request(["session", "progress", "3/7", "--target", "a"])
    #expect(req == ControlRequest(cmd: .sessionProgress, target: "a", args: ControlArgs(progress: "3/7")))
}
```
Extend `formattersCoverEveryKindAndNDJSONIsOneBareEvent` with a `progress` event and its human line.

- [ ] **Step 2:** `swift test --filter 'sessionProgress|formattersCoverEveryKind'` in `shared/ElisCore` — FAIL.
- [ ] **Step 3:** Implement. The CLI sends the raw string; only the dispatcher parses.
- [ ] **Step 4:** Same command — PASS.
- [ ] **Step 5:** `git commit -m "feat(control): session.progress command and elisctl session progress"`

### Task 4: Control progress on the presentation stream (ElisCore)

**Files:**
- Modify: `PresentationFrames.swift:676-677` (`PresentationSnapshot.progress: SessionProgress?`), `:780-840`
  (`case progress(SessionProgress?)`, kind `"progress"`), `PresentationFrame+Codable.swift:5,19,75`,
  `PresentationHub.swift:73` (`supportedKinds` gains `"progress"`), `AppStore+Presentation.swift:17` (snapshot),
  `AppStore+Progress.swift` (publish on a control change, mirroring `.ci` in `AppStore+SessionState.swift:47`),
  `RemotePresentationClient.swift:274,282`, `RemotePresentationEffects`, `AppStore+RemotePresentation.swift`
- Test: `PresentationFramesTests.swift`, `RemotePresentationStateTests.swift`

**Interfaces:**
- Consumes: `setControlProgress` (Task 2).
- Produces: `AppStore.applyRemoteProgress(_ progress: SessionProgress?, forSession id: UUID)` (calls
  `setControlProgress`); an effect `progress(SessionProgress?)` wired like `.status`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func progressFrameAndSnapshotRoundTrip()             // .progress(.steps(3,7)), .progress(nil), snapshot with progress
@Test func anOlderOriginsSnapshotLacksProgress()           // snapshot JSON without "progress" decodes, progress == nil
@Test func aPeerWithoutTheProgressKindGetsNoProgressFrame() // gated the way `ci` is gated by the peer's kinds
@Test func aMirroredProgressLandsOnTheViewerRow()          // RemotePresentationStateTests: frame → viewer session controlProgress
```

- [ ] **Step 2:** `swift test --filter 'progressFrame|OlderOrigins|ProgressKind|MirroredProgress'` — FAIL.
- [ ] **Step 3:** Implement. Only `control` progress publishes; `terminal` never travels.
- [ ] **Step 4:** Same command — PASS.
- [ ] **Step 5:** `git commit -m "feat(remote): control progress travels origin to viewer"`

### Task 5: elis-server

**Files:**
- Modify: `server/Sources/ElisServerKit/ServerActions+Effects.swift` (`setSessionProgress` via `withSession`),
  `server/Sources/ElisServerKit/ServerCommandPolicy.swift:15` (`served` gains `.sessionProgress`)
- Test: `server/Tests/ElisServerTests/ServerActionsEffectsTests.swift`, `ServerCommandPolicyTests.swift`,
  `ServerStreamsTests.swift`

- [ ] **Step 1:** Tests `aProgressIsSetOnTheSession`, `sessionProgressIsServed`, and
  `aProgressChangeReachesTheViewerStream` (pattern of `ServerStreamsTests.swift:317`).
- [ ] **Step 2:** `cd server && swift test --filter 'Progress'` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Same command — PASS.
- [ ] **Step 5:** `git commit -m "feat(server): serve session.progress"`

### Task 6: macOS app: action, OSC 9;4 and row fill

**Files:**
- Modify: `macos/Elis/Control/ControlServer+SessionActions.swift` (near `:518`, `setSessionProgress`),
  `macos/Elis/Control/ControlServer.swift:733` (allow-list), `macos/Elis/Ghostty/GhosttyCallbacks.swift:33-168`
  (`GHOSTTY_ACTION_PROGRESS_REPORT` case), `macos/Elis/Views/SidebarRowViews.swift:398-560` (`setProgressFill`),
  `macos/Elis/Views/WorkspaceSidebar+Bands.swift:74-111` (`decorate`), `macos/Elis/Views/WorkspaceSidebar.swift:102-106`
  (observation tuple gains `controlProgress` and `terminalProgress`; without it the row never redraws)
- Test: `macos/ElisTests/ControlServerProgressTests.swift` (new), `ControlServerRemotePresentationTests.swift`

**Interfaces:**
- Consumes: Tasks 1-4.
- Produces: `SidebarRowView.setProgressFill(_ fill: SidebarProgressFill?)`.

- [ ] **Step 1: Implement the callback.** Copy `action.action.progress_report.state` and `.progress` off-main
  (pattern of the `DESKTOP_NOTIFICATION` case `:71-78`); on main: `view.session`, pane via
  `NotificationManager.paneRole(of:in:)`, store via `library?.store(forSession:)`, then
  `store.setTerminalProgress(update, forSession:pane:)` when `SessionProgress.terminal(state:progress:)` is non-nil.
- [ ] **Step 2: Implement the layer.** One clip `CALayer` + `CAGradientLayer`, clipped and cornered like
  `layoutWave()`, always directly below the wave layer. Colors `[c@0.22, c@0.22, c@0]`, locations
  `[0, max(0, (w - 26) / w), 1]` for fill width `w = rowRect.width × fraction`. Width changes animate 0.2 s unless
  Reduce Motion is on.
- [ ] **Step 3: Wire `decorate`.** Compute `SidebarBand.progressFill` with the wave's tint and `activeHex` inputs. Pass
  `indeterminate: session.shownProgress?.progress == .indeterminate` to `wave`, and replace the
  `indicator.status == .active` early return so an indeterminate idle row can show the wave.
- [ ] **Step 4: Show the owner.** Build and launch an isolated Debug instance per `CLAUDE.md`. In one pane run
  `printf '\e]9;4;1;40\e\\'`; with the Debug `elisctl` and `--socket`, run `session progress 3/7` on a tinted
  session. Leave it running, tell the owner how to reach both rows, and wait for approval of the look.
- [ ] **Step 5: Hosted tests.** `testSessionProgressSetsAndClears` (command → tree read-back) and
  `testProgressTravelsFromAnOriginSessionToItsViewer` (pattern of `:1140`; hold the presentation stream for the
  whole test and give the session a zmx-backed surface).
  Run: `scripts/test-app.sh -only-testing:ElisTests/ControlServerProgressTests -only-testing:ElisTests/ControlServerRemotePresentationTests/testProgressTravelsFromAnOriginSessionToItsViewer` — PASS.
- [ ] **Step 6:** `git commit -m "feat(mac): progress fill on the session row, OSC 9;4 support"`

### Task 7: Claude Code plan hook

**Files:**
- Modify: `shared/ElisCore/Sources/ElisCore/AgentHooksInstall.swift:149-157`
  (`("PostToolUse", "TodoWrite|TaskCreate|TaskUpdate", "progress")`), `shared/agent-status/elis-claude-status.sh`,
  `shared/agent-status/elis-agent-status.sh`
- Test: `shared/ElisCore/Tests/ElisCoreTests/ClaudeStatusHookTests.swift`, the installer tests that pin `claudeHooks`

- [ ] **Step 1: Write the failing tests** (`ClaudeStatusHookTests`; its stub wrapper records argv)

```swift
@Test func todoWriteSendsDoneOverTotal()        // TodoWrite payload, 3 todos, 1 completed → wrapper argv ["progress", "1/3"]
@Test func taskUpdateCountsTheTaskDirectory()   // CLAUDE_CONFIG_DIR=<tmp>, tasks/sid/{1,2,3}.json, 2 completed → ["progress", "2/3"]
@Test func allDoneSendsClear()                  // 3/3 → ["progress", "clear"]; empty list → ["progress", "clear"]
@Test func aSubagentsTodoIsSilent()             // payload with agent_id → no call
@Test func anUnsafeSessionIDIsSilent()          // session_id "../x" → no call (reuse safe_id)
```
Plus an installer test: the Claude hooks include `PostToolUse` with matcher `TodoWrite|TaskCreate|TaskUpdate` and
state `progress`.

- [ ] **Step 2:** `swift test --filter 'ClaudeStatusHookTests|AgentHooks'` in `shared/ElisCore` — FAIL.
- [ ] **Step 3:** Implement. `elis-claude-status.sh` handles `progress` before the Stop logic and ends with
  `exec "$status_wrapper" progress <value>`; it counts `TodoWrite` items with the existing `plutil` → `jq` →
  `python3` chain. `elis-agent-status.sh` maps `progress` to
  `elisctl session progress "$2" --target "$ELIS_SESSION_ID"` plus `--socket` when set, with no `--pane`/`--cwd`,
  and always exits 0.
- [ ] **Step 4:** Same command — PASS.
- [ ] **Step 5:** `git commit -m "feat(hooks): Claude Code plan progress fills the session row"`

### Task 8: Linux bridge calls

**Files:**
- Modify: `linux/bridge/include/elis_bridge.h`; create `linux/bridge/Sources/ElisBridge/Progress.swift`
- Test: a new `ProgressBridgeTests.swift` in the bridge's test target (`linux/bridge/Tests/`)

**Interfaces:**
- Consumes: Task 1.
- Produces (UTF-8 JSON in and out, freed with `elis_free`):
  - `char *elis_progress_parse(const char *text)` → `{"ok":true,"progress":{…}|null}` or `{"ok":false,"error":"invalid progress"}`
  - `char *elis_progress_terminal(const char *body)` → `{"update":"clear"}` | `{"update":"set","progress":{…}}` | `null`
  - `char *elis_progress_row(const char *json)`, input `{"progress"?,"status","sessionTint"?,"workspaceTint"?,"active"}`
    → `{"fill":{"color","fraction","alpha":0.22,"feather":26}|null,"wave":bool}`

- [ ] **Step 1:** Tests for each call's shapes, with the values from Task 1's tests.
- [ ] **Step 2:** `cd linux/bridge && swift test --filter ProgressBridgeTests` — FAIL.
- [ ] **Step 3:** Implement with `@_cdecl`, the pattern of `Tint.swift`.
- [ ] **Step 4:** Same command — PASS.
- [ ] **Step 5:** `git commit -m "feat(linux-bridge): progress parse, OSC and row decision"`

### Task 9: Linux app

**Files:**
- Modify: `linux/src/core/store.h:35-74`, `linux/src/core/store.cpp:841-856` (edge clear in `Store::setStatus`),
  `linux/src/core/control.cpp:32-39,668` (`session.progress` via `elis_progress_parse`; `sessionNode` `progress`),
  `linux/src/core/hooks.cpp:68` (event), `linux/src/ctl/elisctl.cpp:82,489,725` (help, human line, args),
  `linux/src/app/config.cpp:436-442` (replace the `4;` drop with `elis_progress_terminal` → store),
  `linux/src/app/sidebar.cpp:372-409,778-800` (roles from `elis_progress_row`; fill paint between tint wash and
  hover; aurora when `wave`), `linux/src/core/installers.cpp:119-121` (Task 7's hook row)
- Test: `linux/tests/test_core.cpp`, `linux/tests/test_ui.cpp`

**Interfaces:**
- Consumes: Task 8.
- Produces: `Store::setControlProgress(QUuid, std::optional<QJsonObject>)`,
  `Store::setTerminalProgress(QUuid, QString pane, QJsonObject update)`, signal `progressChanged(QUuid)`;
  a single-shot `QTimer` per session for terminal expiry, 15000 ms, injectable for tests.

- [ ] **Step 1:** QtTest slots mirroring Task 2 (`controlWinsOverTerminal`, `completedEdgeClearsControlOnly`,
  `terminalClearFromTheOtherPaneIsIgnored`, `terminalProgressExpires`, `sessionProgressCommandReadsBack`) and in
  `test_ui.cpp` `aProgressRowCarriesTheFillRoles` (role values set; a blocked row has none).
- [ ] **Step 2:** `cmake --build linux/build -j && ctest --test-dir linux/build -R 'core|ui'` — FAIL.
- [ ] **Step 3:** Implement. Fill paint: `QLinearGradient` stops `0` and `(w-26)/w` at alpha 0.22, `1` at 0, clipped
  to the row's rounded rect.
- [ ] **Step 4:** Same command — PASS. Without a Linux host, push the branch and use the CI Linux job.
- [ ] **Step 5:** `git commit -m "feat(linux): session progress fill, command and OSC 9;4"`

### Task 10: Docs and final gates

**Files:**
- Modify: `site/docs.html` (new `<section id="status-progress">` after `status-ci` `:2492`, with a screenshot of a
  filled row from Task 6's instance, `cwebp -q 82` into `site/assets/`), `site/commands.html` (entry after
  `session status` `:1876`, with the tree field), `plugins/elis/skills/elis/SKILL.md` (`:503` command, `:258-261`
  tree field, a trigger in `description` such as "show progress on the session row"),
  `plugins/elis/skills/elis/reference.md` (`:38` event, `:252` tree field), `.claude/rules/control-api.md` (`:1680`
  catalog line; remote note at `:2193`), `.claude/rules/sidebar.md` (layer order),
  `.claude/rules/notifications.md` (OSC 9;4 is progress, not a notification)
- [ ] **Step 1:** Write the docs. One owner per fact; the others link to it.
- [ ] **Step 2:** Run each gate once: `scripts/test.sh`, `make test-app`, `make lint` (in `macos/`), and Task 9's
  Linux `ctest`. All green, zero lint findings.
- [ ] **Step 3:** `lsappinfo list | grep -A4 elis.debug`; stop leaked test processes.
- [ ] **Step 4:** `git commit -m "docs: session progress"`, then the cross-model review per `CLAUDE.md`.

## Not in this plan

- Codex/OpenCode/pi plan sources (their payloads were not probed); `elisctl session progress` serves them later.
- Workflow phase progress: no hook event carries it (Claude Code 2.1.332).
- A roll-up fill on a collapsed workspace row, and the phone app.
