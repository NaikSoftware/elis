# Linux HTML Page Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Mac's HTML page overlay to the Linux app: `session overlay open --html|--url|--markdown|--image|--text`, `--browse`, `--js` with the page bridge, `--page`/`--companion` page rows and `browser.*`, with the Mac's wire contract, errors and read-back.

**Architecture:** A `QWebEngineView` page sits in the existing overlay slot (`linux/src/app/overlay.cpp`) beside the program overlay and HUD.
Every rule that ElisCore already owns (navigation policy, grant, identity, markdown document, bridge request shaping, outcomes, zoom ladder, link routing, browser profile) reaches C++ through new `elis_*` exports in `linux/bridge`, never a C++ rewrite.
Qt WebEngine is an optional build dependency: without it the build keeps today's refusals byte-for-byte.

**Tech Stack:** C++20, Qt 6 (Widgets, WebEngineWidgets, WebChannel), KF6, Swift 6 `ElisCore` through the `ElisBridge` C ABI, QtTest offscreen, `scripts/smoke.sh`.

**Contract:** `.claude/rules/control-api.md:939-1292`, `site/commands.html:2360-2760`, `site/docs.html:1625-1700` (bridge).
Mac reference code: `macos/Elis/Views/HtmlOverlayRegistry.swift`, `HtmlOverlayView.swift`, `HtmlPageSchemeHandler.swift`, `MarkdownPageSource.swift`, `ControlServer+SessionActions.swift:37-119`.
Mac design history: `macos/docs/plans/completed/20260925-html-overlay.md` and its five follow-ups.

Linear: NAI-36. Paths: repo-root relative. Run `linux/` commands from `linux/`.

## Decisions

- **Remote path: Linux pages are local only.** The owner approved this exception (AskUserQuestion, 2026-11-25): the Linux app has no remote sessions, so a Linux page cannot show on a Mac viewing the session or the reverse, and supporting it means porting remote sessions first.
  Keep the page model compatible with `PageServeFrame`/`RemotePageResources` (a page is a source plus a grant root, never a widget-held path), so the remote port adds a transport, not a redesign.
  `session.overlay.page.serve` and `session.overlay.job.run` stay refused with their current texts.
- **Phone:** Linux pages do not show on the phone (`site/docs.html:1154` stays true). Not in scope.
- **Optional WebEngine.** CMake option `ELIS_WEBENGINE` (default `AUTO`: on when `Qt6WebEngineWidgets` is found). Off: every refusal text in `control.cpp:267-269` and `commands.cpp:36-48` is unchanged and the existing tests pin it. On: those refusals are removed for the ported commands only.
- **Bridge transport.** ElisCore's `HtmlBridgeAdapter.script(handler:)`/`helperScript(handler:)` post to `window.webkit.messageHandlers[handler]`. Linux injects a tiny shim that defines that object over `QWebChannel`, so the shared scripts run unchanged. Rejected: forking the scripts per platform (they are shared with the phone WebView).
- **Content worlds.** Theme, renderer and bridge scripts run in `QWebEngineScript::ApplicationWorld`; page JS in `MainWorld`, enabled only with `--js` (`QWebEngineSettings::JavascriptEnabled` applies to the main world only).
- **Storage.** Each page gets an off-the-record `QWebEngineProfile`. `--persistent` uses one named profile whose storage name is the `BrowserProfile` id in `<stateDir>/browser-profile`.
- **Keys.** Linux translations of the Mac's: Ctrl+W closes the page even when the page swallows keydown; Ctrl+= / Ctrl+- / Ctrl+0 zoom; Ctrl+F focuses a text page's search; Ctrl+Alt+Shift+J (`toggle_overlay`) hides/shows. Confirm the exact chords against `linux/src/core/keymap.cpp` built-ins in Task 1.4.
- **One PR per phase.** Each phase leaves the app shippable.

## Global Constraints

