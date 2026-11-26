# Homebrew tap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish Elis as a Homebrew cask that updates itself on every GitHub release.

**Architecture:** A separate tap repo holds the cask; a workflow in `elis` rewrites it on `release: published`.

**Tech Stack:** Homebrew cask DSL, GitHub Actions, `gh`.

**Spec:** `docs/superpowers/specs/2026-11-25-homebrew-tap-design.md`

## Global Constraints

- Tap: `NaikSoftware/homebrew-tap`, public, default branch `main`.
- Asset name: `Elis-<x.y.z>.dmg`; tag `v<x.y.z>`.
- Secret: `HOMEBREW_TAP_DEPLOY_KEY`.

## Review Focus

- A prerelease must not update the cask.
- A tag that is not `v<x.y.z>` fails before anything is written.
- Re-running for the version already in the cask is a no-op, not a failed push.

---

### Task 1: Tap repo

- [ ] Create `Casks/elis.rb` (1.0.0, sha256 from the v1.0.0 asset digest) and `README.md`.
- [ ] `brew audit --cask --strict --online naiksoftware/tap/elis` and `brew style` pass.
- [ ] Create the repo and push.

### Task 2: Workflow and release.sh

**Files:** Create `.github/workflows/homebrew-tap.yml`; modify `macos/scripts/release.sh` publish block.

- [ ] Workflow: prerelease guard, tag regex, digest lookup, sed on `version`/`sha256`, commit only on change.
- [ ] `release.sh`: `gh release create --draft`, upload, `gh release edit --draft=false`.
- [ ] `actionlint` and `bash -n` pass.

### Task 3: Docs

- [ ] Add the brew command to README, `site/docs.html`, `site/index.html`, `site/llms.txt`; update `.claude/rules/release.md`.

### Task 4: Token and verification

- [ ] Create the deploy key and set the secret.
- [ ] After merge, `gh workflow run homebrew-tap.yml -f tag=v1.0.0` succeeds with no tap change.
