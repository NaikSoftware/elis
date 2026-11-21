# Elis assistant: ElisCore contract — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Everything platform-free about the Elis assistant in `ElisCore`: handles, targets, the typed message line, the chat transcript, provider launch and stream codecs, the system prompt, and the whole `assistant.*` control contract with its `elisctl` CLI, `elisctl reply` included.

**Architecture:** Pure value types and one main-actor state object (`AssistantChat`, shaped like `MessageBus`) in `ElisCore`; `ControlDispatcher+Assistant.swift` owns parsing, validation, error text and response shape; hosts supply only a peer directory, typing, the provider process and events through `ControlActions` hooks whose defaults refuse by name. Linux (plan 2) and Mac (plan 3) are hosts over this contract.

**Tech Stack:** Swift 6 (complete concurrency), swift-testing, swift-argument-parser.

**Spec:** `docs/superpowers/specs/2026-11-21-elis-assistant-design.md`

## Global Constraints

- Paths below are under `macos/ElisCore`; the in-flight refactor moves it to `shared/ElisCore` and rebase carries new files by rename.
- Run tests on this machine with `/home/naik/.local/opt/swift-6.3.2-RELEASE-ubuntu24.04/usr/bin/swift test --filter <Suite>` from the package root; afterwards `git checkout Package.resolved` (a Linux build rewrites the swift-markdown pins).
- `ElisCore` imports no AppKit, GhosttyKit, Metal or CoreGraphics; no ICU-only API (`applyingTransform`) since Linux links it.
- New `ControlActions` requirements get defaults in `ControlActionsDefaults.swift` that refuse with `ControlActionsUnsupported.message("<cmd>")`, so the Mac app, elis-server and the agterm-linux fork keep building unchanged.
- The typed line is `[Elis] <text> — reply: elisctl reply "<answer>"`, one line, at most 900 UTF-8 bytes; the hint is never cut, the text is.
- Group tags (`@ws:…`, `@all`) reach only sessions with an `agent`; a session with status `blocked` is never typed into; nothing is queued.
- Transcript keeps the last 500 entries.
- One file per responsibility; files under 1000 lines, types under 800 (`make lint` limits).
- Comments only for non-obvious constraints (CLAUDE.md working norms); test comments rare and one line.
- Mac gates (`make test-app`, `make lint`, Xcode build) run in CI on the PR; Linux runs `swift test` only.

## Review Focus

- A name that transliterates to nothing (emoji only, `~`, punctuation): the session still gets a usable handle (`s-` plus the first four hex digits of its id).
- Two sessions with the same name: stable `-2`, `-3` suffixes in directory order, so a handle does not jump between sessions as the tree is re-read.
- Message text with quotes, newlines, tabs or 5 KB of text: one line, hint intact, text cut on a character boundary.
- A reply from a session the directory no longer lists (closed meanwhile): refused `assistant.reply: unknown session <id>`, never stored as anonymous.
- A provider writes a non-JSON line (a warning, a progress bar) to stdout: decoded as nothing, never a crash or an error entry.

---

### Task 1: Session handles

**Files:**
- Create: `Sources/ElisCore/AssistantHandle.swift`
- Test: `Tests/ElisCoreTests/AssistantHandleTests.swift`

