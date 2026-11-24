# Phone Chat attachments — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone's Chat composer attaches files. They upload to the session's host, and the sent prompt names their host paths.

**Architecture:**
- A new mux channel type `upload` carries the bytes from the phone to the relay under credit.
- The relay asks the app for a destination with a new non-streaming `session.upload` command. It writes the file itself for a local row. For a remote row it pipes the bytes into `ssh … elisctl session upload` on the origin host.
- The phone uploads its chips one by one, then sends `<text> Attached: '<p1>' …` through the existing write gate.

**Tech Stack:** Swift 6 (`shared/ElisCore`, `server/`, `linux/bridge`), C++ Qt6 (`linux/`), Flutter/Dart (`mobile/`), swift-testing, QTest, flutter_test.

**Spec:** `docs/superpowers/specs/2026-11-24-phone-chat-attachments-design.md`. Read "Owner decisions", "Design" and "Refusals". **Tracking:** Linear NAI-24.

## Global Constraints

- **Limits.** `UploadLimits.maxBytes = 20_971_520`, `UploadLimits.maxFiles = 10`, upload window `16384` bytes. Both Swift and Dart use the same values. A window mismatch closes the channel with `input overflow`.
- **Refusal copy.** Use the spec's "Refusals" texts byte for byte.
- **Prompt format.** `<trimmed text> Attached: '<p1>' '<p2>'`, all on one line. With no text it is `Attached: '<p1>'`.
- **Host file name.** Any character outside `[A-Za-z0-9._-]` becomes `_`. Truncate to 100 characters. An empty name becomes `file`. Prefix the stamp `yyyyMMdd-HHmmss-` in UTC. Make it unique by appending `-2`, `-3` … before the extension.
- **Retention.** Apply `UploadStorage.sweep(stateDir:keep:now:)` at each host's launch, and nowhere else.
- **Scope.** Chat view only. The Term composer passes no attach control.
- **Control API contract** (`.claude/rules/control-api.md`). `session.upload` ships with its protocol case, dispatcher, `elisctl`, tests and every docs surface in the same change. It sets no model state, so it has no read-back. Record that exemption in `control-api.md` next to the command's contract.
- **Musl.** `Session+Upload.swift` and everything it calls must compile without `#if !canImport(Musl)`. elis-server ships the musl `elisctl`.
- **Gates.**
  - ElisCore `swift test`: only the known zsh/tcsh/csh failures.
  - `server/` `swift test`.
  - Linux: CMake plus `ctest --test-dir build`.
  - Mobile: `flutter analyze --no-pub` and `flutter test --no-pub`. Follow the SDK-constraint note in `CLAUDE.md`.
  - `make lint` with zero findings.
  - Never wait on the macOS GitHub CI jobs.
- **Live terminal.** Never run `elis` or `elisctl` against the default socket. Emulator runs follow the `mobile-emulator-testing` memory.

## Review Focus

- **The picker backgrounds the app.** `ElisModel.pause()` closes the link unless Watch is on. Chips must survive the picker's pause and resume, and the upload starts only at Send, after `m.mux != null`. Task 8 tests this.
- **A link lost mid-upload.** The relay removes `<path>.part`, and the phone keeps every chip and the text. Chips already uploaded keep their host path, so a re-send uploads only the rest. Tasks 6 and 8 test this.
- **The user removes a chip while it uploads.** The channel CLOSEs, the relay leaves no file, and the send stops with the text kept. Task 8 tests this.
- **The text starts with `/`.** A slash command then receives the `Attached:` tail as arguments. Keep today's `/` branch, which sends a `TextWrite`. The paths still reach the agent. Task 8 asserts the exact line.
- **The relay or host is older.** OPENED `unsupported channel type`, or an unknown-command answer to `session.upload`, both show `Update Elis on the computer to attach files` on the phone. After that the attach button is disabled for this link. Task 7 tests this.

---

### Task 1: Wire messages and vectors