- never execute `elis`/`elisctl` against the default socket, never launch or quit the app outside a throwaway `/tmp` `ELIS_STATE_DIR` (as `scripts/smoke.sh` does).
- Error and reply strings match `OverlayHtmlError` (`shared/ElisCore/.../ControlErrors.swift:48-140`) and `ControlDispatcher.overlayContent` (`ControlDispatcher+Overlay.swift:178-264`) exactly. Where the check lives in ElisCore, call it through the bridge instead of copying the string.
- Read-back field names and shapes match `ControlHtmlOverlayNode` (`ControlProjection.swift:542`). Fields that only mean something remotely (`remote`, `replica`, `phone`) are emitted as `false`.
- `ElisCore` stays host-free; no `public` symbol narrows (downstream `agterm-linux`). New bridge-facing helpers may be added as `public`.
- No page-specific events; slot changes emit `tree.changed` as on the Mac.
- A visual change is shown to the owner (screenshot of the offscreen-rendered widget or a run on their KDE box) before its UI test is written.
- Comments short: only non-obvious constraints. Commits `feat(linux): …`, ending with the `Claude-Session:` trailer.
- Gates (`cmake --build build`, `ctest --test-dir build`, `scripts/smoke.sh`, and `swift test` in `linux/bridge` plus `shared/ElisCore` when touched) run once per phase, in its last task. Earlier tasks run targeted tests only (`ctest -R <name>`, `test_ui -- <slot>`).

## Review Focus

- A build without WebEngine behaves exactly as today (Task 1.1 test).
- The policy decision for every navigation comes from `elis_html_navigation_decide`, never from C++ logic (Task 1.3).
- A clicked cross-origin link prompts, an unclicked one is cancelled or fails the page with `navigation blocked: URL` (Task 1.5).
- Ctrl+W closes a page that cancels every keydown (Task 1.4).
- `--browse` identity comes from the committed document, never the pending URL (Task 4.1).
- Markdown link reads are re-checked after symlink resolution (Task 2.2).
- A bridged request from a subframe is refused; refused commands list matches the Mac (Task 3.2).

---

## Phase 0 — Setup and spike

### Task 0.1: Isolated worktree
- [ ] `git fetch origin master`, create a native Claude worktree `linux-html-overlay` from it.
- [ ] Install `qt6-webengine-dev` (Debian/Ubuntu; KDE neon ships it) and confirm `find_package(Qt6 COMPONENTS WebEngineWidgets WebChannel)` resolves.

### Task 0.2: WebEngine offscreen spike (judgement)
**Files:** scratch only.
- [ ] A 40-line QtTest that loads `data:text/html,<h1>x</h1>` in a `QWebEngineView` under `QT_QPA_PLATFORM=offscreen`, waits for `loadFinished(true)` and reads `document.title` via `runJavaScript`.
- [ ] Record what CI and root need (`QTWEBENGINE_DISABLE_SANDBOX=1`, `--no-sandbox`, `QTWEBENGINE_CHROMIUM_FLAGS`) and put the answer in the test harness (`linux/tests/CMakeLists` env), not in prose.
- [ ] If offscreen rendering cannot load at all, stop and report to the owner with the failing output before Phase 1.

## Phase 1 — Foundation: `--html` and `--url` pages (PR 1)

| # | Task | Kind | Gate |
|---|---|---|---|
| 1.1 | CMake `ELIS_WEBENGINE` option; `ELIS_HAS_WEBENGINE` define; CI Linux job installs `qt6-webengine-dev` and builds both on and off | mechanical | `test_core` off-build keeps `overlayAndHudArgumentsFollowMaster` |
| 1.2 | Bridge exports (below) with Swift tests in `linux/bridge/Tests` | judgement | `swift test` in `linux/bridge` |
| 1.3 | `PageOverlay` widget + `PagePolicy` (`QWebEnginePage::acceptNavigationRequest` → bridge decide) | judgement | `test_ui` |
| 1.4 | Slot integration, strip, keys, focus | judgement | `test_ui` |
| 1.5 | Open-external confirm prompt | judgement | `test_ui` |
| 1.6 | Control commands, CLI args, read-back | judgement | `test_core`, `test_ui`, smoke |
| 1.7 | Docs for Phase 1, gates | mechanical | all gates |

### Task 1.1: Optional WebEngine build
**Files:** Modify `linux/CMakeLists.txt`, `.github/workflows/ci.yml` (Linux job), `linux/README.md:21`.
- [ ] Failing first: a `test_core` case `pageOverlaysRefuseWithoutWebEngine` compiled only when `!ELIS_HAS_WEBENGINE`, asserting the current `--html` refusal text.
- [ ] Add the option; link `Qt6::WebEngineWidgets Qt6::WebChannel` into `elis-ui` only when on.
- [ ] CI: matrix the Linux app build `webengine: [on, off]`.
- [ ] Commit `feat(linux): optional Qt WebEngine build`.

