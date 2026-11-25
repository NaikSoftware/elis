---
name: release-elis
description: Use when the owner asks to release, publish, ship or cut a new Elis version (vX.Y.Z), to write its changelog section, or to check the GitHub release, the DMG, the APK or the Homebrew cask after one.
---

# Release Elis

`macos/scripts/release.sh` builds, signs, packages and publishes locally on the owner's Mac.
`.claude/rules/release.md` owns the mechanics; this is the order to run them in.
Ask the owner for the version and whether the release ships the phone app before step 1.

## Preconditions

- Work in a native worktree of fetched `origin/master`, with the artifacts linked as `CLAUDE.md`'s
  "Worktrees and local builds" says; otherwise `setup.sh` rebuilds libghostty and zmx.
- Docker runs (Rancher Desktop: `PATH=$HOME/.rd/bin:$PATH`); every `release.sh` run builds the `elis-server` tarballs in it.
- No `Developer ID Application` identity: `--publish` needs `ELIS_ALLOW_UNSIGNED=1`.

## Steps

1. **Changelog.** Find the last release date with `gh release view -R NaikSoftware/elis --json publishedAt`, then list
   `gh pr list -R NaikSoftware/elis --state merged --search "merged:>YYYY-MM-DD"`.
   Add `## vX.Y.Z - YYYY-MM-DD` at the top of `macos/CHANGELOG.md`, grouped under `### New Features` and `### Bug Fixes`.
   Describe Elis as its own product: never mention agterm or cite upstream PR numbers.
   Follow `release.md`'s draft approval and get the owner's explicit approval; the text becomes the GitHub release body.
2. **Versions.** Set `X.Y.Z` in `.claude-plugin/marketplace.json`, `plugins/elis/.claude-plugin/plugin.json`,
   `plugins/elis/.codex-plugin/plugin.json` and `site/index.html`'s `softwareVersion`.
   When the APK ships, also bump `mobile/pubspec.yaml` to `X.Y.Z+N` with `N` one above the current build number.
3. **Push to master.** One commit with steps 1–2, then `git push origin HEAD:master`.
   `gh release create` has no `--target`, so the tag lands on `origin/master`, not local `HEAD`.
4. **Phone app (if shipped).** Build per `mobile/README.md` with JDK 21 (`JAVA_HOME`), and `CLAUDE.md`'s temporary
   `sdk:` workaround when the local Flutter is older. Run `./tool/build-vtshim.sh` first when
   `android/app/src/main/jniLibs/arm64-v8a/libvtshim.so` is missing.
   The APK is `mobile/build/app/outputs/flutter-apk/app-release.apk`; confirm with `ls -l` that its mtime is from
   this build, since a failed piped build leaves the old one.
5. **Publish.** `cd macos && ELIS_ALLOW_UNSIGNED=1 MOBILE_APK=<absolute APK path> scripts/release.sh X.Y.Z --publish`.
   Without `--publish` the same full build stops before upload; use that only to debug signing.
6. **Verify.**
   - `gh release view vX.Y.Z -R NaikSoftware/elis` lists `Elis-X.Y.Z.dmg`, both `elis-server-X.Y.Z-linux-*.tar.gz`
     and, if shipped, `elis-mobile.apk`; it is not a draft.
   - If `.github/workflows/homebrew-tap.yml` exists on master: `gh run list -R NaikSoftware/elis -w "Homebrew tap" -L 1`
     is green, and `Casks/elis.rb` in `NaikSoftware/homebrew-tap` shows `version "X.Y.Z"`.
     Retry with `gh workflow run homebrew-tap.yml -R NaikSoftware/elis -f tag=vX.Y.Z`.

## Common mistakes

| Mistake | Result |
|---|---|
| Manifests committed but not pushed | `--publish` stops: "not at X.Y.Z — push master first" |
| Publishing before the Homebrew workflow is on master | Cask stays on the old version; run the retry command after merging it |
| Missing `MOBILE_APK` | Release has no APK while README and the site link it; upload it with `gh release upload vX.Y.Z elis-mobile.apk --clobber` |
| Running `elisctl` or quitting the live app to "test" the release | Forbidden by `CLAUDE.md`; the owner restarts the app |