**Files:**
- Modify: `shared/ElisCore/Sources/ElisCore/PhoneLink/PhoneLinkMessages.swift`, `shared/fixtures/phone-link-vectors.json`, `mobile/lib/link/messages.dart`
- Test: `shared/ElisCore/Tests/ElisCoreTests/PhoneLinkMessagesTests.swift`, `mobile/test/link_test.dart`, `mobile/test/wire_names_test.dart`

**Interfaces:**
- Produces:
  - Swift: `PhoneLinkOpen` gains `name: String?` and `size: Int?`, nil-defaulted in the public init (agterm-linux calls it). `PhoneLinkClose` gains `path: String?`.
  - Dart mirrors both with the same JSON keys.

- [ ] **Step 1:** Add the vectors.
  - `open upload` is `{"name":"a b.png","size":5,"target":"S","type":"upload"}`.
  - `close uploaded` is `{"path":"/s/uploads/S/x.png","reason":"uploaded"}`.
  - Rename the stale `open page` vector's `type` to `present`.
- [ ] **Step 2:** Extend the Swift and Dart vector tests and `wire_names_test.dart`, adding the keys `name`, `size` and `path`. Run them and expect FAIL.
- [ ] **Step 3:** Add the fields. Encoding stays sorted keys without escaped slashes.
- [ ] **Step 4:** Run `swift test --filter PhoneLinkMessages` in `shared/ElisCore`, and `flutter test --no-pub test/link_test.dart test/wire_names_test.dart` in `mobile/`. Expect PASS.
- [ ] **Step 5:** Commit `feat(phone-link): upload open and close fields`.

### Task 2: `session.upload` in ElisCore and the Mac app

**Files:**
- Create:
  - `shared/ElisCore/Sources/ElisCore/UploadStorage.swift`
  - `shared/ElisCore/Sources/ElisCore/ControlDispatcher+Upload.swift`
- Modify:
  - `ControlProtocol.swift`
  - `ControlDispatcher.swift`
  - `ControlActions.swift`
  - `ControlActionsDefaults.swift`
  - `PageSessionRefusal.swift`
  - `HtmlBridge.swift`, only if its `refused` set lists by command
  - `AppStore` (a new `AppStore+Upload.swift`)
  - `macos/Elis/elisApp.swift`, for the launch sweep
- Test:
  - `shared/ElisCore/Tests/ElisCoreTests/UploadStorageTests.swift`
  - `shared/ElisCore/Tests/ElisCoreTests/ControlDispatcherUploadTests.swift`

**Interfaces:**
- Produces:
  - `Command.sessionUpload = "session.upload"`.
  - `ControlArgs.size: Int?`, unless the type already has it.
  - `public struct ControlUpload: Codable, Sendable, Equatable { path: String?; host: String?; session: String? }`.
  - `ControlResult.upload: ControlUpload?`.
  - `public enum UploadLimits { static let maxBytes = 20_971_520; static let maxFiles = 10 }`.
  - `public enum UploadStorage`, with these members:
    - `static func fileName(_ raw: String, now: Date) -> String`
    - `static func reserve(stateDir: URL, sessionID: String, name: String, now: Date) throws -> URL`, which creates the folder and returns a path that does not exist yet
    - `static func sweep(stateDir: URL, keep: Set<String>, now: Date, maxAge: TimeInterval = 7 * 86_400)`
  - `public final class UploadSink`, with these members:
    - `init(path: URL) throws`, which opens `<path>.part`
    - `func write(_ data: Data) throws`
    - `func finish() throws -> URL`, which renames the `.part` file to the path
    - `func abandon()`, which removes the `.part` file
  - `ControlDispatcher.uploadArguments(_ args: ControlArgs?) -> Result<(name: String, size: Int), ControlResponse>`, public, because `linux/bridge` calls it.
  - `ControlActions.uploadDestination(target: String?, name: String, size: Int) -> ControlResponse`. Its default in `ControlActionsDefaults` returns the same too-old refusal as `transcriptSource`.
  - `AppStore`'s implementation:
    - A row with `remoteHost` answers `ControlUpload(host: remoteHost, session: remoteSessionID)`.
    - A page row gets the page refusal.
    - Any other row answers the path from `reserve`.

