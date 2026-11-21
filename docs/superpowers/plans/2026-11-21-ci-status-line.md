# GitHub CI line Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** the second sidebar line shows a session's GitHub CI summary from `gh`; `session info` is removed.

**Architecture:** `ElisCore` owns the model (`CIStatus`), the probe (`CIRepo`, `CIProbe`) and the poller
(`CIPoller`, closures for sessions and apply). `Session.ci`/`mirroredCI` replace `info`/`mirroredInfo`, a `ci`
presentation kind replaces `info`, and `ControlSessionNode.ci` replaces the three info fields.
The Mac app and elis-server run the poller; the Qt app calls `ElisBridge/CIInfo.swift`.

**Tech Stack:** Swift 6 (ElisCore, AppKit, SwiftUI), Qt6 C++ through the ElisBridge C ABI.

**Spec:** `docs/superpowers/specs/2026-11-21-ci-status-line-design.md`

## Global Constraints

- No `gh`, a failure or a timeout → no line, no error UI; a failed refresh clears a shown line.
- Intervals: runs 30 s while one runs, 180 s settled; PR 120 s; calls time out at 15 s; poll tick 5 s (the
  tick replaces the spec's 2 s debounce: a cwd change is seen within one tick).
- Only local sessions are polled (`remoteHost == nil`, `remotePresentation == nil`).
- `ElisCore` imports no AppKit; everything new in it builds and tests on Linux.

## Review Focus

- A repository whose `gh run list` is `[]` and has no open PR: no line, not `✓ 0 passed`.
- A detached HEAD or a cwd outside git: no line and no `gh` call.
- Two sessions in one repository and branch: one fetch, both rows updated.
- A session that `cd`s out of the repository: its line clears on the next tick.
- A viewer of an older version: the `ci` kind is filtered by hello negotiation, nothing breaks.

---

### Task 1: model and line (`CIStatus.swift`)

`CIRunState` (running/failed/passed/skipped, `init(status:conclusion:)` per the spec table), `CIRun`
(workflow, state, url), `CIPullRequest` (number, title, url, approved, changesRequested: `[String]`),
`CIStatus` (branch, sha, pr, runs; Codable; `spans: [SessionInfoSpan]`).
Tests: every line rule and example in the spec, empty runs with/without PR.

### Task 2: probe (`CIProbe.swift`)

`CIRepo.locate(cwd:)` walks up to `.git` (directory, or a `gitdir:` file for worktrees) and reads `HEAD`.
`CIProbe.runs(_:run:)`, `CIProbe.pullRequest(_:run:)`, `CIProbe.gh` (Process, widened PATH, 15 s).
Tests: fixture JSON, newest-sha filter, one run per workflow, non-OPEN PR, worktree `.git` file, detached HEAD.

### Task 3: poller (`CIPoller.swift`)

`@MainActor final class CIPoller(sessions:apply:runner:now:locate:)`, `tick() async`, `start()`, `stop()`.
Tests with a fake runner and clock: intervals, shared fetch, clear on failure, cwd leaving the repo.

### Task 4: replace `session info` in ElisCore and elis-server

Remove `SessionInfo`, its markup parser and `PortableMarkdown`'s span path (keep `SessionInfoSpan`), the
command, dispatcher, actions, elisctl subcommand, `ServerActions+Info`, expiry timers, presentation `info`.
Add `Session.ci`/`mirroredCI`/`effectiveCI`, `AppStore.setCI`, `applyRemoteCI`, presentation kind `ci`,
`ControlSessionNode.ci`. elis-server starts a `CIPoller`. Update and delete the affected tests.

### Task 5: Mac app

Row line from `effectiveCI?.spans`; poller started at launch, sessions filtered by the display setting
(Off → none, Flagged → flagged); click on the line opens an NSPopover (SwiftUI) with PR, reviews and runs;
remove `ControlServer+SessionInfo`; relabel the picker "CI status"; update hosted/UI tests.

### Task 6: docs, skill, site, rules, cookbook

Remove `session info` from `site/docs.html`, `site/commands.html`, the skill, `ARCHITECTURE.md`, `.claude/rules`;
document the CI line and the `ci` read-back; delete the three recipes and their index rows.

### Task 7: Linux bridge (after the Linux phase 1 branch lands)

`ElisBridge/CIInfo.swift`: `elis_ci_probe(cwd) → JSON`, `elis_ci_line(JSON) → spans JSON`; the Qt timer and popup.
