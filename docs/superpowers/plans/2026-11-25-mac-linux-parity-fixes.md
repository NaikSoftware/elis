# Mac and Linux Parity Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring three Linux fixes to the Mac app: keep-awake also keeps the display awake, CI line colors keep 4.5:1 contrast, and a click on a CI line opens the panel only for the shown session.

**Architecture:** Fix 1 is one `ProcessInfo` option. Fix 2 is a pure `legibleOn` in `ElisCore` (Double RGBA, no AppKit) called from `SidebarInfoCellView` with the fills the row view draws. Fix 3 makes the CI line decline a click at click time, so the row's own select and drag path runs.

**Tech Stack:** Swift 6, `ElisCore` (Swift Testing), AppKit hosted tests (XCTest), static HTML docs.

**Spec:** `docs/superpowers/specs/2026-11-25-mac-linux-parity-fixes-design.md`

Paths: repo-root relative. Run `macos/` commands from `macos/`. `ElisCore` sources and tests live in `shared/ElisCore/` (`macos/ElisCore` holds only build dirs).

## Global Constraints

- Never run `elis`/`elisctl` against the default socket, never launch or quit `~/Applications/Elis.app`. Manual checks use a separate `open -n` Debug instance with a short `/tmp` `ELIS_STATE_DIR` (see CLAUDE.md "Working norms").
- Show the owner the rendered rows in that Debug instance before writing the Fix 2 hosted-test changes.
- No new control API (spec "Intent"). No new settings.
- `ElisCore` imports no AppKit or CoreGraphics: Double-backed geometry and color. `ElisCore` is consumed by `agterm-linux`, so a new `public` symbol is fine, but do not narrow existing ones.
- Contrast threshold is exactly 4.5; mix steps are `t = 0, 0.05 … 1.0` (21 steps); the fallback is the text color.
- Docs: `site/docs.html` is the user guide, `site/commands.html` the command reference. State each rule once. Comments short: only non-obvious constraints.
- Gates run once, in Task 5. Earlier tasks run only targeted tests.
- Commit messages end with `Claude-Session: https://claude.ai/code/session_018MUCCRrKVLC4vh25eZbATw`.

## Review Focus

