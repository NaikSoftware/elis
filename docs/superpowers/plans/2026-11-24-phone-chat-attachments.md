# Phone Chat attachments — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the phone's Chat composer the user attaches files. They upload to the session's host, and the sent prompt names their host paths.

**Architecture:**
- A new mux channel type `upload` carries the bytes from the phone to the relay under credit.
- The relay asks the app for a destination with a new non-streaming `session.upload` command. For a local row it writes the file itself. For a remote row it pipes the bytes into `ssh … elisctl session upload` on the origin host.
- The phone uploads its chips one at a time, then sends `<text> Attached: '<p1>' …` through the existing write gate.

**Tech Stack:** Swift 6 (`shared/ElisCore`, `server/`, `linux/bridge`), C++ Qt6 (`linux/`), Flutter/Dart (`mobile/`), swift-testing, QTest, flutter_test.

**Spec:** `docs/superpowers/specs/2026-11-24-phone-chat-attachments-design.md`. Read "Owner decisions", "Design" and "Refusals". **Tracking:** Linear NAI-24.

## Global Constraints

- **Limits.** `UploadLimits.maxBytes = 20_971_520`, `UploadLimits.maxFiles = 10`, upload window `16384` bytes. Swift and Dart use the same values. A window mismatch closes the channel with `input overflow`.
- **Copy.** Use the spec's "Refusals" texts byte for byte.
- **Prompt.** `<trimmed text> Attached: '<p1>' '<p2>'`, all on one line. With no text it is `Attached: '<p1>'`.
- **Names.** `UploadStorage.safeName` turns every character outside `[A-Za-z0-9._-]` into `_`, and a leading `-` or `.` into `_`. It truncates to 100 characters, and an empty result becomes `file`. `fileName` prefixes a UTC stamp `yyyyMMdd-HHmmss-`. The relay sends `safeName` output to every host.
- **Retention.** `UploadStorage.sweep` runs once at each host's launch, after the host's sessions and Recent Closed are loaded. It runs nowhere else.
- **Control API contract** (`.claude/rules/control-api.md`). `session.upload` ships with its protocol case, dispatcher, `elisctl`, tests and every docs surface in the same change. It sets no model state, so it has no read-back. Record that exemption in `control-api.md`, next to the command's contract.
- **Musl.** elis-server ships the musl `elisctl`.
  - `UploadStorage.swift` and `elisctlKit/Session+Upload.swift` must compile without `#if !canImport(Musl)`.
  - `PhoneLinkUpload.swift` and its tests are wrapped in it, like every other `PhoneLink*.swift` file.
- **Scope.** Chat view only. The Term composer passes no `leading` widget.
- **Gates.**
  - ElisCore `swift test`: only the known zsh/tcsh/csh failures.
  - `server/` `swift test`.
  - Linux: CMake, then `ctest --test-dir build`.
  - Mobile: `flutter analyze --no-pub` and `flutter test --no-pub`, following the SDK note in `CLAUDE.md`.
  - `make lint`: zero findings.
  - Don't wait for the macOS GitHub CI.
- **Live terminal.** Never run `elis`/`elisctl` against the default socket. Emulator runs follow the `mobile-emulator-testing` memory.

## Review Focus

- **The picker backgrounds the app.** With Watch off, `ElisModel.pause()` closes the link. Chips must survive the pick, and the upload starts only at Send, once `m.mux != null` (Task 8, Step 5).
- **A link lost mid-upload.** The relay leaves no `.part` file and no placeholder. The phone keeps the text and every chip. Chips that already uploaded keep their host path, so a re-send uploads only the rest (Tasks 6 and 8).
- **A chip removed while it uploads.** `done` completes with `cancelled`, the relay leaves no file, the send stops silently, and the text stays (Tasks 7 and 8).
- **An older relay or host.** The phone shows an `Update Elis on …` text, and the attach button for that session stays disabled until the next reconnect. An ssh failure or an offline host is a transient `<host> gave no answer`, never "too old" (Tasks 6 and 8).
- **A file that changes after the pick.** An empty file completes at once. A stream shorter or longer than `size` fails with `file changed while sending` and leaves no file on the host (Tasks 6 and 7).

---