### Task 1.2: Bridge exports
**Files:** Create `linux/bridge/Sources/ElisBridge/Pages.swift`, `linux/bridge/Tests/ElisBridgeTests/PagesTests.swift`; modify `linux/bridge/include/elis_bridge.h`.
Each takes and returns UTF-8 JSON, freed with `elis_free`, like the existing exports.
- [ ] `elis_overlay_page_arguments(argsJSON)`: `ControlDispatcher.overlayContent`'s validation → `{"ok":true,"source":{kind,…},"flags":{…}}` or the Mac's refusal. If `overlayContent` is not callable without an `AppStore`, hoist its pure part into an ElisCore `public` function first (Mac keeps calling it; `ControlDispatcherOverlayTests` stay green).
- [ ] `elis_html_grant_error({file,cwd,home})` → `HtmlOverlay.grantError`.
- [ ] `elis_html_identity({source})` → `HtmlOverlay.identity`.
- [ ] `elis_html_navigation_decide({source,flags,action:{url,isMainFrame,clicked,…}})` → `allow|openExternal|cancel|fail` with the `navigation blocked` text.
- [ ] `elis_html_theme_script({themed, colors})` → `HtmlOverlayTheme.script`.
- [ ] `elis_html_zoom({current, step})` → `HtmlZoom.applying`.
- [ ] `elis_page_outcomes_*`: register/submit/dismiss/result over one process-wide `HtmlPageOutcomes` (last 32 kept), guarded by a lock.
- [ ] Tests: one per export for the happy path and one refusal each, comparing against the ElisCore function directly.
- [ ] Commit `feat(linux): bridge page policy, grant and outcomes`.

### Task 1.3: `PageOverlay` widget and policy
**Files:** Create `linux/src/app/pageoverlay.{h,cpp}`; modify `linux/CMakeLists.txt`.
- [ ] Failing first (`test_ui`): `aFilePageWithoutCwdLoadsItsTextAndCannotNavigate`, `aUrlPageStaysOnItsOrigin`, `anUnclickedCrossOriginRedirectFailsThePage` (serve two origins from a `QTcpServer` on 127.0.0.1 with different ports).
- [ ] `PageOverlay : QWidget` owns a `QWebEngineView`, a `PolicyPage : QWebEnginePage` and its `QWebEngineProfile`.
- [ ] Load paths mirror `HtmlOverlayRegistry.loadOriginal` (`:512-558`): file without `--cwd` → `setHtml(text)` with no base URL; with `--cwd` → `load(file URL)` and a URL request interceptor that refuses `file:` outside the grant; URL → `load(url)`.
- [ ] `acceptNavigationRequest` builds the action (`NavigationTypeLinkClicked` → clicked) and asks `elis_html_navigation_decide`.
- [ ] Refuse: `JavaScriptDialog*`, `createWindow` (popups), `fileDialogRequested`/`chooseFiles`, `featurePermissionRequested` (camera, mic, geolocation), drops and pastes carrying files.
- [ ] Track `state` (loading|loaded|failed), `error`, `page` (committed URL), `title`, `canGoBack/Forward` from `loadStarted/loadFinished/urlChanged/titleChanged`. A failed load shows the error panel with Reload.
- [ ] Commit `feat(linux): page overlay widget with ElisCore navigation policy`.

### Task 1.4: Slot integration, strip, keys, focus
**Files:** Modify `linux/src/app/overlay.cpp`, `mainwindow.{h,cpp}`.
- [ ] Show the owner the rendered strip and a floating page before writing the UI tests.
- [ ] `Overlay` gains a `PageOverlay *page` (one of `part`/`page`), keeping `slotKey`, `layoutOverlays`, `coverPart`, `hasHideableOverlay` as the single slot code path. Floating pages add the 29 px strip height (`HtmlOverlay.chromeHeight`) to the content height; point axes capped at 80%.
- [ ] Strip: identity, dimmed title (plain text, untrusted), close; hide button when the title-bar hide control is enabled; with `--navigation` Back/Forward/Reload/Open in Browser and Show in Folder (file, via `QDesktopServices` on the folder) or Copy Link (URL). `--chromeless` drops the strip.
- [ ] Keys: a `QShortcut` with `Qt::WidgetWithChildrenShortcut` on the page for close and zoom, so a page's `preventDefault` cannot swallow them; zoom is app-wide, persisted in settings as `htmlOverlayZoom`.
- [ ] Focus: a background open does not take focus; a click on a pane page moves split focus to that pane.
- [ ] Tests: `controlWClosesAPageThatCancelsEveryKeydown`, `aPanePageDrawsOverASessionPage`, `hidingAPageKeepsItLoaded`, `zoomStepsFollowTheLadderAndPersist`.
- [ ] Commit `feat(linux): pages in the overlay slot`.