- A span color already legible on every backdrop stays byte-identical (no drift on plain rows). Test in Task 2.
- A `dim` colored span (alpha 0.55) is judged and mixed with its alpha kept; contrast uses the composited color. Test in Task 2.
- An active-status row has two backdrops (the wave's strongest stops); both must pass, not just one. Test in Task 2 (`under` with two entries) and the Task 3 backdrop list.
- A reused cell must follow selection changes: the click decision reads the store at click time, not at configure time. Test in Task 4.
- VoiceOver press on an unshown row's line must follow the same rule as the mouse. Test in Task 4.
- Drag, context menu and rename on the CI line of an unshown row still work (the row handles them once the line declines). Manual step in Task 4.

---

### Task 0: Isolated worktree

**Files:** none tracked.

- [ ] **Step 1:** `git fetch origin master`, then create a native Claude worktree (EnterWorktree, name `parity-fixes`) so it forks fetched `origin/master`. Do not run `git worktree add`.
- [ ] **Step 2:** Symlink the six ignored artifacts from the main checkout into the worktree's `macos/`: `GhosttyKit.xcframework`, `Elis/Resources/{ghostty,terminfo,zmx}` (absolute targets), `.ghostty-build-stamp`, `.zmx-build-stamp`.
- [ ] **Step 3:** Check the stamps first (CLAUDE.md "Worktrees and local builds"): the main checkout's stamps must equal `GHOSTTY_REV` plus the digest of `scripts/ghostty-patches/*.patch`, and `ZMX_REV`, `ZMX_TARGET` plus the digest of `scripts/zmx-patches/**/*.patch`, as the worktree's `scripts/setup.sh` computes them. If a set differs, do not link it and let `scripts/setup.sh` build it.
- [ ] **Step 4:** Verify with `ls -l` that the links resolve. Check `ps` for a leftover `swift` process holding `ElisCore/.build` before the first build.

### Task 1: Keep-awake keeps the display awake

**Files:**
- Modify: `macos/Elis/KeepAwakeController.swift:34`
- Modify: `site/docs.html:1312`, `site/commands.html:3861`
- Modify only if Step 4 fails: `macos/Elis/Views/SettingsView.swift:149`

**Interfaces:** Produces: none. The `beginActivity` call passes `[.idleSystemSleepDisabled, .idleDisplaySleepDisabled]`.

- [ ] **Step 1:** Change the `beginActivity` options to `[.idleSystemSleepDisabled, .idleDisplaySleepDisabled]`. No automated test: there is no seam for `beginActivity`.
- [ ] **Step 2:** Build a Debug instance (`scripts/run.sh` is wrong here, it activates an existing instance; use `xcodebuild` Debug and `open -n --env ELIS_STATE_DIR=/tmp/elis-ka`). Enable Settings > General > Keep the Mac awake, start an agent session with status `active`.
- [ ] **Step 3:** Run `pmset -g assertions` while the agent is active. Pass: `PreventUserIdleDisplaySleep` lists the Debug app's pid with reason "An agent is working"; it disappears within the refresh interval after the agent stops being active.
- [ ] **Step 4:** Manual screen-lock check. Set System Settings > Lock Screen "Start Screen Saver when inactive" and "Turn display off on power adapter when inactive" to 1 minute, "Require password after screen saver begins or display is turned off" to Immediately, with the agent active. Leave the Mac idle 3 minutes with no hot corner set. Pass: the screensaver does not start and the screen does not lock. Record the result and the settings used in the PR description. Restore the settings afterwards.
- [ ] **Step 5:** Docs. In `site/docs.html:1312` and `site/commands.html:3861` replace "on the Mac the display still sleeps and locks" with the checked behavior: on both platforms the screen also stays on. If Step 4 failed (the screen still locks), keep the claim narrow ("the display stays on; the screen can still lock from its own timer") and rename the label at `SettingsView.swift:149` to "Keep the display on while an agent is working", updating every surface that quotes the old label (`grep -rn "Keep the Mac awake" site plugins macos`).
- [ ] **Step 6:** Commit `fix(mac): keep-awake also keeps the display on`.

### Task 2: `legibleOn` in ElisCore

**Files:**
- Create: `shared/ElisCore/Sources/ElisCore/LegibleColor.swift`
- Test: `shared/ElisCore/Tests/ElisCoreTests/LegibleColorTests.swift`

**Interfaces:**
- Produces: `public struct RGBA: Equatable, Sendable { public var r, g, b, a: Double; public init(r:g:b:a:) }` (components 0...1; `a` defaults to 1 via a defaulted init parameter).
- Produces: `public func composite(_ layer: RGBA, over under: RGBA) -> RGBA` (opaque result when `under` is opaque).
- Produces: `public func luminance(_ c: RGBA) -> Double` (WCAG relative luminance of RGB, alpha ignored).
- Produces: `public func legibleOn(_ color: RGBA, under: [RGBA], text: RGBA) -> RGBA`. Linux algorithm exactly: for `step` in 0...20, `t = step / 20`, candidate = `color` mixed toward `text` by `t` per RGB channel, alpha of `color` kept; return the first candidate where every `bg` in `under` has contrast >= 4.5, with contrast = `(max(a, b) + 0.05) / (min(a, b) + 0.05)`, `a = luminance(composite(candidate, over: bg))`, `b = luminance(bg)`; else return `text`. Empty `under` returns `color` (t = 0 passes vacuously).

- [ ] **Step 1: Write failing tests** in `LegibleColorTests` (Swift Testing, `struct LegibleColorTests`, `@testable import ElisCore`):
  - `legibleOnKeepsAColorThatAlreadyPasses`: dark blue `RGBA(r: 0, g: 0, b: 0.5)` over white, text black: `== color`.
  - `legibleOnPushesYellowOffAYellowBandAndAWhiteSidebar`: yellow `(1, 0.8, 0)`, `under = [white, composite(yellow@0.2, over: white)]`, text `(0.1, 0.1, 0.1)`; assert for each `bg` the contrast of the result is `>= 4.5` and the result `!= yellow`.
  - `legibleOnKeepsAlpha`: color alpha 0.55 comes back with alpha 0.55 and contrast (composited) `>= 4.5` over a light `bg`.
  - `legibleOnFallsBackToTheTextColorWhenNothingPasses`: color and text both mid-gray `(0.5, 0.5, 0.5)` over a mid-gray backdrop: returns `text`.
  - `legibleOnMustPassEveryBackdrop`: `under = [white, black]`, color red: result either passes both (contrast >= 4.5 on each) or equals `text`; assert exactly that disjunction.
  - `luminanceMatchesWCAGAnchors`: white is 1, black is 0, `(1, 0, 0)` is `0.2126` within 1e-9.
- [ ] **Step 2:** Run `cd shared/ElisCore && swift test --filter LegibleColorTests`. Expected: FAIL, symbols not defined.
- [ ] **Step 3:** Implement the four symbols in `LegibleColor.swift` per the Interfaces block. Use `pow` from Foundation for the sRGB linearization (`v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)`).
- [ ] **Step 4:** Run the same command. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): legibleOn keeps colored spans at 4.5:1 contrast`.

### Task 3: Adopt `legibleOn` in the CI line

**Files:**
- Modify: `macos/Elis/Views/SidebarInfoCell.swift:121-125` (`color(for:foreground:)`)
- Modify: `macos/Elis/Views/SidebarRowViews.swift` (row view: expose the fills under the line, mirroring `drawBackground` at ~635-650 and the wave at ~490-515)
- Modify: `macos/ElisTests/SidebarInfoRowTests.swift` (existing color tests, new test)
- Modify: `docs/superpowers/specs/2026-11-21-ci-status-line-design.md` (add one line on legibility, see Step 6)

**Interfaces:**
- Consumes: `RGBA`, `composite`, `legibleOn` from Task 2.
- Produces: `SidebarRowView.infoBackdrops: [RGBA]`, the opaque colors under the info line. Built in this order, each layer composited over the previous: the outline's background color, the band at alpha 0.10 if `band` is set, `rowWash` if set, then selected: `selectionColor` at 0.20 (`isEmphasized`) or 0.12, else hovered: terminal foreground at 0.07. When the wave is on, return two colors instead: the base composited with the wave's `base` at 0.20 and with `second` at 0.16 (the strongest stops).
- Produces: `SidebarInfoCellView` reads `(superview as? SidebarRowView)?.infoBackdrops ?? []`; an empty list leaves colors untouched.

- [ ] **Step 1:** Show the owner the current rendering of a red, yellow and green CI line on a light sidebar, a yellow-tinted workspace band, and an active-status row (separate Debug instance, isolated state and socket). Record what the owner sees before and after Step 3.
- [ ] **Step 2:** Update the failing expectations first: in `SidebarInfoRowTests` the tests at `testASelectedRowKeepsColoredFragments…` (~98) and `testARowTintNeverReachesTheInfoLine` (~151) assert the raw tint. Add `testAColoredFragmentStaysLegibleOnTheRowsBackdrop`: seed a session, set a CI with a yellow-colored span on a row inside a yellow-tinted workspace band, mount the sidebar, then assert the composited contrast of the span color over `row.infoBackdrops` is `>= 4.5` for every backdrop, and that an uncolored span's color is unchanged.
- [ ] **Step 3:** Run `xcodebuild … -only-testing:ElisTests/SidebarInfoRowTests/testAColoredFragmentStaysLegibleOnTheRowsBackdrop` (command as in `scripts/test-app.sh`). Expected: FAIL.
- [ ] **Step 4:** Implement `infoBackdrops` and change `color(for:foreground:)`: for a colored span compute `NSColor.tint(tint)` with alpha 1 or 0.55 as today, convert to `RGBA` (sRGB), call `legibleOn(color, under: backdrops, text: RGBA(foreground))`, convert back. Plain spans are untouched. The conversion helpers live in the app target (`NSColor` <-> `RGBA`), not in `ElisCore`. A selection or hover change must re-run `render()` (it already does via `setColors`; add a re-render when `isHovered` or the wave changes if the line does not redraw).
- [ ] **Step 5:** Run the targeted test and the two updated ones with `-only-testing:` for each. Expected: PASS. Capture the same rows in-process, light and dark.
  A separate designer reviewer (not the implementer) compares the before and after captures with the Linux #87 result and the Mac sidebar look: no hue lost, no span that reads as plain text, no other row element changed.
  Fix every difference the reviewer marks as a defect, re-capture, then show the owner the rendered rows.
- [ ] **Step 6:** Docs. Add one sentence to the CI status line spec's color paragraph: colored spans ease toward the text color just far enough to keep 4.5:1 against the fills under them. `site/docs.html` needs no change unless it states raw colors (`grep -n "red\|yellow" site/docs.html` near line 2488; update only if it does).
- [ ] **Step 7:** Commit `fix(mac): CI line colors keep 4.5:1 contrast on every tinted row`.

### Task 4: CI line click rule

**Files:**
- Modify: `macos/Elis/Views/SidebarInfoCell.swift:27` and the click wiring (~44-62, 120-135)
- Modify: `macos/Elis/Views/WorkspaceSidebar+RowRendering.swift:126-130`
- Test: `macos/ElisTests/SidebarInfoRowTests.swift`
- Modify: `docs/superpowers/specs/2026-11-21-ci-status-line-design.md` ("The panel", ~line 60), `site/docs.html:2492`

**Interfaces:**
- Produces: `SidebarInfoCellView.claimsInfoClick: (() -> Bool)?`, evaluated live; nil means no claim. The cell sets itself as the click recognizer's `NSGestureRecognizerDelegate` and `gestureRecognizerShouldBegin(_:)` returns `claimsInfoClick?() ?? false`, so a declined click falls through to the row's selection and drag path with no extra hit-test logic.
- Produces: `SidebarInfoField.onPress` keeps working but `accessibilityPerformPress` returns false when `claimsInfoClick` says no.
- Rule: the closure returns `store.selectedSessionID == node.id`. Read at click time, so a reused cell and a selection change need no refresh.

- [ ] **Step 1: Write failing test** `testACILineOpensThePanelOnlyForTheShownSession` in `SidebarInfoRowTests`: seed two sessions in one store (add a second via `store.addSession`), set `ci()` on both, mount the sidebar, select session A. Assert `infoCell(A).claimsInfoClick?() == true` and `infoCell(B).claimsInfoClick?() == false`; drive each field's recognizer delegate: `gestureRecognizerShouldBegin` is true for A, false for B. Then call `store.selectSession(B.id)` without reloading and assert the answers flip. If a click can be posted to the mounted outline (as other tests in this file do), also post one at B's line and assert `store.selectedSessionID == B` and no popover shown.
- [ ] **Step 2:** Run `-only-testing:ElisTests/SidebarInfoRowTests/testACILineOpensThePanelOnlyForTheShownSession`. Expected: FAIL (`claimsInfoClick` undefined).
- [ ] **Step 3:** Implement the interface above. In `WorkspaceSidebar+RowRendering.swift` set `infoCell.claimsInfoClick = { store.selectedSessionID == node.id }` next to `onInfoClick`, which keeps opening the panel. Update the doc comment at `SidebarInfoCell.swift:27` to state the rule once: the line claims its click only on the shown session.
- [ ] **Step 4:** Run the new test and the existing `testACIChangeRefreshesTheMountedSidebarAndTheLineTakesItsClick` (it asserts the recognizer exists with `delaysPrimaryMouseButtonEvents`; keep it passing). Expected: PASS.
- [ ] **Step 5:** Manual check in a Debug instance with two sessions. Pass: a click on the unshown row's CI line selects it and opens no panel; a click on the shown row's line opens the panel; dragging an unshown row by its CI line reorders it; right-click on the line opens the row's menu; double-click rename still starts from the name.
- [ ] **Step 6:** Docs. Spec "The panel": replace "The click does only that; selecting the session stays the click on the name band." with the rule once: a click on the shown session's line opens the panel, a click on any other session's line selects it like a row click. `site/docs.html:2492`: change "Click the line for the details" to "Click the shown session's line for the details; a click on another session's line selects it."
- [ ] **Step 7:** Commit `fix(mac): only the shown session's CI line opens the panel`.