- [ ] **Step 1: Write failing tests.**
  - `fileName("my photo'1.png", now:)` returns `"20261124-103000-my_photo_1.png"`.
  - A second `reserve` with the same name and second returns a path ending `-2.png`.
  - `UploadSink.finish` leaves only the final file. `abandon` leaves nothing.
  - `sweep` removes a folder not in `keep`, and a kept file whose mtime is 8 days old. It keeps a kept file 1 day old.
  - `uploadArguments` rejects size `20_971_521` with `file too large (max 20 MiB)`, and rejects a missing name.
  - Dispatch on a local row answers `upload.path` under `<stateDir>/uploads/<id>/`.
  - Dispatch on a row with `remoteHost` answers host and session.
- [ ] **Step 2:** Run `swift test --filter Upload` in `shared/ElisCore`. Expect FAIL.
- [ ] **Step 3:** Implement. `reserve` and `sweep` take `stateDir` explicitly; never resolve it from the environment inside `UploadStorage`.
- [ ] **Step 4:** At launch, `elisApp` calls `UploadStorage.sweep`. Its `keep` holds every session id in every saved window, plus the ids in `RecentClosed` items, local and remote. Run the dispatch off the accept thread only if `reserve`'s I/O shows up there. It is a mkdir, so expect not.
- [ ] **Step 5:** Run the tests again. Expect PASS. Commit `feat(control): session.upload reserves a host path`.

### Task 3: `elisctl session upload` and the remote argv

**Files:**
- Create: `shared/ElisCore/Sources/elisctlKit/Session+Upload.swift`, not Musl-gated
- Modify: `shared/ElisCore/Sources/elisctlKit/SessionCommands.swift` (add `Upload.self` to `subcommands`), `shared/ElisCore/Sources/ElisCore/RemoteSession.swift`
- Test: `shared/ElisCore/Tests/elisctlKitTests/SessionUploadCommandTests.swift`, `shared/ElisCore/Tests/ElisCoreTests/RemoteSessionTests.swift`

**Interfaces:**
- Consumes: `session.upload`, `UploadSink`.
- Produces:
  - `elisctl session upload --target <t> --name <n> --size <bytes>`. It reads exactly `size` bytes from stdin. Its stdout is always exactly one JSON `ControlResponse` line. A short stdin gives `upload ended after <k> of <n> bytes`, and the `.part` file is abandoned.
  - `RemoteSession.uploadCommand(host: String, session: String, name: String, size: Int, connectTimeout: Int = 5, controlPath: String? = nil) throws -> [String]`. It follows `presentCommand`: `-T`, `cliPathPrefix && exec elisctl session upload …`, and operands quoted with `CommandRestore.shellQuotedLine`.

- [ ] **Step 1: Write failing tests.**
  - Against a stub socket answering `upload.path`, five stdin bytes land at the path, and stdout is one ok line with that path.
  - Three bytes for `--size 5` print the short-stream error and leave no file.
  - A remote answer (`host` set) prints `cannot upload to a remote row from here`.
  - `uploadCommand` quotes a name with a space and refuses a host that fails `isPlain`.
- [ ] **Step 2:** Run the tests. Expect FAIL.
- [ ] **Step 3:** Implement. Copy stdin in chunks of at most 64 KiB.
- [ ] **Step 4:** Run the tests. Expect PASS. Commit `feat(elisctl): session upload`.

### Task 4: elis-server

**Files:**
- Modify: `server/Sources/ElisServerKit/ServerCommandPolicy.swift` (add `.sessionUpload` to `served`), `ServerActions+Sessions.swift`, and the server start path (`ElisServer.swift`)
- Test: `server/Tests/ElisServerTests/ServerActionsSessionsTests.swift`, `ServerCommandPolicyTests`

**Interfaces:**
- Consumes: `UploadStorage` with `configuration.stateDirectory`, and `ControlActions.uploadDestination`.