**Interfaces:**
- Produces: `public enum AssistantHandle { public static func assign(_ items: [(id: String, name: String)]) -> [String: String] }` — id → handle, in input order for collisions.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func cyrillicNameKeepsTwoWordsAndShortensLongOnes() {
    #expect(AssistantHandle.assign([("a", "Міграція Linux-версії за планом")]) == ["a": "mihr-linux"])
}
@Test func latinNameDropsStopwords() {
    #expect(AssistantHandle.assign([("a", "fix the sidebar filter")]) == ["a": "fix-side"])
}
@Test func duplicatesGetSuffixesInOrder() {
    #expect(AssistantHandle.assign([("a", "logcat"), ("b", "logcat")]) == ["a": "logcat", "b": "logcat-2"])
}
@Test func emptyTransliterationFallsBackToId() {
    #expect(AssistantHandle.assign([("3fa9c1d2-0000", "🚀 ~")]) == ["3fa9c1d2-0000": "s-3fa9"])
}
@Test func handlesAreCappedAndClean() {
    let handle = AssistantHandle.assign([("a", "superlongword anotherlongword")])["a"]!
    #expect(handle.count <= 12)
    #expect(handle.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" })
    #expect(!handle.hasSuffix("-"))
}
```

- [ ] **Step 2: Run** `swift test --filter AssistantHandleTests` — expect FAIL (`cannot find 'AssistantHandle'`).

- [ ] **Step 3: Implement `assign` in `AssistantHandle.swift`**

Rule: lowercase; transliterate with a fixed map (Ukrainian national table without positional rules:
а a, б b, в v, г h, ґ g, д d, е e, є ie, ж zh, з z, и y, і i, ї i, й i, к k, л l, м m, н n, о o, п p, р r, с s,
т t, у u, ф f, х kh, ц ts, ч ch, ш sh, щ shch, ь —, ю iu, я ia, ’ ' —; plus ё e, ы y, э e, ъ —);
split on anything outside `[a-z0-9]`; drop stopwords `за і й та в у на з із до для по the a an of for to in on and`;
keep the first two words; a word longer than 6 characters becomes its first 4; join with `-`; cut to 12 and trim a
trailing `-`; empty → `s-` + first 4 characters of the id with dashes removed; a taken handle gets `-2`, `-3`, …
(the suffixed form is also cut so the whole stays within 12).

- [ ] **Step 4: Run** the suite — expect PASS.
- [ ] **Step 5: Commit** `feat(assistant): short session handles`.

### Task 2: Peers, targets and the typed line

**Files:**
- Create: `Sources/ElisCore/AssistantTargets.swift`
- Test: `Tests/ElisCoreTests/AssistantTargetsTests.swift`

**Interfaces:**
- Consumes: `AssistantHandle.assign`.
- Produces:
  - `public struct AssistantPeer: Codable, Sendable, Equatable { sessionID, window, workspaceID, workspaceName, name: String; agent, status: String? }`
  - `public struct AssistantDirectory: Sendable { public init(_ peers: [AssistantPeer]); public func handle(of sessionID: String) -> String?; public func workspaceHandle(of workspaceID: String) -> String?; public let peers: [AssistantPeer] }` — session handles over all peers in order; workspace handles over distinct workspaces in first-seen order.
  - `public struct AssistantSkip: Codable, Sendable, Equatable { handle: String; reason: String }` with reason `"blocked"`.
  - `public struct AssistantDelivery: Sendable, Equatable { targets: [AssistantPeer]; skipped: [AssistantSkip] }`
  - `public enum AssistantTargets { public static func resolve(_ tags: [String], in: AssistantDirectory) throws(AssistantTagError) -> AssistantDelivery }`; `AssistantTagError.message` is `unknown tag @<tag>` or `no tags`.
  - `public enum AssistantLine { public static let maxBytes = 900; public static func make(_ text: String) throws(AssistantLineError) -> String }`; error message `text must not contain a NUL byte` or `empty message`.

- [ ] **Step 1: Write the failing tests**

```swift
// directory: "claude 1" (id claude1, agent claude, idle) and "zsh" (id shell1, no agent) in workspace "elis",
// "codex run" (id codex1, agent codex, status blocked) in workspace "mobile"
@Test func allReachesAgentsOnlyAndSkipsBlocked() throws {
    let d = try AssistantTargets.resolve(["@all"], in: directory)
    #expect(d.targets.map(\.sessionID) == ["claude1"])
    #expect(d.skipped == [AssistantSkip(handle: "codex-run", reason: "blocked")])
}
@Test func workspaceTagExpandsToItsAgents() throws {
    #expect(try AssistantTargets.resolve(["@ws:elis"], in: directory).targets.map(\.sessionID) == ["claude1"])
}
@Test func explicitTagReachesAPlainShell() throws {
    #expect(try AssistantTargets.resolve(["@zsh"], in: directory).targets.map(\.sessionID) == ["shell1"])
}
@Test func explicitTagToABlockedAgentIsSkipped() throws {
    let d = try AssistantTargets.resolve(["codex-run"], in: directory)   // leading @ optional
    #expect(d.targets.isEmpty && d.skipped.map(\.handle) == ["codex-run"])
}
@Test func duplicatesCollapseAndUnknownTagsThrow() throws {
    #expect(try AssistantTargets.resolve(["@all", "@claude-1"], in: directory).targets.count == 1)
    #expect(throws: AssistantTagError.self) { try AssistantTargets.resolve(["@nobody"], in: directory) }
}
@Test func lineFoldsNewlinesAndKeepsTheHint() throws {
    #expect(try AssistantLine.make("a\nb\t\"c\"") == "[Elis] a b \"c\" — reply: elisctl reply \"<answer>\"")
    let long = try AssistantLine.make(String(repeating: "я", count: 5000))
    #expect(long.utf8.count <= AssistantLine.maxBytes && long.hasSuffix("elisctl reply \"<answer>\""))
}
@Test func lineRefusesNulAndBlank() {
    #expect(throws: AssistantLineError.self) { try AssistantLine.make("a\u{0}b") }
    #expect(throws: AssistantLineError.self) { try AssistantLine.make(" \n ") }
}
```

- [ ] **Step 2: Run** `swift test --filter AssistantTargetsTests` — expect FAIL.
- [ ] **Step 3: Implement** in `AssistantTargets.swift`; fold every control character and newline to one space, collapse runs, trim; cut the text on a `Character` boundary so line bytes ≤ 900.
- [ ] **Step 4: Run** — expect PASS.
- [ ] **Step 5: Commit** `feat(assistant): tag resolution and the typed line`.

### Task 3: Chat transcript

**Files:**
- Create: `Sources/ElisCore/AssistantChat.swift`
- Test: `Tests/ElisCoreTests/AssistantChatTests.swift`

**Interfaces:**
- Produces:
  - `public struct AssistantEntry: Codable, Sendable, Equatable { id: UUID; kind: Kind; from: String?; to: [String]?; text: String; ts: Double; public enum Kind: String, Codable { user, assistant, sent, reply, error } }` — `from`/`to` are session ids.
  - `public enum AssistantMark: String, Codable, Sendable { waiting, replied, notDelivered = "not-delivered" }`
  - `public final class AssistantChat { public static let shared; public init(file: URL? = nil); public func append(_ kind: AssistantEntry.Kind, text: String, from: String? = nil, to: [String]? = nil, now: Double) -> AssistantEntry; public func entries(last: Int?) -> [AssistantEntry]; public private(set) var unread: Int; public func markSeen(); public private(set) var marks: [String: AssistantMark]; public func markSkipped(_ sessionIDs: [String]); public var provider: SessionLauncher?; public var running: Bool }` — main-actor confined like `MessageBus`.
  - Rules: `user` clears `marks`; `sent` sets each `to` to `waiting`; `markSkipped` sets `notDelivered`; `reply` sets its `from` to `replied` and adds 1 to `unread`; `markSeen` zeroes `unread`.
  - Persistence: `<file>` is JSONL, one entry per line, rewritten trimmed to the last 500 when it exceeds 600 lines, else appended; `provider` lives in `<file>.provider` (raw value). A line that does not decode is skipped on load.

- [ ] **Step 1: Write the failing tests** — `userMessageClearsMarks`, `replyMarksSenderAndCountsUnread`, `markSeenZeroesUnread`, `reloadRestoresEntriesAndProvider` (write to a temp dir, new instance, same `entries(last: nil)` and `provider`), `transcriptKeepsTheLast500` (append 650, reload, count 500, first is entry 151), `undecodableLineIsSkipped`.
- [ ] **Step 2: Run** `swift test --filter AssistantChatTests` — expect FAIL.
- [ ] **Step 3: Implement** `AssistantChat.swift`.
- [ ] **Step 4: Run** — expect PASS.
- [ ] **Step 5: Commit** `feat(assistant): chat transcript`.

### Task 4: Provider launch and stream codecs

**Files:**
- Create: `Sources/ElisCore/AssistantProvider.swift`, `Sources/ElisCore/AssistantStream.swift`
- Create fixtures: `Tests/ElisCoreTests/Fixtures/assistant/{claude,antigravity,codex,opencode}.jsonl`
- Test: `Tests/ElisCoreTests/AssistantProviderTests.swift`

**Interfaces:**
- Consumes: `SessionLauncher`.
- Produces:
  - `public enum AssistantMode: Sendable { case stream, perInput }`
  - `public struct AssistantLaunch: Sendable, Equatable { argv: [String]; mode: AssistantMode }`
  - `public enum AssistantProvider { public static func choices(_ available: [SessionLauncher]) -> [SessionLauncher]` (drops `.terminal`) `; public static func launch(_ p: SessionLauncher, prompt: String, resume: String?) -> AssistantLaunch` (for `.stream`: the long-lived process) `; public static func turn(_ p: SessionLauncher, input: String, prompt: String, resume: String?) -> [String]` (for `.perInput`: one process per input) `}`
  - `public enum AssistantStreamEvent: Sendable, Equatable { case text(String), conversation(String), turnEnded(error: String?) }`
  - `public enum AssistantStream { public static func encode(_ p: SessionLauncher, text: String) -> String` (one NDJSON line, stream mode only) `; public static func decode(_ p: SessionLauncher, line: String) -> [AssistantStreamEvent] }`

- [ ] **Step 1: Verify each CLI and record fixtures.** `claude` and `agy` are installed here; install `@openai/codex` and `opencode-ai` with `npm install --prefix <scratchpad>/cli` and read their `--help`. Record a real two-turn exchange for every CLI that can authenticate here into its fixture file; for one that cannot, write the fixture from that CLI's own documented event schema and mark it in the fixture's first line `{"fixture":"documented"}`. Expected routes, confirm or correct each:
  - Claude, stream: `claude -p --input-format stream-json --output-format stream-json --verbose --allowedTools "Bash(elisctl:*)" --append-system-prompt <prompt> [--resume <id>]`; input `{"type":"user","message":{"role":"user","content":[{"type":"text","text":…}]}}`; `system/init` and `result` carry `session_id`.
  - Antigravity, stream: `agy -p --input-format stream-json --output-format stream-json` with its permission settings limited to `elisctl` (`--settings` allow rule), `--conversation <id>` to resume.
  - Codex, perInput: `codex exec --json …` then `codex exec resume <thread_id> --json …`, sandbox and approval flags that allow only `elisctl`.
  - OpenCode, perInput: `opencode run --format json [--session <id>] …`, permission config allowing only `elisctl`.
  Prompt passing for a CLI without a system-prompt flag: prepend it to the first input.
- [ ] **Step 2: Write the failing tests** — `claudeLaunchIsStreamWithElisctlOnly` (argv contains `--input-format`, `stream-json`, `Bash(elisctl:*)`; resume adds `--resume`), one `launch`/`turn` argv test per provider, `encodeProducesOneLine` (no `\n` inside, round-trips text with quotes and newlines), `decode<Provider>Fixture` per fixture (expected `[.conversation(id), .text(...), .turnEnded(error: nil)]` sequence), `nonJSONLineDecodesToNothing` (`decode(.claude, line: "warning: x") == []`), `choicesDropTerminal`.
- [ ] **Step 3: Run** `swift test --filter AssistantProviderTests` — expect FAIL.
- [ ] **Step 4: Implement** both files to the verified routes.
- [ ] **Step 5: Run** — expect PASS.
- [ ] **Step 6: Commit** `feat(assistant): provider launch and stream codecs`.

### Task 5: System prompt

**Files:**
- Create: `Sources/ElisCore/AssistantPrompt.swift`
- Test: `Tests/ElisCoreTests/AssistantPromptTests.swift`

**Interfaces:**
- Consumes: `AssistantDirectory`.
- Produces: `public enum AssistantPrompt { public static func system(_ directory: AssistantDirectory) -> String }`.

Fixed content, in English: you are Elis, the assistant of the Elis terminal; act only through `elisctl`
(the `elis` skill documents it); message sessions with `elisctl assistant send --to @handle "text"`;
the user's tags say whom a message is about; never type into a session any other way; replies arrive as
messages starting `[reply from @handle]`; a reply is not a request to message that session again unless the user
asked; then a table `handle | workspace | agent | status | session id`, one row per peer.

- [ ] **Step 1: Write the failing test** `promptListsEveryPeerAndTheRules` (contains `elisctl assistant send`, `[reply from @`, and one row per peer with its handle and status).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(assistant): system prompt`.

### Task 6: Control contract

**Files:**
- Modify: `Sources/ElisCore/ControlProtocol.swift` (commands, args), `Sources/ElisCore/ControlPayloads.swift` (result), `Sources/ElisCore/ControlActions.swift`, `Sources/ElisCore/ControlActionsDefaults.swift`, `Sources/ElisCore/ControlDispatcher.swift` (route), `Sources/ElisCore/ControlProjection+Tree.swift` (`assistant`), `Sources/ElisCore/ControlProjection.swift` (`handle` on session and workspace nodes, optional, nil in existing inits)
- Create: `Sources/ElisCore/ControlDispatcher+Assistant.swift`
- Modify: `Tests/ElisCoreTests/MockControlActions.swift`
- Test: `Tests/ElisCoreTests/ControlDispatcherAssistantTests.swift`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces:
  - `Command`: `assistantAsk = "assistant.ask"`, `assistantSend = "assistant.send"`, `assistantReply = "assistant.reply"`, `assistantRead = "assistant.read"`, `assistantProvider = "assistant.provider"`, `assistantShow = "assistant.show"`.
  - `ControlArgs`: reuse `text`, `recipients` (tags), `window`; add `last: Int?`, `provider: String?`.
  - `ControlResult.assistant: ControlAssistantResult?` = `{ entries: [AssistantEntry]?, delivered: [String]?, skipped: [AssistantSkip]?, provider: String?, providers: [String]? }`.
  - `ControlTree.assistant: ControlAssistantNode?` = `{ provider: String?, providers: [String], running: Bool, unread: Int }`.
  - `ControlActions` hooks (defaults refuse or no-op): `assistantPeers() -> [AssistantPeer]?` (nil = unsupported), `assistantInput(_ entry: AssistantEntry)` (host writes it into the stream; no-op default), `assistantProviders() -> [SessionLauncher]?`, `assistantProviderChanged(_ p: SessionLauncher)`, `showAssistant(window: String?) -> ControlResponse`.
  - `ControlDispatcher.init(actions:bus:chat:)` with `chat: AssistantChat = .shared`.
- Behavior (dispatcher owns all error text):
  - `ask`: blank text → `assistant.ask requires text`; appends `user`, calls `assistantInput`, returns the entry.
  - `send`: no tags → `assistant.send requires --to`; resolves on `AssistantDirectory(assistantPeers())`; builds the line once; types each target through `typeSession(peer.sessionID, window: peer.window, options: text = line + "\n")`; a target whose typing fails joins `skipped` with reason `failed: <error>`; appends one `sent` entry with the delivered ids; `markSkipped`; returns `delivered` handles and `skipped`.
  - `reply`: sender is `request.target` resolved against the peers by session id or unique prefix; unknown → `assistant.reply: unknown session <target>`; appends `reply` from it, calls `assistantInput` with text `[reply from @handle] <text>`.
  - `read`: `last` ≥ 1 or omitted, else `assistant.read: --last must be positive`; returns entries.
  - `provider`: bare reads; a value not in `assistantProviders()` → `unknown provider <name>; available: <list>`; sets `chat.provider`, calls `assistantProviderChanged`.
  - `show`: delegates to `showAssistant`, then `chat.markSeen()` on ok.
- Events are the host's: it emits `assistant.message` from `assistantInput` and from the `sent` entry; the dispatcher calls `assistantInput` for `user` and `reply` only.

- [ ] **Step 1: Write the failing tests** (mock peers as in Task 2): `askAppendsAndFeedsTheStream`, `sendTypesTheLineIntoEachTargetAndRecordsIt` (mock records `typeSession` calls: text equals `AssistantLine.make` + `"\n"`, window passed), `sendSkipsBlockedAndMarksThem`, `sendUnknownTagFailsWithoutTyping`, `replyFromKnownSessionFeedsTheStreamWithItsHandle`, `replyFromUnknownSessionIsRefused`, `readHonoursLast`, `providerRejectsUnavailable`, `everyAssistantCommandRefusesOnAHostWithoutSupport` (default `MockControlActions` without peers → error contains `assistant.`), `treeOmitsAssistantWhenNil` (encode `ControlTree` without it → no `assistant` key), round-trip `ControlRequest` encode/decode for each new command.
- [ ] **Step 2: Run** `swift test --filter ControlDispatcherAssistantTests` — expect FAIL.
- [ ] **Step 3: Implement** the protocol additions, defaults, routing (`case .assistantAsk, … : return await dispatchAssistantCommand(request)`) and `ControlDispatcher+Assistant.swift`.
- [ ] **Step 4: Run** the suite, then the whole `ElisCoreTests` target — expect PASS.
- [ ] **Step 5: Commit** `feat(assistant): assistant.* control contract`.

### Task 7: `elisctl assistant` and `elisctl reply`

**Files:**
- Create: `Sources/elisctlKit/AssistantCommands.swift`
- Modify: `Sources/elisctlKit/Commands.swift` (register `Assistant` and `Reply`), `Sources/elisctlKit/EventCommands.swift` (`EventFormatter.human` for `assistant.message`)
- Test: `Tests/elisctlKitTests/AssistantCommandsTests.swift`

**Interfaces:**
- Consumes: Task 6 wire names and `ControlAssistantResult`.
- Produces CLI:
  - `elisctl assistant ask TEXT [--wait [--timeout N]]` — `--wait` polls `tree` until `assistant.running` is false (100 ms, then 500 ms after 1 s, as `pick`), exit 124 on timeout.
  - `elisctl assistant send --to TAG [--to TAG…] TEXT|--stdin`
  - `elisctl assistant read [--last N]` — human: `HH:MM kind @from: text` per entry.
  - `elisctl assistant provider [NAME]`, `elisctl assistant show`
  - `elisctl reply TEXT|--stdin` — target from `CallerEnvironment.defaultSessionTarget`; outside a session (`ELIS_SESSION_ID` unset) fails `elisctl reply runs inside an Elis session`.
  - Event human line: `assistant.message kind=<kind> from=<handle or -> <text cut to 80>`.

- [ ] **Step 1: Write the failing tests** — argument parsing for each subcommand (`--to` repeatable, `--stdin` exclusive with TEXT, `--last` positive), `replyOutsideASessionFails`, request building (cmd, args, target) for each, `humanReadLine`, `eventHumanLineCarriesKindSenderAndText`.
- [ ] **Step 2: Run** `swift test --filter AssistantCommandsTests` — expect FAIL.
- [ ] **Step 3: Implement** following `MessageCommands.swift`'s structure (`emit`, `refused`, `--json` prints the server line unchanged).
- [ ] **Step 4: Run** the suite, then `swift test` for the whole package — expect PASS; `git checkout Package.resolved`.
- [ ] **Step 5: Commit** `feat(assistant): elisctl assistant and reply`.

---

## After this plan

- Plan 2 (Linux host) is written once the Linux phase 1 and ElisBridge branches are on master, since they rewrite
  `sidebar.cpp`, `mainwindow.cpp` and `commands.cpp`: bridge functions in `ElisBridge/Chat.swift`, C++ commands and
  `elisctl` over them, the provider `QProcess`, the pinned row, chat view, composer, the remote reply route,
  user docs (`site/docs.html`, `site/commands.html`), the skill and `.claude/rules/control-api.md`'s catalog.
- Plan 3 (Mac host) over the same contract.