### Task 1: Wire messages and vectors

**Files:**
- Modify: `shared/ElisCore/Sources/ElisCore/PhoneLink/PhoneLinkMessages.swift`, `shared/fixtures/phone-link-vectors.json`
- Test: `shared/ElisCore/Tests/ElisCoreTests/PhoneLinkMessagesTests.swift`, `mobile/test/link_test.dart`

**Interfaces:**
- Produces:
  - `PhoneLinkOpen` gains `name: String?` and `size: Int?`, nil-defaulted in the public init because agterm-linux calls it.
  - `PhoneLinkClose` gains `path: String?`.

- [ ] **Step 1:** Add two vectors:
  - `open upload`: `{"name":"a_b.png","size":5,"target":"S","type":"upload"}`
  - `close uploaded`: `{"path":"/s/uploads/S/x.png","reason":"uploaded"}`

  Also rename the stale `open page` vector to `open present`, set its type to `present`, and regenerate its `hex` (payload length `0x20`).
- [ ] **Step 2:** Extend the Swift vector test. Run `swift test --filter PhoneLinkMessages` in `shared/ElisCore`. Expected: FAIL.
- [ ] **Step 3:** Add the fields, keeping sorted keys and unescaped slashes.
- [ ] **Step 4:** Run the Swift test, then `flutter test --no-pub test/link_test.dart` in `mobile/`. Expected: PASS. Commit `feat(phone-link): upload open and close fields`.

### Task 2: `session.upload` in ElisCore and the Mac app

**Files:**
- Create:
  - `shared/ElisCore/Sources/ElisCore/UploadStorage.swift`
  - `shared/ElisCore/Sources/ElisCore/ControlDispatcher+Upload.swift`
  - `macos/Elis/Control/ControlServer+Upload.swift`
- Modify:
  - In `shared/ElisCore/Sources/ElisCore/`: `ControlProtocol.swift`, `ControlDispatcher.swift`, `ControlActions.swift`, `ControlActionsDefaults.swift`, `PageSessionRefusal.swift`, and `HtmlBridge.swift` (its `refused` set).
  - `macos/Elis/Control/ControlServer.swift`: add `.sessionUpload` to the exhaustive fallback switch near `.sessionTranscript`, and add a `stateDirectory: URL` that `elisApp.init` passes in.
  - `macos/Elis/elisApp.swift`, for the launch sweep.
- Test: `shared/ElisCore/Tests/ElisCoreTests/UploadStorageTests.swift`, `shared/ElisCore/Tests/ElisCoreTests/ControlDispatcherUploadTests.swift`

**Interfaces:**
- Produces:
  - `Command.sessionUpload = "session.upload"`.
  - `ControlArgs.size: Int?`.
  - `public struct ControlUpload: Codable, Sendable, Equatable { path: String?; host: String?; session: String? }`, returned as `ControlResult.upload: ControlUpload?`.
  - `public enum UploadLimits { static let maxBytes = 20_971_520; static let maxFiles = 10 }`.
  - `public enum UploadStorage`:
    - `static func safeName(_ raw: String) -> String`
    - `static func fileName(_ raw: String, now: Date) -> String`
    - `static func reserve(stateDir: URL, sessionID: String, name: String, now: Date) throws -> URL` creates the folder, then claims the final path as an empty placeholder with `O_CREAT|O_EXCL`. On `EEXIST` it retries with `-2`, `-3` … before the extension.
    - `static func sweep(stateDir: URL, keep: Set<String>?, now: Date, maxAge: TimeInterval = 7 * 86_400)`. When `keep == nil` it only prunes by age.
  - `public final class UploadSink`:
    - `init(path: URL) throws` opens `<path>.part` with `O_CREAT|O_EXCL`.
    - `write(_: Data) throws`
    - `finish() throws -> URL` renames the `.part` over the placeholder.
    - `abandon()` removes the `.part` and the placeholder.
  - `ControlDispatcher.uploadArguments(_ args: ControlArgs?) -> Result<(name: String, size: Int), ControlResponse>`. It is public because `linux/bridge` calls it. It refuses:
    - a missing name with `upload needs a name`;
    - a missing or negative size with `upload needs a size`;
    - a size over the cap with the spec's cap text.
  - `ControlActions.uploadDestination(_ target: String?, window: String?, name: String, size: Int) -> ControlResponse`. Its default refuses with `the Elis on this host is too old for session.upload`.
  - `UploadStorage.answer(for session: Session, stateDir: URL, name: String, now: Date) -> ControlResponse` is the host-free row logic:
    - a page row gets the page refusal;
    - a row with `remoteHost` gets `ControlUpload(host:, session: remoteSessionID)`;
    - any other row gets `ControlUpload(path:)` from `reserve`.
  - `ControlServer+Upload.swift` resolves the row with `resolver.resolveSessionTarget(target, window:)`, then calls `answer`.

