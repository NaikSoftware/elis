# Phone Chat images as a real paste — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An image attached in phone Chat reaches Claude Code as `[Image #N]`, like a desktop Ctrl+V.

**Architecture:** `ChatComposer` splits the uploaded chips into images and other files.
The text line keeps `Attached: '<path>'` for the other files only.
A second paste holds only the images' quoted paths; Claude Code turns it into one `[Image #N]` per path.

**Tech Stack:** Flutter/Dart (`mobile/`), flutter_test.

**Spec:** `docs/superpowers/specs/2026-11-26-phone-attachments-image-paste-design.md`.

## Global Constraints

- Image extensions: `png`, `jpg`, `jpeg`, `gif`, `webp`, case-insensitive; one shared set, today's `_pictures` in `mobile/lib/chat/items.dart`.
- Image paste text: `'<p1>' '<p2>'`, single-quoted, one space between, nothing else.
- Images go as a separate paste only when the screen is Claude (`ClaudeScreen.agy == false`) and the trimmed text does not start with `/`, `!` or `#`.
  Otherwise every path stays in today's single line.
- Order: text line paste (skipped when empty), then the image paste, then Enter.
- Gates: `flutter analyze --no-pub` and `flutter test --no-pub` in `mobile/`, with the temporary SDK pin from `CLAUDE.md`, restored before commit.
  The four `session_*` goldens fail on macOS only by text antialiasing; leave them.

## Review Focus

- Images only, no text: one image paste, then Enter; the Enter's ready check must accept an input that shows only `[Image #N]`.
- A draft the user left on the computer: the existing draft check still runs first; images never paste onto someone else's draft.
- Typed path (`colours == false`, `session.type`): `PasteWrite` there is plain text, so the image paste must carry `ESC[200~ … ESC[201~` itself.
- Antigravity: unchanged line with every path.
- A resend after a failed send: chips keep their host path; the same split applies.

---

### Task 1: Split images from the text line and paste them separately

**Files:**
- Modify: `mobile/lib/chat/items.dart` (make the extension set public), `mobile/lib/chat/attachments.dart`, `mobile/lib/chat/chat_composer.dart` (`_send`, `_live`, `_typed`)
- Modify: `site/docs.html` (the "Attach files" paragraph), `docs/superpowers/specs/2026-11-24-phone-chat-attachments-design.md` ("Prompt": point to the new spec)
- Test: `mobile/test/chat_composer_test.dart`, `mobile/test/attachments_test.dart` if it exists, else the composer test

**Interfaces:**
- Produces: `const pictureExtensions` (renamed `_pictures`), `bool isPicture(String path)` and `String imagePaste(List<String> paths)` in `attachments.dart`.

- [ ] **Step 1: Write the failing tests** in `chat_composer_test.dart`'s attach group, using its `_C`, `_a` (`a.png`), `_b` (`b.txt`) helpers:
  - `sendPastesTextThenTheImagesAlone`: text `fix this`, chips a.png and b.txt.
    Expect writes: `PasteWrite("fix this Attached: '/h/u/S/b.txt'")`, `PasteWrite("'/h/u/S/a.png'")`, Enter.
    The script shows `[Image #1]` in the input after the second paste.
  - `imagesOnlyPasteOnceThenEnter`: no text, chip a.png. Expect `PasteWrite("'/h/u/S/a.png'")`, Enter.
  - `aCommandKeepsEveryPathInItsLine`: update `aCommandWithAChipIsOneWrite` to stay as is (`/review Attached: '/h/u/S/a.png'`).
  - `antigravityKeepsTheSingleLine`: an agy screen keeps `fix this Attached: '/h/u/S/a.png' '/h/u/S/b.txt'`.
  - `typedImagePasteIsBracketed`: `colours: false`; the image write is `TextWrite("\x1b[200~'/h/u/S/a.png'\x1b[201~")`.
  - Update `sendPastesTheTextAndTheHostPaths`, `withNoTextSendPastesOnlyThePaths` and the resend test to the new writes.
- [ ] **Step 2:** Run `flutter test --no-pub test/chat_composer_test.dart`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
  - `_send`: when images split (Global Constraints), `line = attachedLine(text, others)` and pass `images` to `_live`/`_typed`.
  - `_live(q, line, replace, images)`: skip the text write when `line` is empty; after it, one
    `GateStep(PasteWrite(imagePaste(images)), ready: bottomStack, done: '[Image #' count in draft == images.length)`.
    The Enter's ready accepts `pasteShown(s, shown)` with `shown` empty when only images were sent.
  - `_typed(q, line, images)`: same order; the image write is `TextWrite('\x1b[200~${imagePaste(images)}\x1b[201~')`.
- [ ] **Step 4:** Run `flutter test --no-pub test/chat_composer_test.dart`, then the whole suite and `flutter analyze --no-pub`. Expected: PASS except the four macOS-only goldens.
- [ ] **Step 5:** Update `site/docs.html`: images arrive as image attachments (`[Image #N]`) in a Claude session; other files, and every file for Antigravity or after `/`, `!`, `#`, are named in `Attached: '/path' …`.
- [ ] **Step 6:** Commit `feat(mobile): attached images reach Claude as a paste`.

### Task 1b: Composer UI B4 (after Task 1, same files)

**Files:** `mobile/lib/screens/composer.dart` (`prefix` slot), `mobile/lib/chat/chat_composer.dart` (tiles, one menu button,
ModeChip sheet gains Attach and the shells line), `mobile/test/chat_composer_test.dart`, `site/docs.html` "Attach files" paragraph.

- [ ] Tests first: `oneMenuButtonOpensAttachAndModes`, `attachRowPicksFiles`, `modeRowsKeepTheirGates`,
  `menuShowsShellsWhenAny`, `agyMenuHoldsAttachOnly`, `tilesShowThumbnailForImagesAndNameForFiles`,
  `uploadingTileShowsProgress`; update tests keyed on the old paperclip, ModeChip and chips.
- [ ] Implement per the spec's "Composer UI" section; reuse ModeChip's `_pick` sheet and the `actions.dart` `_item` style.
- [ ] Commit `feat(mobile): one composer menu for attach and mode, file tiles`.

### Task 2: Emulator end to end

- [ ] Rebuild the APK, install on `elis-agent-test`, send `stop.png` plus `note.txt` with text to the isolated claude session.
  Expected: the input showed `[Image #1]`, the Chat bubble shows the picture, Claude answers about both files.
- [ ] Send `stop.png` alone with no text. Expected: Claude receives one image.
