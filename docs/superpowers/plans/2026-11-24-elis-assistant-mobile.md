# Elis assistant: phone app — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Elis phone app gets the Elis assistant chat. On the Sessions screen an "Ask Elis…" composer button and New session share one bottom row. A tap on the composer expands it into a chat bottom sheet with reply cards, `@` tag completion and a provider menu.

**Architecture:**
- The phone speaks the existing `assistant.*` control API through the phone link, which already forwards it.
- The host gains one command, `assistant.seen`, so the phone can clear unread without selecting the desktop's Elis row.
- The Flutter side adds one model class and three widgets under `mobile/lib/assistant/`. It reads `tree.assistant`, session and workspace `handle`, and re-reads `assistant.read` on each `assistant.message` event.

**Tech Stack:** Swift 6 (`shared/ElisCore`, `linux/bridge`), C++ Qt6 (`linux/`), Flutter/Dart (`mobile/`), swift-testing, QTest, flutter_test.

**Spec:** `docs/superpowers/specs/2026-11-21-elis-assistant-design.md` (read "Design", "Control API", "Remote and phone").
**Approved design:** variant B on https://claude.ai/artifact/HVYXv51XrdYFDB74Q93WGE. The `B-Sessions` frame is interactive: Play it to see the transition. **Tracking:** Linear NAI-26.

## Global Constraints

- **Design source.** The mockup decides only the points the owner approved:
  - one bottom row with the composer button and New session;
  - the composer expands into the sheet, and New session slides out;
  - variant B's sheet, cards, completion and provider menu.
  Port nothing else from it. Tokens come from `mobile/lib/theme.dart`.
- **Bottom row.** Inset 12 from the screen edges, height 52, gap 8.
  - New session: fixed width 164, fill `C.text`, text `C.bg` 15/w600, `Icons.add`, radius 16.
  - Composer button: takes the rest of the row; fill `C.surface`, 1 px `C.line`, radius 16. It holds the `AppMark` icon (32), the hint "Ask Elis…" (15, `C.muted`) and the unread badge.
  - The badge is the app's existing unread badge, `C.unseen`.
- **Transition.**
  - Duration 380 ms, curve `Cubic(0.2, 0, 0, 1)`.
  - The composer surface animates from its row rect to the sheet rect (top 72, full width, bottom 0, top radius 24). New session translates right by its width + 8 and fades out on the same curve.
  - The black 54% scrim fades in. Sheet content fades in after 260 ms, laid out at the sheet's full size, never re-wrapping.
  - Closing (drag down, tap the handle or the scrim, system back) runs the same animation in reverse.
  - `MediaQuery.disableAnimations` jumps straight to the end state.
- **No assistant on the host.** When the tree has no `assistant` key (Mac and elis-server today), the composer button is absent and New session fills the row. There is no long-press tagging (owner, 2026-11-24): tags come from `@` completion only.
- **Phone-link boundary.** The phone sends exactly the desktop's requests:
  - `assistant.ask {text}`, where the text holds plain `@handle` tokens;
  - `assistant.read {last}`;
  - `assistant.provider {provider}`;
  - `assistant.seen`.
  It never calls `assistant.show`, which selects the desktop's row.
- **Control API contract** (`.claude/rules/control-api.md`): a new command ships with its protocol case, dispatcher, `elisctl`, read-back, tests, `site/commands.html`, `site/docs.html` and the bundled skill, all in the same change.
- **Gates.**
  - ElisCore `swift test`: only the known zsh/tcsh/csh failures.
  - Linux: CMake build plus `ctest --test-dir build`.
  - Mobile: `flutter analyze --no-pub` and `flutter test --no-pub`. Follow the SDK-constraint note in `CLAUDE.md`, and restore `pubspec.yaml` and `pubspec.lock` before committing.
  - SwiftLint strict: zero findings.
  - The macOS GitHub CI is not waited for.
- **Live terminal.** Never execute `elis`/`elisctl` against the default socket. Manual runs use a short `/tmp` `ELIS_STATE_DIR`, and emulator runs follow the `mobile-emulator-testing` memory.

## Review Focus

- **Composer tapped while the tree is still loading or the link drops.** The sheet opens on the cached transcript and shows the link state. It must not hang on `assistant.read`.
- **A reply arrives while the sheet is open.** The new card appears at the bottom and the transcript keeps its scroll position unless it was at the bottom. Unread stays 0, because the phone sends `assistant.seen` again.
- **A turn ends with no text.** `running` must clear on the phone within one poll (Task 3 polls `tree` every 2 s while `running`).
- **A reply card names a session that has since closed.** The card still shows the handle, and its go link does nothing rather than throwing.
- **The keyboard opens in the sheet.** The composer rises above the keyboard, and the `@` popup stays inside the sheet, above the field.