- [ ] **Step 1: Write the failing tests.**
  - `fileName("-my photo'1.png", now: 2026-11-24T10:30:00Z) == "20261124-103000-_my_photo_1.png"`.
  - A second `reserve` while the first placeholder exists returns `…-2.png`.
  - `finish` leaves only the final file. `abandon` leaves nothing.
  - `sweep` removes a folder not in `keep` and an 8-day-old file in a kept folder. It keeps a 1-day-old file. With `keep: nil` it removes no folder.
  - `uploadArguments` refuses size `20_971_521`, size `-1`, and a missing name, each with its text.
  - `answer` gives the right `ControlUpload` or refusal for a local row, an attached row and a page row.
- [ ] **Step 2:** Run `swift test --filter Upload` in `shared/ElisCore`. Expected: FAIL. Implement until it passes.
- [ ] **Step 3: Launch sweep.** `elisApp.init` builds `keep` from:
  - the session ids of `library.paneClaims()`;
  - every session id `restoresSession` covers in `recentClosedItems`: the snapshot, its companions, and the members of a workspace entry. This is not `RecentClosedItem.id`.

  When `paneClaims().complete` is false, it passes `nil`. Test that the keep set holds a Recent Closed session whose entry id differs from its session id.
- [ ] **Step 4:** Run `make build` and the tests. Expected: PASS. Commit `feat(control): session.upload reserves a host path`.

### Task 3: `elisctl session upload` and the remote argv

**Files:**
- Create: `shared/ElisCore/Sources/elisctlKit/Session+Upload.swift`. Not Musl-gated.
- Modify: `shared/ElisCore/Sources/elisctlKit/SessionCommands.swift` (add `Upload.self` to `subcommands`), `shared/ElisCore/Sources/ElisCore/RemoteSession.swift`
- Test: `shared/ElisCore/Tests/elisctlKitTests/SessionUploadCommandTests.swift`, `shared/ElisCore/Tests/ElisCoreTests/RemoteSessionTests.swift`

**Interfaces:**
- Consumes: `session.upload`, `UploadSink`.
- Produces:
  - `elisctl session upload --target <t> --name <n> --size <bytes>`. It reads exactly `size` bytes from stdin, in chunks of at most 64 KiB. Its stdout is always exactly one `ControlResponse` JSON line. The error texts are:
    - a short stdin: `upload ended after <k> of <n> bytes`, after abandoning the sink;
    - extra stdin: `file changed while sending`;
    - a remote answer: `cannot upload to a remote row from here`.
  - `RemoteSession.uploadCommand(host: String, session: String, name: String, size: Int, connectTimeout: Int = 5, controlPath: String? = nil) throws -> [String]`. Build it like `controlCommand`: an `accountShellQuoted` outer layer, then `exec elisctl session upload --target=<s> --name=<n> --size=<k>`, with `validate(host:)` and `isPlain` on the session.

- [ ] **Step 1: Write the failing tests.**
  - With a stub socket answering `upload.path`, five stdin bytes land at the path, and stdout is one ok line.
  - 3 of 5 bytes, 6 of 5 bytes, and a remote answer each print their error and leave no file.
  - `uploadCommand` refuses host `-oProxyCommand=x`.
  - With a name `a'b\c`, the outer layer decodes under fish the way the existing `controlCommand` tests check.
- [ ] **Step 2:** Implement until the tests pass. Commit `feat(elisctl): session upload`.

### Task 4: elis-server

