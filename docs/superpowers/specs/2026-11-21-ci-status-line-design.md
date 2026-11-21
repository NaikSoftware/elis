# GitHub CI line under a session row — design

Status: draft, waiting for the owner's answer on the `session info` API (Open question 1).

## Intent

A session that works in a GitHub repository shows that repository's CI state on the second line of its sidebar row:
how many checks run, failed and passed, short enough to read at a glance.
A click on the line opens a panel with the details, and the panel opens the PR in the browser.
For an open PR the line and the panel also count approvals and change requests.
The point is to watch the CI of what agents push without leaving the terminal.

## Goals

- Mac app and Linux Qt app, with the shared logic in `shared/ElisCore` (owner, 2026-11-21).
- Data only through `gh`. No `gh`, not logged in, not a GitHub remote, an unpushed commit, a network error, a
  timeout: no line and no error UI (owner).
- Remote sessions (another Mac, elis-server host) show the same line, produced on the host that owns the session.

## Non-goals

GitLab or other forges, re-run/cancel buttons, notifications on failure, polling settings, prompting to install
or log in to `gh`.

## Data

The repository is the session's focused cwd (`Session.focusedCwd` on the Mac): `git rev-parse --show-toplevel`,
the branch, the HEAD sha. Then, run in the repository root:

1. `gh pr view --json number,title,url,state,reviewDecision,latestReviews,statusCheckRollup` for the current branch.
   An OPEN PR gives the checks (`statusCheckRollup`: CheckRun and StatusContext) and the reviews.
   Reviews count the latest review per reviewer: APPROVED and CHANGES_REQUESTED.
2. No open PR: `gh api repos/{owner}/{repo}/commits/<sha>/check-runs` for the HEAD commit.

No checks and no open PR → no line. The `gh` host comes from the remote, so GitHub Enterprise works when `gh` is
logged in there.

Check states:

| Group | gh values |
| --- | --- |
| running | queued, in_progress, waiting, pending, requested, expected |
| failed | failure, timed_out, cancelled, action_required, startup_failure, stale, error |
| passed | success, neutral |
| skipped | skipped: not counted, shown dimmed in the panel |

## The line

Parts in this order, each only when it has something to show, truncated at the tail:

1. Open PR: `#56`, then `👍2` approvals and `👎1` change requests.
2. Checks, failed → running → passed, colored red / yellow / green:
   - one check: its name with its glyph: `✗ Unit tests`;
   - all in one group: `✓ 8 passed`, `◷ 3 running`, `✗ 2 failed`;
   - mixed: `✗ 2  ◷ 1  ✓ 5`, and a single failure names itself: `✗ Unit tests  ◷ 1  ✓ 5`.

Examples: `#56 👍1 · ✗ Unit tests  ◷ 2  ✓ 5`, `✓ build`, `#61 👎1 · ✓ 9 passed`.

## The panel

A click on the line opens a popover anchored to it (NSPopover on the Mac, a `Qt::Popup` widget on Linux).
The click does only that; selecting the session stays the click on the name band.

- Header: `#56 PR title`, a link that opens the PR; without a PR, `branch · abc1234`.
- Reviews: `Approved: alice, bob`, `Changes requested: carol`, or `Review required`.
- Checks grouped Failed / Running / Passed / Skipped, `workflow / job`, each opening its details URL.
- Footer: when it was last updated.

Escape or a click outside closes it.
A remote viewer builds it from the mirrored data and opens links in its own browser.

## Refresh

One poller per (repository root, branch), shared by every session in it, stopped when none refers to it.
Every 20 s while a check runs, every 120 s once all settled.
A cwd change, and a HEAD change seen on a cycle, refresh at once (2 s debounce).
Each `git`/`gh` call has a 15 s timeout.

## Where the code goes

- `shared/ElisCore`: the model and `gh` JSON decoding, the state groups, the line spans, the probe (git + gh via
  `Process`, injectable runner), and the poller (injectable clock). Everything here builds and tests on Linux.
- Mac app: store wiring, the row line (existing `SidebarInfoCellView`), the popover.
- elis-server: runs the same poller for its sessions; a new presentation frame carries the result to viewers,
  which keep it as the mirrored value, as `PresentationInfo` does today.
- Linux: `linux/bridge/Sources/ElisBridge/CIInfo.swift` (not `Bridge.swift`): `elis_ci_probe(cwd) → JSON`,
  called on a worker thread, and `elis_ci_line(JSON) → spans`. The Qt app owns its timer and popup.
  Linux UI waits for the Linux phase 1 branch to land (it rewrites `sidebar.cpp`).

## Control API

Proposed: a read-only `ci` object on `ControlSessionNode` (tree and session read-back) with `pr` (number, url,
approved, changesRequested), the three counts and `checks` (name, workflow, state, url). No setter, no refresh
command. Agents can read "is my PR green" from it.

## Settings

The existing Settings ▸ Interface "Session info" picker (Always / Flagged / Off) governs the line; no new
preference.

## Open question 1: the `session info` API

The owner asked to remove `session info` as unused. Three published cookbook recipes call it:
`claude-git-info` (@umputun), `multi-agent-git-info` (@megabyde), `subagent-status` (@bubakanov).

- Remove it: the line belongs to CI alone; those recipes stop working, and their authors would have to drop them.
  Removed: protocol command, dispatcher, `elisctl session info`, elis-server's `ServerActions+Info`, the
  hide-after timers, the markdown source, the `info`/`infoMarkdown`/`infoHideAfter` read-back, docs, skill, site.
- Keep it: the CI line is its own line under the info line, both independent; the row grows by one line per line
  shown.

## Testing

ElisCore tests with fixture JSON from real `gh` output: decoding, groups, every line rule, the poller's intervals
and debounce with a fake runner and clock. The Mac UI cannot build on this Linux machine; its CI job builds it,
and the owner checks the look on a Mac. Linux: ctest for the bridge calls, then a visual check of the Qt app.