- [ ] **Step 1:** Write the failing tests.
  - `session.upload` on a server session answers a path under the configured state dir.
  - The policy classifies the command as served.
  - A start-up sweep removes a folder whose id is not a live or recent session.
- [ ] **Step 2:** Implement next to `transcriptSource`, reusing `windowRefusal` and `resolveSession`.
- [ ] **Step 3:** Run `swift test` in `server/`. Expect PASS. Commit `feat(server): session.upload`.

### Task 5: Linux Qt app

**Files:**
- Modify:
  - `linux/bridge/Sources/ElisBridge/Bridge.swift`, adding `@_cdecl("elis_upload_reserve")` and `@_cdecl("elis_upload_sweep")` and their header in `linux/bridge/include`
  - `linux/src/core/commands.cpp`, adding a `sessionUpload` handler after `sessionTranscript`
  - the Qt start-up path, which calls the sweep
  - `linux/src/ctl/elisctl.cpp`, adding `session upload` to the exec-to-Swift-helper list
- Test: `linux/tests/test_core.cpp`

**Interfaces:**
- Produces: `char *elis_upload_reserve(const char *stateDir, const char *sessionID, const char *argsJSON)`. It returns a `ControlResponse` JSON that the caller frees. It runs `uploadArguments` and then `reserve`. Also `void elis_upload_sweep(const char *stateDir, const char *keepJSON)`.
- Linux has no remote rows, so the handler only resolves the session and reserves.

- [ ] **Step 1:** Write a failing QTest. `session.upload` with name `a b.txt` and size 3 answers a path under `stateDir()/uploads/<id>/`. Size `20971521` gives the cap refusal.
- [ ] **Step 2:** Implement. The `keep` list holds the store's sessions plus its closed list.
- [ ] **Step 3:** Run the CMake build and `ctest --test-dir build`. Expect PASS. Commit `feat(linux): session.upload`.

### Task 6: Relay upload channel

**Files:**
- Create: `shared/ElisCore/Sources/elisctlKit/PhoneLinkUpload.swift`
- Modify: `shared/ElisCore/Sources/elisctlKit/PhoneLinkSession.swift`
- Test: `shared/ElisCore/Tests/elisctlKitTests/PhoneLinkUploadTests.swift`

**Interfaces:**
- Consumes: `session.upload` through `SocketClient(path: socketPath)`, `UploadSink`, `RemoteSession.uploadCommand`, and `PhoneLinkOpen.name` and `size`.
- Produces: `PhoneLinkUpload.window = 16384`, and the relay behaviour the phone relies on:
  1. OPEN `upload` is checked in this order:
     - a missing `name` or `size`: `malformed open`;
     - `size > UploadLimits.maxBytes`: the cap text;
     - an upload already open on this link: `an upload is already running`.
  2. It asks the app `session.upload` off the relay queue. An error answer becomes OPENED `{error}` with the same text.
  3. If the answer has a path, it streams into an `UploadSink`. If the answer has a host, it starts a `Process` on `uploadCommand` with stdin and stdout pipes. The process is owned by the upload. `PhoneLinkLineStream` is not reused, because it has no write completion.
  4. OPENED `{}`.
  5. DATA is written on a private serial queue. Each completed write sends CREDIT through `sendDirect`. Bytes beyond the window give `input overflow`.
  6. When `size` bytes are in, a local row calls `finish()`. A remote row closes stdin and reads the one reply line. Then CLOSE `{reason:"uploaded", path}` is sent.
  7. Any failure, a phone CLOSE, or `close(reason:)` abandons the sink or terminates the process.
- Wire `uploads[channel]` into the duplicate check, DATA, CLOSE, `close(reason:)` and `closeChannel`. Do not call `scheduler.open`.

