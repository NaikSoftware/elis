# Homebrew tap for Elis

## Intent

Users install and upgrade Elis with `brew install --cask naiksoftware/tap/elis`.
The owner does nothing extra per release: publishing the GitHub release updates the cask.

## Goals, non-goals

- Goal: a public tap `NaikSoftware/homebrew-tap` with `Casks/elis.rb`.
- Goal: a published (non-prerelease) release of `NaikSoftware/elis` rewrites the cask's `version` and `sha256`.
- Goal: the cask removes the quarantine flag, so the unnotarized app opens without `xattr`.
- Non-goal: a `release` branch, a version gate, CI builds of the DMG, the official `homebrew/cask`.

## Approaches

- Chosen: a workflow in `elis` on `release: published` pushes to the tap with a deploy key.
- Rejected: a `release` branch whose merge updates the cask (owner dropped it: the DMG is built locally anyway).
- Rejected: the tap polls releases on a schedule (no token, but not triggered by the publish).

## Decisions

- `release.sh` creates the release as a draft, uploads the assets, then publishes it.
  Without this, `published` fires before the DMG exists.
- The workflow reads the DMG's sha256 from the release asset `digest`; it fails when the DMG is missing.
- Quarantine removal follows the upstream agterm cask: `preflight_steps` on `{{staged_path}}`,
  warning instead of failing. A `postflight` on the bundle in `appdir` can be refused by TCC.
- `workflow_dispatch` with a `tag` input retries a failed update.
- Secret: `HOMEBREW_TAP_DEPLOY_KEY`, an SSH deploy key with write access to the tap only (no expiry, no account-wide scope).