**Files:**
- Modify:
  - `server/Sources/ElisServerKit/ServerCommandPolicy.swift`: add `.sessionUpload` to `served`.
  - `ServerActions.swift`: add `var uploadDirectory: URL?`. `ElisServer.start` sets it, the same way it sets `recentClosed`.
  - `ServerActions+Sessions.swift`
  - `ElisServer.swift`
- Test: `server/Tests/ElisServerTests/ServerActionsSessionsTests.swift`, `ServerCommandPolicyTests`

- [ ] **Step 1:** Write the failing tests:
  - `session.upload` on a server session answers a path under the configured state dir;
  - the policy classifies the command as served;
  - the sweep keeps a Recent Closed session's folder and removes an unknown one.
- [ ] **Step 2:** Implement `uploadDestination` next to `transcriptSource`, starting with `windowRefusal(window)` and `resolveSession`. Call the sweep in `ElisServer.start` after `pendingCloses.recover` and `seedWorkspace`. Its `keep` is the store's sessions plus the expanded session ids from `recentClosed.load()`.
- [ ] **Step 3:** Run `swift test` in `server/`. Expected: PASS. Commit `feat(server): session.upload`.

### Task 5: Linux Qt app

**Files:**
- Modify:
  - `linux/src/core/store.cpp`: `reopenClosed` reuses the closed entry's id, and `addSession` gains an optional id.
  - `linux/bridge/Sources/ElisBridge/Bridge.swift` and its header in `linux/bridge/include`.
  - `linux/src/core/commands.cpp`: a `sessionUpload` handler after `sessionTranscript`.
  - The Qt start-up path, for the sweep.
  - `linux/src/ctl/elisctl.cpp`: `session upload` joins both the exec-to-helper condition (:562) and the `--socket` append (:580).
- Test: `linux/tests/test_core.cpp`

**Interfaces:**
- Produces:
  - `char *elis_upload_reserve(const char *stateDir, const char *sessionID, const char *argsJSON)`. It runs `uploadArguments`, then `reserve`, and returns `ControlResponse` JSON that the caller frees.
  - `void elis_upload_sweep(const char *stateDir, const char *keepJSON)`.
- Linux has no remote rows.

- [ ] **Step 1:** Write the failing QTests:
  - a Recent Closed reopen keeps the session id;
  - `session.upload` with name `a b.txt` and size 3 answers a path under `stateDir()/uploads/<id>/`;
  - size `20971521` gets the cap text.
- [ ] **Step 2:** Implement. The sweep's `keep` is the store's sessions plus its closed list.
- [ ] **Step 3:** Run the CMake build and `ctest --test-dir build`. Expected: PASS. Commit `feat(linux): session.upload`.

### Task 6: Relay upload channel

**Files:**
- Create: `shared/ElisCore/Sources/elisctlKit/PhoneLinkUpload.swift`
- Modify: `shared/ElisCore/Sources/elisctlKit/PhoneLinkSession.swift`
- Test: `shared/ElisCore/Tests/elisctlKitTests/PhoneLinkUploadTests.swift`; `mobile/test/wire_names_test.dart` (add `upload` under `PhoneLinkSession.swift` and `uploaded` under `PhoneLinkUpload.swift`)

**Interfaces:**
- Consumes:
  - `session.upload`, sent with `SocketClient(path:).sendRaw(_, timeout: PhoneLinkTerminal.attachTimeout)` the way `requestAttach` sends it.
  - `UploadSink`, `UploadStorage.safeName`, `RemoteSession.uploadCommand`.