### Task 1.5: Open-external prompt
- [ ] Nonblocking confirm over the page naming the URL, Cancel default, one per page. Cancel silences the page's prompts until the next user click/key in it. Hide, close or detach ends the prompt. OK → `QDesktopServices::openUrl`.
- [ ] Tests: `aClickedCrossOriginLinkAsksOnce`, `cancelSilencesUntilTheNextUserInput`.
- [ ] Commit `feat(linux): confirm before a page link leaves its bounds`.

### Task 1.6: Control commands, CLI, read-back
**Files:** Modify `linux/src/core/control.cpp`, `commands.cpp`, `linux/src/app/overlay.cpp`, `linux/src/ctl/elisctl.cpp`, `linux/tests/test_core.cpp`, `test_ui.cpp`, `scripts/smoke.sh`.
- [ ] Failing first: flip `overlayAndHudArgumentsFollowMaster`'s html expectation (WebEngine build) to the Mac's flag-rule errors (`--browse requires --url`, `--chromeless with --url requires a loopback host…`, …) via `elis_overlay_page_arguments`.
- [ ] `session.overlay.open` page sources (`html`, `cwd`, `url`, `navigation`, `chromeless`, `color`, sizes, `pane`, `follow`); reply `{id, pageID}` with a `pending` outcome registered.
- [ ] Port from `unsupportedReason` (WebEngine build only): `session.overlay.reload` (`current`), `.navigate` (`to`: back|forward|browser|finder), `.submit` (`value`). Extend `close`, `hide|show|toggle`, `resize`, `result --page ID` (`pageOutcome`) to pages, with the Mac's errors (`no overlay`, `the overlay is not an html page`, `no page to go back to`, `show in Finder requires a file page`, `no such page`, `no overlay result: the slot holds an html page`).
- [ ] `elisctl`: add `--browse --navigation --js --chromeless --persistent --current --block` to the flags list (`elisctl.cpp:591-593`) so they stop swallowing the next token; `--block` on a page polls `result --page` and exits 0 submitted / 2 dismissed / 1 error.
- [ ] Read-back: `sessionExtras` adds `htmlOverlays[]` with `ControlHtmlOverlayNode`'s fields; `overlay`, `paneOverlays`, `hiddenOverlays`, `surfaces[]` count pages like programs.
- [ ] smoke.sh: open a `--html` page with `--cwd`, read `htmlOverlays[0].state == loaded`, reload, hide/show, submit with `--block`; drop the ported commands from the unsupported loop.
- [ ] Commit `feat(linux): page overlay control commands`.

### Task 1.7: Docs and gates
- [ ] `linux/README.md` (`:11-12`, `:89-92`, `:162-163`), `elisctl.cpp` usage (`:118-128`, `:152-153`), `plugins/elis/skills/elis/linux.md:55-59`, `site/docs.html:1191`, `site/commands.html:313` and per-command Linux notes: state what Linux pages do once, the remaining gaps once.
- [ ] Run all gates once; record CI flakes in `docs/ci-flakes.md` if any.
- [ ] Commit `docs(linux): page overlays`.

## Phase 2 — Markdown, image, text and document pages (PR 2)

| # | Task | Kind | Gate |
|---|---|---|---|
| 2.1 | Install `macos/Elis/Resources/markdown/` (markdown-it, highlight.js, `render.js`, `page.css`) to `share/elis/markdown`; bridge `elis_markdown_page` (`MarkdownPage.html`), `elis_markdown_linked_document`, `elis_image_page`, `elis_text_page`, `elis_document_page` | judgement | `swift test` bridge |
| 2.2 | `elis-page://<pageID>/<path>` via `QWebEngineUrlSchemeHandler` (registered before `QApplication`), serving only what `linkedDocument` returns after symlink resolution | judgement | `test_ui`: `aMarkdownLinkOutsideTheRootIsNotServed`, `aSymlinkOutOfTheRootIsRefused` |
| 2.3 | `--markdown` (`--navigation` for relative links), `--image`, `--text` (`line`, `tail`, `followFile`); theme script on theme change reloads file pages | judgement | `test_ui`, smoke |
| 2.4 | Text-page commands from `unsupportedReason`: `search`, `follow`, `wrap`, `changes`, `files`; Ctrl+F focuses the search field; read-back `text{…}` | judgement | `test_core`, `test_ui` |
| 2.5 | Document page (a clicked `.html` file): network blocked by interceptor plus CSP, browser hand-off refused | judgement | `test_ui` |
| 2.6 | Docs, gates | mechanical | all |