- [ ] **Step 1: Write failing tests.** Use the `MobileTestSupport` fakes and a stub app socket.
  - Five DATA bytes yield CLOSE `uploaded` with the stub's path and the file on disk.
  - An over-cap OPEN is refused.
  - A second OPEN is refused while one is running.
  - A phone CLOSE after 2 of 5 bytes leaves no `.part` file.
  - A link `close` mid-stream leaves no `.part` file.
  - 16385 unacknowledged bytes close the channel with `input overflow`.
  - A remote answer runs the argv from `uploadCommand`. Inject the process launcher, and assert the argv plus a stub reply line mapped to CLOSE `uploaded`.
  - A stub reply that is not JSON maps to `Update Elis on <host> to attach files`.
- [ ] **Step 2:** Run `swift test --filter PhoneLinkUpload`. Expect FAIL.
- [ ] **Step 3:** Implement, using `PhoneLinkForward` as the model for the window, the `writes` queue and coalesced CREDIT.
- [ ] **Step 4:** Run the tests. Expect PASS. Commit `feat(relay): upload channel`.

### Task 7: Phone mux upload

**Files:**
- Modify: `mobile/lib/link/mux.dart`
- Test: `mobile/test/mux_test.dart`

**Interfaces:**
- Produces:
  - `const _uploadWindow = 16384;`
  - `UploadChannel Mux.upload(String target, {required String name, required int size})`.
  - `class UploadChannel`, with these members:
    - `Stream<int> get progress`, the credited bytes;
    - `Future<String> get done`, which completes with the host path or throws `UploadFailed(String reason)`;
    - `Future<void> send(Stream<List<int>> bytes)`, which starts after OPENED, splits into frames of at most `linkMaxPayload`, and waits while `_Outbox` is full;
    - `void cancel()`, which sends CLOSE.
- `UploadFailed.tooOld` is true for `unsupported channel type`, for an unknown-command answer, and for `Update Elis on` texts.

- [ ] **Step 1:** Write failing tests with `FakeRelay` and `upgraded()`.
  - The OPEN payload equals the `open upload` vector.
  - No DATA is sent before OPENED.
  - At most 16384 bytes stay unacknowledged.
  - CLOSE `uploaded` completes `done` with the path.
  - OPENED `{error}` throws with that reason.
  - A link loss throws `link lost`.
  - `cancel()` sends CLOSE.
- [ ] **Step 2:** Implement, using `ForwardChannel` and `_Outbox` as the model. Run `flutter test --no-pub test/mux_test.dart` and expect PASS. Commit `feat(mobile): mux upload channel`.

### Task 8: Chat composer attachments

**Files:**
- Create: `mobile/lib/chat/attachments.dart`
- Modify:
  - `mobile/lib/screens/composer.dart`, adding `final Widget? leading;` rendered before the TextField
  - `mobile/lib/chat/chat_composer.dart`
  - `mobile/lib/chat/chat_view.dart`
  - `mobile/lib/screens/session.dart` (`_chatView`)
  - `mobile/pubspec.yaml`, adding `file_picker` at the newest version that resolves with the lock
  - `mobile/README.md`
- Test: `mobile/test/chat_composer_test.dart`, `mobile/test/chat_screen_test.dart`

**Interfaces:**
- Consumes: `Mux.upload`, `UploadChannel`.
- Produces:
  - `class PickedFile { final String name, path; final int size; }`.
  - `typedef PickFiles = Future<List<PickedFile>> Function();` with `pickFiles` as the `file_picker` default (multiple selection, any type).
  - `typedef UploadFile = UploadChannel Function(PickedFile f);`.
  - `String attachedLine(String text, List<String> paths)`, which produces the prompt format from Global Constraints.
  - `ChatComposer` gains `PickFiles? pick`, `UploadFile? upload` (null means the button is disabled) and `String? attachBlocked`.
