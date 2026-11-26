# CI Line Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the CI line's popover panel with a plain native menu on the Mac.

**Architecture:** The item list (titles, URLs, enabled state, order) is built by one pure function
and tested directly; the menu shown is just those items. The Mac drops `NSPopover`/`CIStatusPanel`.

**Tech Stack:** Swift 6 AppKit (`NSMenu`). Linux is out of scope.

**Spec:** `docs/superpowers/specs/2026-11-26-ci-line-menu-design.md`

## Global Constraints

- Item order: PR title (if PR) → review lines (disabled) → separator → runs grouped failed, running, passed, skipped.
- Review lines: `Approved: a, b`, `Changes requested: c`, or `No reviews yet` when both are empty.
- Run item: glyph (`✗`, `◷`, `✓`, skipped glyph as today) in the state color, a space, the workflow name.
- No `branch · sha` headline, no state captions. Only `https` URLs open.
- The menu opens below the CI line at its leading edge.
- The menu closes when the session's CI line goes.
- Control API unchanged. Keep `.claude/rules/sidebar.md` and `site/docs.html` in sync if they describe the panel.

## Review Focus

- A session without a PR: the menu starts directly with runs, no leading separator.
- Only skipped runs: names are secondary color, still clickable.
- The line disappears while the menu is open: the menu closes, no stale menu.
- A non-https URL: the item does nothing.
- Repeated clicks: one menu at a time.

---

### Task 1: Mac menu

**Files:**
- Modify: `macos/Elis/Views/CIStatusLine.swift` (replace `showPanel`'s popover and the `CIStatusPanel` view)
- Modify: `macos/Elis/Views/SidebarInfoCell.swift` (drop `textRect` if no longer used)
- Test: `macos/ElisTests/SidebarInfoRowTests.swift` (replace the popover anchor test)

**Interfaces:**
- Produces: `CIStatusLine.menuItems(for ci: CIStatus) -> [NSMenuItem]` (internal, testable);
  `CIStatusLine.showMenu(for: Session, from: SidebarInfoField)` replaces `showPanel`.

- [ ] Write failing tests: `testTheCIMenuListsThePRReviewsThenRunsByState` (titles in spec order, review lines
  disabled, one separator), `testTheCIMenuWithoutAPRStartsWithRuns`, `testTheCIMenuClosesWhenTheLineGoes`.
- [ ] Run them scoped: `lockf -k /tmp/elis-hosted-tests.lock xcodebuild test ... -only-testing:ElisTests/SidebarInfoRowTests` → FAIL.
- [ ] Implement: items carry the URL in `representedObject`; one action target opens https URLs.
  Pop up with `menu.popUp(positioning: nil, at: NSPoint(x: field.bounds.minX, y: field.bounds.maxY or minY per flipped), in: field)`.
  Track the open menu so the CI-gone path calls `cancelTracking()`.
- [ ] Run scoped tests → PASS. Commit.

### Finish

- [ ] Gates once: `make build`, `make test`, `make lint`, `make test-app` (under the lockf).
- [ ] Push to `fix/ci-line-anchor-repo` (PR #125); update its body.
- [ ] Designer checks the rendered menu (light and dark) against the spec.