- Produces: `PhoneLinkUpload.window = 16384`, and the following behaviour.
  1. **OPEN `upload`.** The relay refuses, in this order:
     - a missing name, a missing size, or a negative size: `malformed open`;
     - a size over the cap: the cap text;
     - any existing entry in `uploads`: `an upload is already running`.

     Otherwise it inserts into `uploads[channel]` before it asks the app. The answer handler is a no-op once `stop()` has run.
  2. **The app's answer.** The update text `Update Elis on the computer to attach files` replaces any of these:
     - an answer for which `refusesUnknown(.sessionUpload)` holds;
     - a text containing `too old for session.upload`;
     - Linux's `unknown command 'session.upload'`.

     Any other error goes out verbatim in OPENED `{error}`.
  3. **Opening the destination.**
     - A path answer opens an `UploadSink`.
     - A host answer starts a `Process` on `uploadCommand` with stdin, stdout and stderr pipes. It uses `runWithSignals()`, and sets `F_SETNOSIGPIPE` (Darwin) or `SIG_IGN` (Linux) for the stdin fd. Writes are raw `write(2)`, and `EPIPE` counts as an early exit.

     Then it sends OPENED `{}`. A `size` of 0 completes at once.
  4. **DATA.** Writes run on a private serial `writes` queue. Each completed write sends coalesced CREDIT through `sendDirect`. DATA beyond the window or past `size` closes the channel with `input overflow` and abandons the upload.
  5. **Completion.** `written()` drives it, once the written total equals `size`. Then `finish()` runs on `writes`, or the relay closes stdin and reads the one reply line. CLOSE `{reason:"uploaded", path}` goes out only after that succeeds.
  6. **Remote failures.** The relay watches the process for its whole life. An exit before completion closes the channel with an error taken from the reply line:
     - `refusedArguments` (status 64, empty stdout), or `refusesUnknown(.sessionUpload)`: `Update Elis on <host> to attach files`;
     - any other output that is not JSON: `<host> gave no answer (<stderr>)`.
  7. **Teardown.** A phone CLOSE, `close(reason:)`, or any failure abandons the sink or terminates the process.

  `uploads` joins the duplicate check and the DATA, CLOSE, `close(reason:)` and `closeChannel` paths. It gets no `scheduler.open`.

- [ ] **Step 1: Write the failing tests.** Use the `MobileTestSupport` fakes, a stub app socket and an injected process launcher.
  - Five bytes yield CLOSE `uploaded`, and the file is on disk.
  - Size 0 yields CLOSE `uploaded` with no DATA.
  - Over the cap, a second OPEN, and a negative size are each refused.
  - A phone CLOSE during a delayed stub answer leaves no `.part` and no process.
  - A phone CLOSE after 2 of 5 bytes, or a link close mid-stream, leaves nothing.
  - 16385 unacknowledged bytes, or 6 bytes for size 5, give `input overflow`.
  - A stale-app answer maps to the update text.
  - A remote row runs the expected argv, and its stub reply maps to `uploaded`.
  - Exit 64 with empty stdout gives `Update Elis on h to attach files`. Exit 255 gives `h gave no answer (…)`.
  - A process that exits before reading stdin leaves the relay alive, and the channel closes with its error.
- [ ] **Step 2:** Implement, taking the window, the `writes` queue and CREDIT from `PhoneLinkForward` as the model. Run `swift test --filter PhoneLinkUpload` and the wire-names test. Expected: PASS. Commit `feat(relay): upload channel`.

### Task 7: Phone mux upload

**Files:**
- Modify: `mobile/lib/link/mux.dart`
- Test: `mobile/test/mux_test.dart`, `mobile/test/wire_names_test.dart` (keys `name`, `size`, `path`)

**Interfaces:**
- Produces:
  - `const _uploadWindow = 16384;`
  - `UploadChannel Mux.upload(String target, {required String name, required int size})`.
  - `class UploadFailed implements Exception { final String reason; bool get tooOld; }`. `tooOld` is true for `unsupported channel type` and for any reason that starts with `Update Elis on`.
  - `class UploadChannel`:
    - `Stream<int> get progress`: the credited bytes.
    - `Future<String> get done`: completes with the host path or throws `UploadFailed`.
    - `Future<void> send(Stream<List<int>> bytes)`: starts after OPENED, splits the bytes into frames of at most `linkMaxPayload`, and waits while `_Outbox` refuses. If the streamed count differs from `size`, it cancels and throws `file changed while sending`.
    - `void cancel()`: sends CLOSE, completes `done` with `UploadFailed('cancelled')`, and closes `progress`.
- OPENED `unsupported channel type` is reported as `Update Elis on the computer to attach files`. A lost link throws `UploadFailed('Disconnected')`.

- [ ] **Step 1: Write the failing tests** with `FakeRelay`/`upgraded()`:
  - the OPEN payload equals the `open upload` vector;
  - no DATA goes out before OPENED;
  - at most 16384 bytes are ever unacknowledged;
  - CLOSE `uploaded` completes `done`;
  - OPENED `{error}` throws;
  - a lost link, `cancel()`, a short stream and a long stream each give their reason.
