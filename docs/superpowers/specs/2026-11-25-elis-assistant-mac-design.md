# Elis assistant on macOS

Status: draft for the owner's approval.
Product spec: `docs/superpowers/specs/2026-11-21-elis-assistant-design.md` (layout B, tags, provider picker, reply cards,
`assistant.*`). This doc does not restate it; it covers only the Mac host.
Reference host: Linux (`docs/superpowers/plans/2026-11-22-elis-assistant-linux.md`).
Paths are relative to the repository root.

## Intent

The shared core (`shared/ElisCore`: `AssistantChat`, `AssistantCommands`, `AssistantTargets`, `AssistantHandle`,
`AssistantProvider`, `AssistantStream`, `AssistantPrompt`, `ControlDispatcher+Assistant`, `elisctlKit`'s commands)
is done and tested.
The Mac has no host for it: `ControlServer` falls back to the `ControlActionsDefaults.swift` stubs, so every
`assistant.*` refuses as unsupported and the tree has no `assistant` key.
The phone connected to the Mac reads that key (`mobile/lib/model.dart:353`), so the phone shows no Elis row either.
This work gives the Mac the row, the chat, the provider process and the `ControlActions` adapter.

## Goals

- The pinned Elis row, chat view, composer and provider picker of the product spec, in every Mac window.
- Every `assistant.*` command works on the Mac socket, with tree read-back and both events.
- The phone connected to the Mac gets the Elis row and chat through the same tree stamp and commands.
- Behavior matches Linux where the spec leaves a choice open, unless this doc names a Mac difference.

## Non-goals

- No change to the shared contract, except four ElisCore changes: `AppStore.assistantShown`,
  `ControlTree.assistantShown`, `BuiltinAction.showAssistant`, and the snapshot selection fallback.
- No remote assistant (see Remote exception).
- No new settings in v1.

## Anti-goals

- No chat in the HTML overlay or any web view that owns focus or drag (see Approaches).
- No key typed in the chat reaches a terminal: not the selected session's, not one mounted underneath.
- No provider process that outlives the app.

## Remote exception (owner, 2026-11-25)

The owner approved, in a direct AskUserQuestion, that the assistant is local only.
Reason: the assistant only makes sense on the machine where the owner works.
- elis-server gets no `assistant.*` commands. `ServerCommandPolicy` is default-deny and lists none today: keep it so.
- Remote rows (a session attached from another Mac, a session served by elis-server) are not peers:
  `assistantPeers()` skips every session with `remoteHost != nil`.
  Such a row gets no `handle` in the tree, does not appear in `@` completion, and a drop of it on the composer is refused
  (the drag shows the not-allowed cursor; no chip appears).
- No remote reply route. `elisctl reply` in an attached Mac's session reaches that Mac's own socket and becomes a reply
  in that Mac's chat, from its own local session; the viewing Mac sees nothing.
- The phone connected to this Mac is local: it gets the row through the tree stamp.
- The implementation updates the product spec's "Remote and phone" section (lines ~171-178) and its delivery item 3
  to this rule, and deletes `macos/docs/backlog/assistant-remote-reply-route.md`.

## Constraints

- `ElisCore` imports no AppKit; the adapter, views and process live in the app target.
- `.claude/rules/control-api.md`: protocol, dispatcher, CLI, read-back, `EventFormatter.human`, tests and the bundled skill
  in the same change. The core already covers protocol, dispatcher, CLI and human lines.
- `.claude/rules/sidebar.md`: the sidebar is an `NSOutlineView` with cached `SidebarNode`s; the row joins it,
  not a SwiftUI overlay above it.
- `.claude/rules/menu-actions.md` and `keymap.md`: menu item, palette row and keymap name share one `BuiltinAction` seam;
  enablement goes through `PaletteCommand.isEnabled(in:)`.
- A control already in the app looks and behaves the same in the new place: reuse it.
- Run app commands in `macos/`; gates per `CLAUDE.md`.

## Approaches

1. **Native SwiftUI/AppKit (chosen).** Row in the outline, chat as a SwiftUI view in the detail area, composer as an
   AppKit text view that accepts the sidebar's own pasteboard types, provider through Foundation `Process`.
   It keeps layout B, native drag from the outline and native focus rules.
2. **Chat as an HTML page in the HTML overlay (rejected).** The overlay is a page over a session, so the chat would
   belong to one session, which breaks layout B. Drag from the outline into a `WKWebView` and composer focus would need
   a bridge, and the overlay's input rules would apply to a view that is not a session's.

## Design

### Mapping

| Linux | Mac | Notes |
|---|---|---|
| `ElisBridge/Chat.swift` (`elis_assistant_open`, `chat` global) | `ControlServer` owns `AssistantChat(file: <stateDir>/assistant/chat.jsonl)`; `ControlServer.swift:720` passes it as `ControlDispatcher(actions: self, chat:)` | Today the Mac uses `AssistantChat.shared`, which has no file, so nothing would persist. |
| `core/assistant.cpp` `Assistant::peers` | new `macos/Elis/Control/ControlServer+Assistant.swift`: `assistantPeers()` over `library.openIDs()` stores in library order, sidebar order inside, local sessions only | `sessionID` is byte-identical to the tree node `id`. Companions: builder's call, matching Linux's session set. |
| `Assistant::dispatch` | nothing: `ControlDispatcher+Assistant` already runs commands, types through `typeSession`, and performs effects | The `preconditionFailure` arm at `ControlServer.swift:763` stays: the dispatcher always answers these. |
| `elis_assistant_stamp` | nothing: the dispatcher's `.tree` arm calls `stampAssistant` once `assistantPeers()` is non-nil | The phone's tree goes through the same dispatcher. |
| `AssistantSink` (`enqueue`, `providerChanged`, `cleared`) | `assistantInput`, `assistantSent`, `assistantProviderChanged`, `assistantCleared`, `assistantSeen`, `showAssistant` in `ControlServer+Assistant.swift` | Each forwards to the runner or the model below. |
| `DetectedLaunchers` | `SessionLaunchers` (`macos/Elis/SessionLaunchers.swift`) keeps the login-shell PATH it detected with, beside `detected` | `assistantProviders()` = cached `available` minus `.terminal`; it runs on every tree request, so no detection on that path. |
| `app/assistantrunner.cpp` | new `macos/Elis/AssistantRunner.swift`, `@MainActor` | Same state machine; see Provider process. |
| `Assistant::emitMessage` | `AppStore.emitControlEvent` on the sender's window store, else the first open store | Payload `kind`, `from`, `handle`, `text`; `assistant.cleared` has an empty payload. |
| `AssistantView::refreshAll` | new `@Observable` `AssistantModel` (app target): entries, unread, running, provider, providers | `AssistantChat` is not observable; the adapter and runner bump the model after each effect and turn. |
| `app/sidebar.cpp` Elis row | `WorkspaceSidebar` Coordinator: a pinned `SidebarNode` kind at row 0, drawn by `WorkspaceSidebar+RowRendering.swift` | See Sidebar row. |
| `app/assistantview.cpp` | new `macos/Elis/Views/AssistantView.swift` (+ `AssistantComposer.swift`), shown by `WindowContentView+Detail.swift` | See Chat view. |
| `mainwindow.cpp` `m_assistantShown`, window `assistantShown` | `AppStore.assistantShown` (ElisCore, transient); `ControlTree.assistantShown: Bool?` (ElisCore, top-level, as Linux `chromeState`), set only when true | ElisCore additions; Linux writes its own JSON and is unaffected. |
| keymap `show_assistant`, Navigate ▸ Show Elis | `BuiltinAction.showAssistant = "show_assistant"` (no default chord), Navigate ▸ Show Elis, palette row "Show Elis" | Bump `BuiltinActionTests`' count and the count in `keymap.md`. |
| `ELIS_ASSISTANT_PROVIDER_CMD` | same variable, read by `AssistantRunner` | Test seam for hosted and UI tests. |

### Provider process

`AssistantRunner` mirrors `assistantrunner.cpp` line for line in behavior; the Linux file is the reference for each case.
- State dir: `<stateDir>/assistant/`, created on first spawn; the working directory of the process.
- Start: lazily, on the first queued input, after the first launcher detection.
  It reads the saved provider; an unavailable one falls back to the first available, saved through `assistant.provider`.
  `AssistantProvider.launch` gives argv, mode, environment and preamble; the system prompt comes from
  `AssistantPrompt.system` over the current peers.
- Queue: one input per turn, the rest held host-side, as the core requires (`inputQueued`/`turnEnded` pairs).
  The first input of a fresh process carries the preamble, plus `AssistantPrompt.inline(settledEntries(last: 50))` after a
  provider change or a lost conversation.
- Stream mode: one long-lived `Process`; inputs are `AssistantStream.encode` lines on stdin; stdout lines go through
  `AssistantStream.decode`. Per-input mode: one `Process` per turn from `AssistantProvider.turn`, stdin `/dev/null`.
- Turn end: text collected in the turn becomes one assistant entry; then `turnEnded()` or `turnFailed`.
  A 10-minute watchdog, re-armed by output, fails the turn ("the assistant stopped responding").
- Death: a stream process that exits is started again by the next input, resuming its conversation.
  One that dies before naming its conversation after a resume forgets that resume id and retries once fresh,
  with the chat inlined. Otherwise `providerFailed` with the exit reason and the last stderr line.
- Provider change: stop the old process (SIGTERM, SIGKILL after 3 s), hand the cut turn to the new provider.
- Clear: stop the process, drop the queue.
- Quit: `applicationWillTerminate` stops it and waits up to 2 s, then SIGKILL.
- Environment: the app's environment minus every `ELIS_*` and Claude Code's parent-session markers (the Linux list),
  plus `ELIS_STATE_DIR` = this app's state dir, plus the launch's own environment.
  PATH = the bundle's `Contents/MacOS` first, then the detected login-shell PATH; argv[0] resolves on that PATH.
- Stop after a hard kill: macOS has no `PR_SET_PDEATHSIG`.
  A stream provider gets stdin EOF when the app dies; the builder verifies that each stream provider exits on it.
  For any that does not, the runner writes `<stateDir>/assistant/provider.pid` with the pid and its start time,
  and the next launch terminates that pid when both still match.
  Builder's call: a pidfile for every provider instead, if that is simpler than per-provider proof.

### TCC

The provider is a direct child of Elis.app, not of `elis-session-host`, so its attribution can differ from a pane's.
Agents run tools that read files (Documents, Desktop, Downloads, removable volumes) and may use the network.
The builder checks each service the provider can touch, as the #574 microphone test did: run a provider tool that reads
a protected folder and record the responsible process and the subject in the tccd log.
Expected (author's call, unverified): prompts name Elis, and a grant Elis already has for panes applies.
If the check shows a worse result (a prompt per launch, or a denial without a prompt), the runner spawns the provider
through the same `elis-session-host` path panes use instead of as a direct child (lead's call; no owner round-trip).

### Sidebar row

- A pinned node above the first workspace, in every sidebar mode (tree, flat, flagged), never movable, closable,
  renamable or a drop target for reordering; nothing drops above it.
- Content: the app's dog icon, "Elis", and the unread count drawn with the existing unseen badge.
- A click calls `showAssistant(window:)` for that window. The row is not a `Session`: no context menu, no multi-select,
  absent from `navigableSessions`, MRU, recent and session search.
- Selected look: the row's pill shows while `store.assistantShown` is true; no session row is selected then.
- Workspace tints and bands skip it.

### Chat view and composer

- `WindowContentView+Detail.swift` shows `AssistantView` while `store.assistantShown` is true, the way it handles the
  dashboard: the terminal deck stays mounted underneath and non-interactive (no focus, no hit testing, no drag targets).
- No cards, as on Linux: user and sent entries on the right, assistant and reply entries on the left; a reply entry names
  its session with a "go to session" control that runs `session.go`; an error entry renders plain, with no error card.
- Markdown in cards: native `Text` over `AttributedString(markdown:)` with block structure, matching Linux's
  `Qt::MarkdownText`.
  `MarkdownPage.html` builds a whole web page and `HudMarkdown` paints terminal rows; neither fits a card.
  Author's call: if native rendering of lists and code blocks proves poor, the builder may adapt `HudMarkdown.lines`
  (made `public`) to SwiftUI runs, and says so in the PR.
- Composer: a multi-line AppKit text view in the chrome of the GUI ask field (`AskFormViews.swift`), with tag chips,
  `@` completion (handles, `@ws:`, `@all`), the provider picker and send button.
  It registers `sessionPasteboardType` and `workspacePasteboardType` (`WorkspaceSidebar.swift:6-9`); a dropped local row
  becomes its tag chip.
- Clear chat button, as on Linux, runs `assistant.clear`.
- Return sends, Shift-Return inserts a newline (folded later by the core).

### Selection, focus and keys

One rule (owner's decision, 2026-11-25, exactly as Linux): while the chat shows, the window has no selected session,
and keys go to the chat. No new "default target" concept joins `AppStore`.
- `showAssistant` closes an open dashboard (as Linux `MainWindow::showAssistant`, lead's call) and leaves terminal zoom, sets
  `assistantShown = true`, clears `selectedSessionID`, and focuses the composer.
- `session.selected` fires with no session, as for any cleared selection.
- Any session selection (click, `session.go`, MRU, Ctrl-Tab, palette, notification reveal) sets `assistantShown = false`.
  Put this in `AppStore`'s `selectedSessionID` setter, so no caller can miss it.
- Ctrl-Tab returns to the most recent session.
- Session-scoped menu items and shortcuts are disabled while no session is selected, through their existing
  presence term in `PaletteCommand.isEnabled(in:)`.
- New Session (Cmd-T) opens in `currentWorkspaceID`, unchanged: with no selection that is a freshly created workspace
  if one is held, else the last workspace in sidebar order. Linux's `Store::resolveWorkspace` does the same.
- An `elisctl` command that needs a session and gets no `--session` refuses, as it does with no selection today.
- Escape closes an open completion list or provider picker; otherwise it does nothing.
- The terminal underneath receives nothing: no keys, no paste, no focus.
- `show_assistant` in another window shows that window's chat; the chat is app-wide, so every window shows the same thread.
- A dashboard opened over the chat covers it; closing it shows the chat again.

### Relaunch

`assistantShown` is transient (lead's call): a relaunch after a quit or crash while the chat showed opens on a session.
`AppStore+Snapshot.swift:41-42` (`persistedSelection`) today writes nil for a nil selection; it falls back to the
MRU session, then the first, as it already does for an unpersistable one.

### Tree, events, phone

- Tree: the dispatcher stamps top-level `assistant {provider, providers, running, unread}` and node `handle`/`assistantMark`.
  The Mac adds top-level `assistantShown: true` while the projected window shows the chat.
- `assistant.message` for every new entry (user, assistant, sent, reply, error), `assistant.cleared` after a clear.
- `.seen` (from the phone's `assistant.seen` or the Mac's own show): bump `AssistantModel`, so the row's badge repaints.
- The phone needs nothing more: it polls the tree and calls `assistant.*` through the Mac's dispatcher.

### Menus and settings

- Navigate ▸ Show Elis (`show_assistant`), and the palette row. No other menu items.
- No settings in v1.
- The row does not join `InterfaceElement` or Settings > Interface (owner's decision, 2026-11-25).

### Docs and skill

- `site/docs.html:582`: drop "the macOS app gets it later"; state Mac and Linux; document the drop and the shortcut name.
- `site/docs.html` and `site/commands.html`: top-level `assistantShown`, and that remote rows have no handle.
- `plugins/elis/skills/elis/SKILL.md:181`: drop "(Linux now, macOS later)"; add "local sessions only".
- `.claude/rules/control-api.md`: the Mac host's actions and the remote exception, once.
- `macos/ARCHITECTURE.md`: `AssistantRunner` and the model, one line each.
- The product spec and backlog changes listed under Remote exception.

## Tests

ElisCore logic is tested. Add only what this work adds.
- ElisCore: `ControlTree.assistantShown` encoding; `AppStore` selection clears `assistantShown`;
  a nil selection persists the MRU session;
  `BuiltinActionTests` count.
- Hosted (`macos/ElisTests/ControlServerAssistantTests.swift`, with `ELIS_ASSISTANT_PROVIDER_CMD` pointing at a fake
  stream provider script in the test bundle):
  - `assistant.show` reads back `assistantShown`, clears the selection, and a `session.go` clears it again;
  - `assistantPeers` excludes a remote row, and the tree has no `handle` for it;
  - `assistant.ask` runs a turn through the fake provider and appends an assistant entry; `running` returns to false;
  - provider death mid-turn yields one error entry; a provider change restarts with the recap;
  - `assistant.clear` stops the process and emits `assistant.cleared`;
  - the chat persists to `<stateDir>/assistant/chat.jsonl` and reloads.
- `AssistantRunner` unit tests in the hosted target for queue, watchdog (injected clock) and environment scrubbing.
- One UI test (`macos/ElisUITests/AssistantUITests.swift`): click the row, type in the composer, check the fake
  provider's answer card and that the terminal received no text; drag a session row onto the composer and check its chip.
- Run each new test with `-only-testing:`; the full gates once at the end.

## Left to the builder

- Widget structure, card layout and spacing, within the reuse rule; show the owner the rendered view before tests.
- Exact pinned-node plumbing in the Coordinator.
- Whether companions are peers (match Linux).
- Pidfile versus per-provider EOF proof.
- Markdown fallback described above.
