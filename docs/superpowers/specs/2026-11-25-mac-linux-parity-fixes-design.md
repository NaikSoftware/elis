# Mac and Linux parity fixes: keep-awake display, CI line contrast, CI line click

## Intent

The Linux app got three fixes that the Mac app lacks.
The owner approved all three for the Mac, and chose the Linux click rule for both platforms.
No new control API: nothing in the repo opens the CI panel except the row click (`CIStatusLine.showPanel` has one caller), so no command needs to stay consistent.

## 1. Keep-awake also keeps the display awake

Linux PR #99 (`fce4282b`, `linux/src/app/main.cpp`) adds a ScreenSaver inhibit beside the PowerManagement one.
Reason: on a locked screen the agent got stale screenshots and its input landed in the password field.

- `macos/Elis/KeepAwakeController.swift:34` passes only `.idleSystemSleepDisabled` to `ProcessInfo.beginActivity`.
- Change: pass `[.idleSystemSleepDisabled, .idleDisplaySleepDisabled]`, the matching ProcessInfo option (no raw IOPM assertion needed).
- Unverified: whether a display that never sleeps also stops the screensaver and the screen lock.
  The lock can still fire from its own "require password after N" timer or a hot corner.
  The builder checks this by hand with a Debug instance and records the result in the PR.
- Text to update if it states the old behavior:
  - `site/docs.html:1312` ("on the Mac the display still sleeps and locks");
  - `site/commands.html:3861` (same claim);
  - `macos/Elis/Views/SettingsView.swift:149` label "Keep the Mac awake while an agent is working" is still true; change it only if the hand check shows the lock still fires.
- Tests: no seam for `beginActivity`; none added.

## 2. CI line colors keep 4.5:1 contrast

Linux PR #87 (`dcf7fbf6`, `linux/src/app/sidebar.cpp`, `legibleOn`).
Problem: a raw red, yellow or green span merges into a yellow status band and washes out on a light sidebar.

- `macos/Elis/Views/SidebarInfoCell.swift:122` returns raw `NSColor.tint(tint)` with alpha 1 or 0.55.
- Linux algorithm, to mirror exactly:
  - the delegate tracks the opaque color under the line by compositing each fill it paints: window background, then the group band at alpha 0.10, then the row tint at 0.09, then the status or selection fill at 0.20 (key window) or 0.12;
  - `legibleOn(color, under[], text)` tries 21 steps `t = 0, 0.05 … 1.0`, mixing the span color by `t` toward white or black, whichever contrasts more with the base backdrop (owner decision, Mac and Linux; mixing toward the text color erased hue), and keeping its alpha;
  - it returns the first mix where every background `bg` in `under` gives WCAG contrast of at least 4.5, comparing the luminance of `bg` with the luminance of the span color composited over `bg`; if none passes, it returns the text color;
  - it runs only for colored spans, and plain text is untouched.
- Mac approach: add a pure `legibleOn` in `ElisCore` (Double-backed RGBA, no AppKit) with the composite and WCAG luminance helpers.
  `SidebarCellView` computes the `under` list from the fills it already draws, and `color(for:foreground:)` calls `legibleOn` for colored spans.
- Tests: `ElisCore` unit tests for `legibleOn`:
  - a passing color is returned unchanged;
  - yellow over a yellow band and over a white sidebar reaches 4.5;
  - an impossible case falls back to the text color;
  - alpha is kept.
  Hosted tests in `SidebarInfoRowTests` check the rendered line against the row's backdrops; show the owner the rendered rows in a Debug instance first.

## 3. CI line click rule

Linux PR #86 (`1c3a9ee8`, `sidebar.cpp`, `cipanel.cpp`).
Rule, same on both platforms: a click on the CI line of a session that is not shown selects it, like a row click.
A click on the shown session's CI line opens the CI panel.
A click with a modifier (Control, Shift; Command on Mac) never opens it and reaches the row: menu or selection extension.

- `macos/Elis/Views/SidebarInfoCell.swift:27` documents `onInfoClick` as claiming every click.
- `macos/Elis/Views/WorkspaceSidebar+RowRendering.swift:126-130` opens the panel for any row.
- Approach: the `onInfoClick` closure opens the panel only when `node.id` is the shown session in `store`; otherwise it does not claim the click, so the row's normal selection and drag path runs.
  The cell needs a way to decline a click (for example `onInfoClick` returns `Bool`, or the field's `hitTest` checks a `claimsClick` flag set at configure time).
  The builder picks the one that keeps drag, context menu and rename untouched.
- The flag must refresh when selection changes, since a reused cell keeps its closure.
- Docs: `docs/superpowers/specs/2026-11-21-ci-status-line-design.md` ("The panel", ~line 60: "The click does only that; selecting the session stays the click on the name band") and `site/docs.html:2492` ("Click the line for the details").
  Both state the new rule once.
- Tests: a hosted test with two session rows, in `ElisTests/SidebarInfoRowTests.swift`: a click on an unshown row's line selects it and shows no panel; a click on the shown row's line shows the panel; a modified click on it shows none.

## Left to the builder

- Run the by-hand display-lock check in item 1 and decide the settings label.
- Pick the click-decline mechanism in item 3.
- Gates once at the end: build, `swift test`, `make test-app`, `make lint`.