- [ ] **Step 2:** Implement, taking `ForwardChannel`/`_Outbox` as the model. Run `flutter test --no-pub test/mux_test.dart test/wire_names_test.dart`. Expected: PASS. Commit `feat(mobile): mux upload channel`.

### Task 8: Chat composer attachments

**Files:**
- Create: `mobile/lib/chat/attachments.dart`
- Modify:
  - `mobile/lib/screens/composer.dart`: `final Widget? leading;`, placed before the TextField.
  - `mobile/lib/chat/chat_composer.dart`
  - `mobile/lib/chat/chat_view.dart`
  - `mobile/lib/screens/session.dart`
  - `mobile/pubspec.yaml`: `file_picker: ^13.3.2`.
  - `mobile/README.md`
- Test:
  - `mobile/test/chat_composer_test.dart`
  - `mobile/test/chat_screen_test.dart`
  - `mobile/test/session_term_test.dart`: export `pauseResume` and `Relay`.

**Interfaces:**
- Consumes: `Mux.upload`, `UploadChannel`, `UploadFailed`.
- Produces:
  - `class PickedFile { final String name, path; final int size; }`.
  - `typedef PickFiles = Future<List<PickedFile>> Function();`. The default `pickFiles` calls `FilePicker.pickFiles(type: FileType.any)`. It refuses a result whose `path` is null with `cannot read <name>`, and takes the size from `await length()` when it is missing.
  - `typedef UploadFile = UploadChannel Function(PickedFile f);`.
  - `String attachedLine(String text, List<String> paths)`.
  - `class AttachBlocks { static final Set<String> tooOld; }`. It is keyed by session id and cleared whenever `m.mux` changes, mirroring `ModePicks.tooOld`.
  - `ChatComposer` gains `PickFiles? pick`, `UploadFile? upload` (null disables the button) and `String? attachBlocked` (disables the button and becomes its tooltip).
  - `SessionScreen` gains a `@visibleForTesting PickFiles? pick`, passed through `ChatView`.
- Composer behaviour:
  - **Attach button.** An `IconButton(Icons.attach_file)` in `Composer.leading`. It is disabled while held, while the gate runs, while an upload runs, when `upload == null`, or when `attachBlocked != null`.
  - **Chips.** `InputChip`s in the `accessory` Column, each showing the name, the size (for example `1.2 MB`) and ×. An uploading chip shows a `LinearProgressIndicator` driven by `progress`.
  - **Pick limits.** A file over the cap is not added, and the cap text is shown. Picks past the 10th are dropped, with `at most 10 files per message`.
  - **Who sends chips.** Only the field's Send and the offer's Replace go through `sendField(String text, {bool replace = false})`. `send('/model')` and every other caller leave the chips alone.
  - **`sendField` steps:**
    1. Check `_blocked`.
    2. Set `_uploading`. Send, attach and the field are disabled, and `reason` shows `Uploading i/n`.
    3. Upload each chip that has no `hostPath`, one at a time. Check `mounted` after each.
    4. Check `_blocked` again.
    5. Call `gate.run` with `attachedLine`.
    6. On success, clear the field and the chips. Call `FilePicker.clearTemporaryFiles()` only when no chips remain, because it clears every copy.
    7. On failure, keep the text and the chips and `_tell` the reason. `cancelled` is silent. A `tooOld` failure adds the session to `AttachBlocks.tooOld`.
  - **Empty field.** `send`, `canSend` and `reason` accept empty text when chips exist.
  - **Offer.** The offer holds only the user's own text. The clear check compares the field with that text.
  - **`dispose`.** Cancel the active channel, set a stop flag, and guard every listener with `mounted`. Clear the cache when chips are dropped.
  - **`session.dart`.** Pass `upload` only while `m.mux != null`. Set `attachBlocked` from `writeBlockedOn` or `AttachBlocks.tooOld`.