Limits from ElisCore: 4 MB markdown, 32 MB images, 256 images, `html: false`.

## Phase 3 — `--js` and the page bridge (PR 3)

| # | Task | Kind | Gate |
|---|---|---|---|
| 3.1 | Bridge exports `elis_html_bridge_scripts({handler})` (adapter + helper) and `elis_html_bridge_request({message, page})` → `HtmlBridge.request` | judgement | `swift test` bridge |
| 3.2 | `QWebChannel` shim defining `window.webkit.messageHandlers[handler].postMessage` in `ApplicationWorld`; requests from subframes refused; the shaped request goes through `WindowLibrary::dispatch` as if from `elisctl`; refused commands (`zmx.present`, `catalog.subscribe`, `overlay.job.run`, `overlay.page.serve`, `zmx.reset`, `companion.page.attach`, `session.attach`, `phone.*`) match the Mac | judgement | `test_ui`: `dataElisAttributesWorkWithJsOff`, `elisRequestResolvesWithJs`, `aFrameCannotUseTheBridge` |
| 3.3 | `--js` toggles main-world JS; `window.close()` → outcome `dismissed`; a bridged `overlay.reload` defaults to `--current` | judgement | `test_ui`, smoke (`--block` exit 2) |
| 3.4 | Docs, gates | mechanical | all |

## Phase 4 — `--browse`, `--persistent`, `browser.*` (PR 4)

| # | Task | Kind | Gate |
|---|---|---|---|
| 4.1 | `--browse`: main frame to any http(s) origin; identity, `page`, Open in Browser and Copy Link from the committed URL (`urlChanged` after commit, never `acceptNavigationRequest`'s URL) | judgement | `test_ui`: `browseIdentityFollowsTheCommittedDocument` |
| 4.2 | `--persistent` named profile from `BrowserProfile` (bridge `elis_browser_profile`); persistent store failure refuses the open as `persistentStoreFailure` does | judgement | `test_ui` |
| 4.3 | `browser.clear` (refused with `N persistent page(s) still open`), `browser.links` + Settings ▸ "Open links in" (`overlay|overlay95|overlay75|overlay50`); remove `browser` from `unsupportedReason`; top-level `linkOpenMode` | judgement | `test_core`, smoke |
| 4.4 | Docs, gates | mechanical | all |

## Phase 5 — Page rows and terminal link clicks (PR 5)

| # | Task | Kind | Gate |
|---|---|---|---|
| 5.1 | `session.page` / `session.companion.page`: a sidebar row whose content is a page (`content: "page"`), same `PageOverlay` hosted full-size in the row's stack | judgement | `test_ui`, smoke |
| 5.2 | Persist page rows as the Mac's `PageSnapshot` JSON (file or url plus flags); an unreadable descriptor restores as unreadable; bridge `elis_page_snapshot_*` if decoding lives in ElisCore | judgement | `test_core` round-trip with a Mac-written snapshot |
| 5.3 | Konsole link clicks routed by `LinkPolicy` (bridge `elis_link_route`): with `browser.links` set to an overlay mode, a URL opens `--url --browse --js --navigation --persistent` at that size; `.md`, images, text and `.html` files open as their page kinds | judgement | `test_ui` (hook Konsole's `urlFilter` activation; if the KPart exposes no seam, report to the owner before working around it) |
| 5.4 | Final docs sweep (README "Not ported yet" now lists only remote sessions and what remains), skill `linux.md`, `site/` Linux notes; full gates | mechanical | all |

## Self-review

- Every Mac command in the contract is either ported in a phase above or listed as refused with its reason (`page.serve`, `job.run`: remote; phone pages).
- Every new state is read back on the session node or tree top level (`htmlOverlays[]`, `linkOpenMode`, page rows' `content`).
- No visual artifact outlives its page: the prompt, strip and error panel all die with the `PageOverlay`; `forgetOverlays` covers pages.
- No string or rule is duplicated in C++ that ElisCore already owns.
