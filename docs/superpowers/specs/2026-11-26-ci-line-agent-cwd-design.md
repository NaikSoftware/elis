# CI line follows the agent's working directory

## Problem
The CI/PR line resolves `(repo root, branch)` from `Session.focusedCwd` (`CIPoller.tick`, `CITracker`, `CIRepo.locate`).
A Claude Code session started in the main checkout that moves into a worktree (`EnterWorktree`, `.claude/worktrees/*`)
keeps the pane's OSC 7 cwd and the `claude` process cwd (lsof) in the main checkout. So the line shows `master`
while the agent works on another branch. Evidence: Claude transcripts record `"cwd":".../.claude/worktrees/<x>"` and
`gitBranch` of the worktree for the same session whose pane cwd stays at the repo root.

## Goal
The CI line of a session shows the branch the pane's agent works in. No agent, or no reported directory: unchanged.

## Non-goals
- Subagent worktrees (`Agent` with `isolation: worktree`): several can run in parallel, no single branch. Only the lead agent's directory counts.
- Parsing agent transcripts.

## Approaches
1. **Hook reports the agent cwd (picked).** Claude Code hook payloads carry `cwd` (the session's current directory, which follows `EnterWorktree`). The status adapter forwards it with `elisctl session status <state> --cwd <dir>`. Agent-agnostic: any adapter whose payload has a cwd (codex too) can send it.
2. Read the agent process cwd (`proc_pidinfo`). Rejected: Claude does not `chdir` on `EnterWorktree`; lsof shows the repo root.
3. Read `gitBranch` from the Claude transcript. Rejected: Claude-only, private file format.

## Design (revised after architecture review)
- Precondition: the builder probes one real Claude hook payload after `EnterWorktree` and confirms `cwd` is the worktree. If not, stop and report.
- Protocol: `session.status` takes an optional absolute `cwd`. CLI `elisctl session status ... --cwd <dir>`. Path guarding stays in `CIRepo.locate` (`LinkPolicy.guardedLocalPath`).
- Model: `Session.paneAgentCwd: [StatusPane: String]`, a dictionary of its own next to `paneActivity` (NOT its lifetime). Written in `applyControlStatus` (new parameter) before the early return under another pane's block, so the Mac and elis-server adapters both get it. A write skipped by `--if-idle` drops its cwd too (the lead agent never sends `--if-idle`). `cwd` for `.scratch` is ignored.
- Lifetime: one rule. A pane's entry lives while that pane's agent sample has an agent. `applyAgentSamples` (`AppStore+Agent.swift`) clears it when the sample says no agent (Mac and elis-server samplers). Status changes (idle, interrupt, Clear Status, auto-reset) do NOT clear it. Pane moves carry it: swap, promotion, close (`AppStore+Panes.swift`), companions move (`AppStore+Companions.swift`). Not persisted; the next hook refills it after restore.
- `Session.ciCwd`: the focused pane's agent cwd, else `focusedCwd`. `CIPoller` uses it. Nothing else changes.
- Adapter: `elis-claude-status.sh` appends `--cwd "$(field cwd)"` right before `exec`, after the `set -- active --blink` rewrite, only without `agent_id` and only when non-empty. Codex: no change.
- Read-back: `ci.branch` on the session node (no new `agentCwd` field; a remote presentation frame would not carry it). Record this in `control-api.md`.
- Remote: an attached Mac or elis-server session gets `ci` from the origin, which polls with its own store. No new code.
- Linux Qt app: out of scope (owner rule: Mac changes stay Mac-only unless Linux is asked). Its `elisctl` ignores the unknown `--cwd`, so the shared adapter does not break status there.
- Docs: `site/docs.html` CI line section, `site/commands.html`, `control-api.md`, `plugins/elis/skills/elis/`.
- Tests: ElisCore dispatcher parses `cwd`; store sets per pane, keeps it across status changes, clears on a no-agent sample, carries it across pane moves; `ciCwd` precedence; CIPoller uses it.