- [ ] **Step 1:** Build the UI only: the `Composer.leading` button and the chip row, with a fake `pick` and `upload`.
- [ ] **Step 2: Show the owner.** Render the composer offscreen with two chips, one of them uploading. Pass the visual-critic loop, put the result on an Artifact page, and get approval. The chips must match the app's existing chip style.
- [ ] **Step 3: Write the failing composer tests** (`_C` harness):
  - picking adds chips, and × removes one;
  - Send pastes exactly `fix this Attached: '/h/u/S/a.png' '/h/u/S/b.txt'`;
  - with no text, Send pastes `Attached: '/h/u/S/a.png'`;
  - under the shipped checks, `/review` plus a chip goes as one `PasteWrite` of `/review Attached: '…'`; with `pastedCommandRuns: false` it goes as a `TextWrite`;
  - a failed second upload keeps the chips and the text, and the re-send uploads only the second chip;
  - removing an uploading chip stops the send silently;
  - a second Send tap during an upload does nothing;
  - `send('/model')` leaves the chips alone;
  - unmounting during an upload sends CLOSE and writes nothing;
  - after a `tooOld` failure, the button is disabled and its tooltip gives the reason.
- [ ] **Step 4:** Wire the upload logic. Run the composer tests. Expected: PASS.
- [ ] **Step 5: Screen test** in `chat_screen_test.dart`, using `Harness`/`Relay`:
  - set `Watch.permitted = false`;
  - complete the fake pick inside `pauseResume`'s paused phase, so the link really closes and reconnects;
  - Send, with the fake relay answering OPENED, CREDIT and CLOSE `uploaded` on the upload channel;
  - assert the paste of the attached line.
- [ ] **Step 6:** Run `flutter analyze --no-pub` and `flutter test --no-pub`. Expected: PASS. Commit `feat(mobile): attach files in Chat`.

### Task 9: Chat Send on rows attached from another Mac

**Files:**
- Modify: `mobile/lib/chat/checks.dart`, `site/docs.html` (`#phone-chat-remote`)
- Test: `mobile/test/chat_composer_test.dart` (`serverRowSendsWithServerChecksOnly`), `mobile/test/prompt_cards_test.dart` (`remoteRowDisabledUntilProven`, `serverRowAnswersAttachedRowStaysOff`)

- [ ] **Step 1:** The owner runs the elis-server report's checks on a Mac-attached row, using two Macs and the phone on LAN:
  - keys, paste and Send;
  - a multiSelect card and a Bash card answered from the phone;
  - a mode-chip change;
  - an attached PNG that Claude reads.

  Record the date and the Claude version in the `checks` comment.
- [ ] **Step 2:** Set `attached: true`.
  - Update the three tests above so that attached rows pass.
  - Add a test that the shipped `checks` enable Send and card answering on an attached row.
  - Rewrite `#phone-chat-remote` so one rule covers both kinds of remote row.

  Commit `feat(mobile): Chat Send on rows attached from another Mac`.

### Task 10: Docs and end-to-end check

**Files:**
- Modify:
  - `.claude/rules/control-api.md`:
    - the public catalog;
    - the `session.upload` contract and its no-read-back exemption;
    - the relay mux `upload` channel: window, refusals and CLOSE reasons;
    - the "Relay-to-phone CREDIT goes only on a claim or `forward` channel" bullet, which now also covers `upload`;
    - the stale "the relay runs only on a Mac" line at :419.
  - `site/commands.html` (`#session`, next to `session transcript`)
  - `site/docs.html` (`#phone-chat-send`)
  - `plugins/elis/skills/elis/SKILL.md`, `reference.md` and `linux.md`
  - `linux/README.md` (Control API, Phone app)

- [ ] **Step 1:** Mirror every `git grep -n "session transcript"` hit in the surfaces above.
- [ ] **Step 2:** Run the emulator end-to-end against an offscreen Linux build on `/tmp/elr`:
  1. Attach a PNG and a `.txt` to an agy session and to a claude session.
  2. Check that each agent quotes the file's content.
  3. Check that `ls /tmp/elr/uploads/<id>/` shows exactly the two files.

  If Claude shows `[Image #N]` for the line, extend `pasteShown` to accept that placeholder, with a test, before continuing.
- [ ] **Step 3:** Run every gate once. Commit `docs: phone Chat attachments`.