---

### Task 1: `assistant.seen` on the host

**Files:**
- Modify: `shared/ElisCore/Sources/ElisCore/ControlProtocol.swift` (`case assistantSeen = "assistant.seen"` beside `assistantShow`), `ControlDispatcher.swift:102` (route it), `AssistantCommands.swift` (`run`).
- Modify: `linux/bridge/Sources/ElisBridge/Chat.swift` (the `commands` set), `shared/ElisCore/Sources/elisctlKit/AssistantCommands.swift` (`Seen` subcommand), and `linux/src/ctl/elisctl.cpp` (next to `assistant.read`, if the C++ front lists assistant commands).
- Docs: `site/commands.html`, `site/docs.html`, `plugins/elis/skills/elis/` reference, `.claude/rules/control-api.md` catalog.
- Test: `shared/ElisCore/Tests/ElisCoreTests/AssistantCommandsCoreTests.swift`, `ControlDispatcherAssistantTests.swift`, the elisctlKit parse tests, and `linux/tests/test_ui.cpp`.

**Interfaces:**
- **Produces:** `assistant.seen` (no args, no target) → `{ok: true}`. It calls `chat.markSeen()` and returns the effect `.seen`.
- **New effect:** `AssistantEffect.seen`. Each host responds by refreshing its Elis row's unread badge: the Linux sidebar through the existing assistant sink refresh, and the Mac by repainting the row once one exists.
- **Read-back:** the tree's top-level `assistant.unread`.
- **CLI:** `elisctl assistant seen`.

- [ ] **Write failing tests:**
  - `assistantSeenClearsUnread`: append a `.reply` entry, assert `unread == 1`; run `assistant.seen`; assert `.reply(ok)` with effects `[.seen]` and `chat.unread == 0`.
  - `assistantSeenWithoutPeersIsUnsupported`: a host with nil peers refuses it, with the message from `ControlActionsUnsupported.message("assistant.seen")`.
  - CLI parse: `assistant seen` builds `ControlRequest(cmd: .assistantSeen)`.
  - `test_ui`: after `assistant.seen`, the sidebar Elis row's `Unseen` data is 0.
- [ ] Run `swift test --filter Assistant` in `shared/ElisCore`. Expected: the new tests fail.
- [ ] Implement it. `.assistantSeen` joins the peers-required branch.
- [ ] Run the tests above, plus `ctest --test-dir build -R test_ui`. Expected: PASS.
- [ ] Update the docs listed above. Add the human line for the effect only if an event is emitted (none is).
- [ ] Commit: `feat(assistant): assistant.seen clears unread without showing the row`.

### Task 2: Mobile model reads the assistant

**Files:**
- Create: `mobile/lib/assistant/assistant_model.dart`.
- Modify: `mobile/lib/model.dart` (`Session`, `Workspace`, `ElisModel.refresh`, `_onEvent`).
- Test: `mobile/test/assistant_model_test.dart`.

**Interfaces:**
- **Produces:**
  - `class AssistantEntry { String id, kind, text; String? from; List<String> to; double ts; AssistantEntry.fromJson(Map m) }`. `kind` is one of `user | assistant | sent | reply | error`.
  - `class AssistantState { String? provider; List<String> providers; bool running; int unread; AssistantState.fromJson(Map m) }`.
  - `ElisModel` gains:
    - `AssistantState? assistant`: null when the tree has no `assistant` key;
    - `List<AssistantEntry> assistantEntries`;
    - `Future<void> readAssistant({int last = 100})`;
    - `Future<String?> askAssistant(String text)`: returns the error text or null;
    - `Future<String?> setProvider(String name)`;
    - `Future<void> markAssistantSeen()`;
    - `bool assistantOpen`: set by the sheet.
  - `Session.handle` and `Workspace.handle` are `String`, defaulting to `''`.

- [ ] **Write failing tests:**
  - `parses assistant state and handles`: tree fixture with `assistant: {provider: 'codex', providers: ['claude','codex'], running: false, unread: 2}`, session `handle: 'side-filter'`, workspace `handle: 'elis'`. Expect `m.assistant!.unread == 2`, `session.handle == 'side-filter'` and `workspace.handle == 'elis'`.
  - `no assistant key leaves it null`: expect `m.assistant` to be null.
  - `assistant.message event re-reads the transcript`: use a fake `Connection` recording calls. Feeding `{'kind': 'assistant.message'}` to `_onEvent` leads to one `assistant.read` with `{'last': 100}`. If `assistantOpen` is true, it is followed by `assistant.seen`.
  - `askAssistant sends text verbatim`: `askAssistant('@side-filter push')` sends `assistant.ask` with `{'text': '@side-filter push'}`.
