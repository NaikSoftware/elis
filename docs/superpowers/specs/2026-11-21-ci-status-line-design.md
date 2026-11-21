# GitHub CI line under a session row — design

## Intent

A session that works in a GitHub repository shows that repository's CI state on the second line of its sidebar row:
how many workflows run, failed and passed, short enough to read at a glance.
A click on the line opens a panel with the details, and the panel opens the PR in the browser.
For an open PR the line and the panel also count approvals and change requests.
The point is to watch the CI of what agents push without leaving the terminal.

## Owner decisions (2026-11-21)

- Mac app and Linux Qt app together, shared logic in `shared/ElisCore`.
- Data only through `gh`. No `gh`, not logged in, not a GitHub remote, a network error, a timeout: no line, no
  error UI.
- The `session info` API is removed; the second line becomes internal and shows only CI.

## Non-goals

GitLab or other forges, re-run/cancel buttons, notifications on failure, polling settings, prompting to install
or log in to `gh`, jobs inside a workflow run (the run's GitHub page shows them).

## Data

The repository is the session's focused cwd (`Session.focusedCwd`, the same cwd the row and title already track),
found by reading `.git` and `HEAD` upward from it off the main actor, with no git process. Then, in the root:

1. `gh run list --branch <branch> --limit 30 --json databaseId,workflowName,status,conclusion,headSha,url,updatedAt`.
   The runs counted are those of the newest `headSha` in that list, one per workflow (the latest attempt).
   This is the last pushed commit, so local unpushed commits keep the line of the last push.
2. `gh pr view --json number,title,url,state,reviewDecision,latestReviews`. An OPEN PR adds its number and reviews;
   reviews count the latest review per reviewer, APPROVED and CHANGES_REQUESTED.

No runs and no open PR → no line. A detached HEAD → no line.
`gh` picks the host from the remote, so GitHub Enterprise works when `gh` is logged in there.

Run states (my call):

| Group | gh values |
| --- | --- |
| running | queued, in_progress, waiting, pending, requested |
| failed | failure, timed_out, cancelled, action_required, startup_failure, stale |
| passed | success, neutral |
| skipped | skipped: not counted, listed dimmed in the panel |

## The line

Parts in this order, each only when it has something to show, truncated at the tail:

1. Open PR: `#56`, then `👍2` approvals and `👎1` change requests.
2. Runs, failed → running → passed, colored red / yellow / green:
   - one run: its workflow name with its glyph: `✗ build`;
   - all in one group: `✓ 3 passed`, `◷ 3 running`, `✗ 2 failed`;
   - mixed: `✗ 2  ◷ 1  ✓ 5`, and a single failure names itself: `✗ build  ◷ 1  ✓ 2`.

Examples: `#56 👍1 · ✗ build  ◷ 1  ✓ 2`, `◷ build`, `#61 👎1 · ✓ build`, `#62 👍2` (no runs).

## The panel

A click on the line opens a popover anchored to it (NSPopover on the Mac, a `Qt::Popup` widget on Linux).
The click does only that; selecting the session stays the click on the name band.
Cost on the Mac: the line becomes its own hit target inside an `NSOutlineView` row, so the cell must pass drags,
the context menu and rename through untouched. The owner asked for the click, so this cost is accepted.

- Header: `#56 PR title`, a link that opens the PR; without a PR, `branch · abc1234`.
- Reviews: `Approved: alice, bob`, `Changes requested: carol`, or `No reviews yet` (the review decision is not
  fetched, so "required" cannot be told from "optional").
- Runs grouped Failed / Running / Passed / Skipped by workflow name, each opening its run page.
- No "last updated" footer: a failed refresh already clears the panel, so a shown one is current.

Escape or a click outside closes it. A remote viewer builds it from the mirrored data and opens links in its own
browser.

## Refresh

- One poller per (repository root, branch), shared by every session in it, stopped when none refers to it and
  when Settings ▸ Interface hides the line (Off stops the polling, not only the drawing).
- Runs every 30 s while one runs, every 3 min once all settled; the PR every 2 min while open.
  Worst case per branch is about 150 GitHub requests an hour; ten active branches stay near 1500 of the 5000 an
  hour that the owner's agents share with Elis.
- The poller ticks every 5 s; a cwd or branch change seen on a tick refreshes at once.
- Each `git`/`gh` call has a 15 s timeout.
- A failed refresh clears the line and closes its open panel, so a stale "passed" never outlives the fact.

## Mac process constraints

- PATH: a Finder-launched app has no Homebrew PATH, so `gh` is resolved through `CommandPath.widened` as
  `CustomCommandRunner` and `OpenCodeEnvironmentProbe` do.
- TCC: the app reading `.git` and spawning `gh` in a repository under `~/Documents`, `~/Desktop` or `~/Downloads`
  may raise a folder prompt attributed to Elis. Check on a Mac that a repository in `~/Documents` raises no new
  prompt before the PR merges.

## Where the code goes

- `shared/ElisCore`: the model, `gh` JSON decoding, the groups, the line spans, the probe (git + gh via `Process`,
  injectable runner) and the poller (injectable clock). All of it builds and tests on Linux.
- `Session.info`/`mirroredInfo`/`effectiveInfo` become `ci`/`mirroredCI`/`effectiveCI` of the new model.
- Remote presentation: a new frame kind `ci` replaces `info`. Unknown kinds decode as `.unknown` and the hello
  negotiates kinds, so a viewer and an origin on different versions only miss the line, never break.
  elis-server runs the same poller for its sessions.
- Mac app: store wiring, the row line in `SidebarInfoCellView`, the popover.
- Linux: `linux/bridge/Sources/ElisBridge/CIInfo.swift` (not `Bridge.swift`): `elis_ci_probe(cwd) → JSON`, called
  on a worker thread, and `elis_ci_line(JSON) → spans` in the JSON shape the phase 1 renderer already takes:
  `[{text, bold, italic, code, dim, color?}]`, `color` one of ElisCore's 12 colour names.
  Phase 1 removes `elis_session_info`, so Linux shows no second line until this feed lands.
  The Qt app owns its timer and popup. Linux UI waits for the Linux phase 1 branch to land.

## Removed with `session info`

Protocol command, dispatcher, `ControlActions` entry, `elisctl session info`, elis-server `ServerActions+Info`, the
hide-after timers, the markdown source path of `SessionInfoMarkup` (span rendering stays for the CI line), the
`info`/`infoMarkdown`/`infoHideAfter` read-back, `EventFormatter` text, `site/docs.html`, `site/commands.html`,
the skill (`SKILL.md`, `reference.md`, `linux.md`), `ARCHITECTURE.md` and `.claude/rules` (`control-api.md`,
`sidebar.md`, `settings.md`). The cookbook recipes that called it go too (below).

## Control API

A read-only `ci` object on `ControlSessionNode`: `branch`, `sha`, `pr` (number, title, url, `approved` and
`changesRequested` logins) and `runs` (workflow, state, url). No counts: they follow from `runs`. No setter, no
refresh command. Agents can read "is my PR green" from it.

## Settings

The existing Settings ▸ Interface "Session info" picker (Always / Flagged / Off) is relabelled "CI status" and
governs the line; no new preference.

## Cookbook

The three recipes that called `session info` (`claude-git-info`, `multi-agent-git-info`, `subagent-status`) are
removed with it (owner, 2026-11-21).

## Testing

ElisCore tests with fixture JSON from real `gh` output: decoding, groups, every line rule, the poller's intervals,
debounce and clear-on-failure with a fake runner and clock. The Mac UI cannot build on this Linux machine: its CI
job builds it, and the owner checks the look and the TCC case on a Mac. Linux: ctest for the bridge calls, then a
visual check of the Qt app.