### Task 5: Full gates and PR

**Files:** none.

- [ ] **Step 1:** From `macos/`, once each: `make build`, `make test` (host-free ElisCore), `make test-app`, `make lint`. Expected: all pass, zero lint findings. If an intermittent failure appears, look it up in `docs/ci-flakes.md` by test name first.
- [ ] **Step 2:** `lsappinfo list | grep -A4 elis.debug`; stop leaked test processes (known pids only) and any Debug instance from Tasks 1, 3, 4 by SIGTERM to its pid. Confirm the Dock tile is gone.
- [ ] **Step 3:** `/code-review` (or the `cross-model-review` workflow) on the diff; verify each finding against the code before acting.
- [ ] **Step 4:** Open the PR to `master`. Description: three fixes, the Task 1 Step 4 screen-lock result with its settings, a link to the spec. End with `https://claude.ai/code/session_018MUCCRrKVLC4vh25eZbATw`.
- [ ] **Step 5:** After merge, verify the merge commit on fetched `origin/master`, then remove the worktree from a session started in the main checkout.

---

## Self-review

- Spec coverage: item 1 (Task 1, label decision and both docs), item 2 (Tasks 2-3, all four spec test cases plus extras), item 3 (Task 4, tests and both docs), builder decisions (Task 1 Step 4/5, Task 4 interface), gates once (Task 5).
- Types: `RGBA`, `composite`, `luminance`, `legibleOn`, `infoBackdrops`, `claimsInfoClick` are named identically wherever used.
- Open points for the implementer, not decided here: the exact outline background color source for `infoBackdrops`.