- [ ] Run `flutter test --no-pub test/assistant_model_test.dart`. Expected: FAIL.
- [ ] Implement it. The event loop already schedules a tree refresh after events, so only `assistant.message` adds the read.
- [ ] Run the tests again. Expected: PASS.
- [ ] Commit: `feat(mobile): read the Elis assistant state and transcript`.

### Task 3: Running poll

**Files:** Modify `mobile/lib/model.dart`. Test: `mobile/test/assistant_model_test.dart`.

**Interfaces:**
- **Consumes:** Task 2's `AssistantState.running`.
- **Produces:** while `assistant?.running == true`, `refresh()` re-arms `scheduleRefresh(const Duration(seconds: 2))`.

- [ ] Write a failing test, `polls tree while running`, with `fakeAsync`. A tree with `running: true` leads to a second `tree` call after 2 s. With `running: false` there is no extra call.
- [ ] Implement it, run the test (PASS), and commit `fix(mobile): a silent assistant turn still clears running`.

### Task 4: Tag completion

**Files:** Create `mobile/lib/assistant/tags.dart`. Test: `mobile/test/assistant_tags_test.dart`.

**Interfaces:**
- **Produces:**
  - `class TagCandidate { String tag; String label; String icon; String? status; String tint; }`. `tag` is like `@all`, `@ws:elis` or `@side-filter`. `icon` is `all | workspace | <agent id> | terminal`.
  - `List<TagCandidate> tagCandidates(String query, List<Workspace> workspaces)`.
  - `String? tagQuery(String text, int caret)`: the word after an `@` that ends at the caret, or null.
- **Order:** `@all`, then `@ws:<handle>` for each workspace, then sessions with a non-empty `handle` in sidebar order. Each list is filtered by a case-insensitive prefix match of `query` against the tag without its `@`. Blocked sessions stay listed with their status.

- [ ] **Write failing tests:**
  - `empty query lists all, then workspaces, then sessions`.
  - `prefix filters case-insensitively`: `'SIDE'` returns only `@side-filter`.
  - `sessions without handle are skipped`.
  - `tagQuery finds the word at the caret`: `'ask @si'` with caret 7 gives `'si'`; `'mail a@b'` gives null.
- [ ] Run the tests (FAIL), implement, run them again (PASS), and commit `feat(mobile): @ tag completion for the Elis composer`.

### Task 5: Bottom row and the composer-to-sheet transition

**Files:**
- Create: `mobile/lib/assistant/elis_bar.dart`.
- Modify: `mobile/lib/screens/home.dart` (replace the `FloatingActionButton.extended` at about `:277` and keep its `Key('newSession')`).
- Test: `mobile/test/elis_bar_test.dart`, `mobile/test/home_test.dart`.

**Interfaces:**
- **Consumes:** Task 2's `ElisModel.assistant`, `markAssistantSeen`, `readAssistant` and `assistantOpen`; Task 6's `ElisSheet`.
- **Produces:** `class ElisBar extends StatefulWidget { const ElisBar({required ElisModel model, required VoidCallback onNewSession}); }`. It is laid out in a `Stack` over the Sessions body, which gets 76 px of bottom padding (52 + 12 + 12).
- **Behavior:**
  - One `AnimationController` (380 ms) drives the surface rect, the New session offset and opacity, the scrim, and the content fade (`Interval(0.68, 1)`).
  - Opening sets `assistantOpen`, then calls `readAssistant` and then `markAssistantSeen`. Closing clears `assistantOpen`.
  - System back closes the sheet first (`PopScope`).

- [ ] **Write failing tests:**
  - `bar hidden without assistant`: with `m.assistant` null, there is no `Key('askElis')`, and `Key('newSession')` spans the row (its width is the screen width minus 24).
  - `bar shows unread`: with `unread: 2`, the badge text is `2`.
  - `tap opens the sheet and marks seen`: tap `Key('askElis')`, then `pumpAndSettle`. `ElisSheet` is visible, `Key('newSession')` is offstage or has opacity 0, and the fake connection saw `assistant.read`, then `assistant.seen`.
  - `back closes the sheet`: `tester.binding.handlePopRoute()`, then settle. The bar is back and the route did not pop.