- Behaviour of the composer:
  - **Attach button.** An `IconButton(Icons.attach_file)` sits in `Composer.leading`. It is disabled while `held != null`, while the gate is running, while `upload == null`, or when `attachBlocked != null`.
  - **Chips.** They show in the existing `accessory` Column as `InputChip`s with the name and a size such as `1.2 MB`, plus × to remove. An uploading chip shows a determinate `LinearProgressIndicator` from `progress`.
  - **Too many or too large.** A pick over the cap or past 10 files shows the cap text through `_tell`.
  - **Send.**
    1. `_blocked` check.
    2. Upload each chip that has no `hostPath`, one at a time.
    3. `_blocked` check again.
    4. `gate.run` with `attachedLine`.
    5. On success, clear the field and the chips and call `FilePicker.platform.clearTemporaryFiles()`.
    6. On failure, keep both and `_tell` the reason, or `Update Elis on the computer to attach files` when `tooOld`.
  - Compare the field to the user's own text, never to the joined line. The offer and draft logic never sees the paths.

- [ ] **Step 1: Show the owner.** Render the composer with two chips, one of them uploading, in a throwaway golden or an offscreen grab. Put it on an Artifact page, pass the visual-critic loop, and get the owner's approval. The chips must look like the app's existing chips.
- [ ] **Step 2: Write failing composer tests.** Use the `_C` harness with a fake `pick` and `upload`.
  - The pick adds chips, and × removes one.
  - Send produces exactly `fix this Attached: '/h/u/S/a.png' '/h/u/S/b.txt'`.
  - With no text it produces `Attached: '/h/u/S/a.png'`.
  - `/review` with a chip goes as a `TextWrite` of `/review Attached: '…'`.
  - A failed second upload keeps both chips and the text. The first chip keeps its host path and does not upload again on re-send.
  - Removing an uploading chip cancels it and keeps the text.
  - The button is disabled when `upload == null`.
- [ ] **Step 3: Write a failing screen test.** Use `Harness` and `Relay` in `chat_screen_test.dart`.
  1. Pick.
  2. Pause, then resume (`_pauseResume`).
  3. Send.
  4. Assert the relay saw OPEN `upload` and DATA, and then the paste of the attached line.
- [ ] **Step 4:** Implement. `session.dart` passes `upload` only while `m.mux != null`, and sets `attachBlocked` from `writeBlockedOn`.
- [ ] **Step 5:** Run `flutter analyze --no-pub` and `flutter test --no-pub`. Expect PASS. Commit `feat(mobile): attach files in Chat`.

### Task 9: Chat Send on rows attached from another Mac

**Files:**
- Modify: `mobile/lib/chat/checks.dart`, `site/docs.html` (`#phone-chat-remote`)

- [ ] **Step 1:** The owner runs the open checks on a Mac-attached row, using two Macs and the phone over LAN, and records the date and Claude version in the `checks` comment:
  - checks 1 to 3 (keys, paste and Send);
  - an attached PNG read by Claude.
- [ ] **Step 2:** Set `attached: true`. Update the test in `write_gate_test.dart` that asserts the remote block for attached rows, and remove the "not verified on remote sessions" line from `#phone-chat-remote`. Commit `feat(mobile): Chat Send on rows attached from another Mac`.

### Task 10: Docs and end-to-end check

**Files:**
- Modify:
  - `.claude/rules/control-api.md`: the public catalog, the `session.upload` contract and its no-read-back exemption, the relay mux `upload` channel (window, refusals, CLOSE reasons), and the stale "the relay runs only on a Mac" line at :419
  - `site/commands.html` (`#session`, next to `session transcript`)
  - `site/docs.html` (`#phone-chat-send`)
  - `plugins/elis/skills/elis/SKILL.md`, `reference.md` and `linux.md`
  - `linux/README.md`, in Control API and Phone app

- [ ] **Step 1:** Mirror every `git grep -n "session transcript"` hit in the surfaces above.
- [ ] **Step 2:** Run the emulator end to end per the `mobile-emulator-testing` memory, against an offscreen Linux build on `/tmp/elr`:
  - attach a PNG and a `.txt` to an agy session and a claude session;
  - confirm each agent quotes the file's content;
  - confirm `ls /tmp/elr/uploads/<id>/` shows exactly two files and no `.part`.
  - If Claude shows `[Image #N]` for the line, extend `pasteShown` to accept that placeholder, with a test, before continuing.
- [ ] **Step 3:** Run every gate once. Commit `docs: phone Chat attachments`.