- [ ] Run `flutter test --no-pub test/elis_bar_test.dart test/home_test.dart`. Expected: FAIL.
- [ ] Implement it.
- [ ] Run the tests again. Expected: PASS, with the existing `home_test` cases still green.
- [ ] Commit: `feat(mobile): Ask Elis and New session share the bottom row`.

### Task 6: Chat sheet, composer and provider menu

**Files:**
- Create: `mobile/lib/assistant/elis_sheet.dart` (header and transcript) and `mobile/lib/assistant/elis_composer.dart` (field, tag chips, popup, provider chip).
- Test: `mobile/test/elis_sheet_test.dart`.

**Interfaces:**
- **Consumes:** Task 2's entries and `askAssistant`/`setProvider`, Task 4's `tagCandidates`/`tagQuery`, and the existing `AgentIcon`, `StatusShape`, `AppMark` and `tintColor` from `theme.dart`.
- **Produces:**
  - `class ElisSheet extends StatelessWidget { const ElisSheet({required ElisModel model, required void Function(Session) openSession}); }`
  - `class ElisComposer extends StatefulWidget { const ElisComposer({required ElisModel model}); }`
- **Entry rendering**, matching variant B:
  - `user`: the existing chat bubble (`C.surface2`, radius 16, right-aligned).
  - `assistant`: plain 14 px text.
  - `reply`: a left card, 80% width, fill `C.hover`, radius 12/12/12/4. Its header is the `FROM` caption (11.5/w600), a handle chip, the session name (13, `C.muted`) and an accent arrow. The whole card opens the session.
  - `sent`: a right card with no fill, radius 12/12/4/12. It has one 44 px row per recipient, with `TO` on the first row only, and the body text muted.
  - `error`: 14 px text in `C.danger`.
- **Chips:** handle chips are mono 12, filled with the session's workspace tint at 22% with a 45% border. `@all` uses the accent.
- **Composer:**
  - Field hint "Message Elis… @ to tag". Send is disabled while the text is empty.
  - Typed `@handle` tokens show as chips through a `TextEditingController.buildTextSpan` override. The text sent stays plain.
  - The `@` popup has the field's width and is anchored 4 px above it. Fill `#38383F`, 1 px border `C.text` at 20%, radius 12, rows 44 high: icon 18, tag mono 14, name 13 muted, and a status glyph for blocked or active sessions.
- **Provider chip:** an agent icon, the name and a chevron, above the field. It opens a menu headed "FOUND ON THIS SYSTEM" with 48 px rows (agent icon 20, name 15) and an accent check on the current provider. Names only.

- [ ] **Write failing tests:**
  - `renders each entry kind`: with five fixture entries, find the texts `FROM`, `TO` and the error text, and check that the error text color is `C.danger`.
  - `reply card opens its session`: tapping the card calls `openSession` with the session whose id equals `from`.
  - `reply from a closed session does nothing`: with an unknown `from`, a tap does not throw and `openSession` is not called.
  - `@ popup inserts the tag`: type `'ask @si'`, tap `@side-filter`, and the field text becomes `'ask @side-filter '`.
  - `send calls ask and clears`: type and send; `askAssistant` received the text and the field is empty.
  - `provider menu sets provider`: open the chip, tap `Claude Code`, and `assistant.provider` is sent with `{'provider': 'claude'}`.
- [ ] Run `flutter test --no-pub test/elis_sheet_test.dart`. Expected: FAIL.
- [ ] Implement it.
- [ ] Run the tests again. Expected: PASS.
- [ ] Commit: `feat(mobile): Elis chat sheet with tags and provider menu`.

### Task 7: Docs, full gates, device check

**Files:** `site/docs.html` (the phone section: the Ask Elis bar and what it needs on the host), `mobile/README.md` if it lists screens, and `docs/screenshots/` with a new `phone-elis.png` (staged on the emulator against an isolated Linux Elis, showing two agent statuses at most).

- [ ] Run every gate from Global Constraints once. Expected: green, apart from the known zsh/tcsh/csh failures.
- [ ] Emulator check: pair the emulator with an isolated Linux Elis whose `ELIS_STATE_DIR` is under `/tmp`. Open the bar, ask with a tag, receive a reply card, and confirm that unread on the desktop row drops to 0. Publish the screenshots on an Artifact page after a visual-critic pass.
- [ ] Update NAI-26 and move it to In Review with the PR link. Commit: `docs(mobile): the Elis assistant on the phone`.
