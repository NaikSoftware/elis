# Elis assistant: a chat that drives sessions

Status: draft for the owner's approval. Mockup: variant B of the "Системна сесія Elis" canvas.

## Intent

The owner runs many agent sessions across workspaces and wants one place to talk to all of them.
Elis gets a system session, itself named **Elis**: a chat with an AI provider the user picks
(Claude Code, Codex, Antigravity, OpenCode), which already knows `elisctl` and can message sessions,
drive them, and collect their answers in one thread.

## Goals

- A pinned **Elis** row above the workspaces, with the app's dog icon and an unread count of agent replies.
  Selecting it shows the chat in the main area; the terminals stay mounted underneath.
- The composer tags targets: `@<handle>` for a session, `@ws:<handle>` for a workspace's agent sessions,
  `@all` for every agent session. Tags come from `@` completion or from dragging a sidebar row
  (session or workspace header) onto the composer.
- A provider picker inside the composer lists the agents detected on the system; the choice persists
  and applies from the next message.
- A message to a session is typed into it at once, as one line ending in the reply instruction.
- An agent answers with `elisctl reply "…"`; the answer appears in the chat as a card from that session
  and goes into the live assistant stream at once, so Elis can act on it.
- Everything the chat does is reachable over the control API, so an agent, a script or the phone can drive it.

## Non-goals

- No mailbox, queue or wait for an agent to go idle: the owner chose immediate typing.
- Not a general agent runtime: the provider CLI does the thinking and tool use; Elis only runs it and shows it.
- No editing of handles in v1; they are derived from names.
- No chat inside other sessions' terminals beyond the one typed line.

## Anti-goals

- Typing into a plain shell. A line typed into a shell runs as a command, so group tags (`@ws:`, `@all`)
  expand only to sessions whose foreground is an agent. An explicit `@handle` the user chose is typed as asked.
- A multi-line message. `session.type` submits on every newline, so the payload is one line; newlines
  in the text are folded to spaces before typing.

## Constraints

- Shared logic goes in `ElisCore` (Swift), reached from Linux through the bridge as JSON-in/out `@_cdecl`
  functions in their own file (`ElisBridge/Chat.swift`), declared in `elis_bridge.h`.
  C++ keeps only Qt, the socket and processes. `ControlDispatcher` helpers the bridge calls are `nonisolated`.
- Order: `ElisCore` first, in new files (the in-flight move of `macos/ElisCore` to `shared/ElisCore` carries
  them by rename). Linux UI after the Linux phase 1 merge, which rewrites `sidebar.cpp`, `mainwindow.cpp`
  and `commands.cpp`. Mac UI after that, on a Mac.
- Control API contract (`.claude/rules/control-api.md`): protocol types, dispatcher, CLI, tree read-back,
  events with human lines, tests, and the bundled skill (`plugins/elis/skills/elis/`) in the same change.

## Approaches

Three layouts were drawn: A, a chat docked right of the terminal; B, a pinned system session in the sidebar;
C, a floating quick panel. The owner picked **B**: the assistant is a session-like place with its own address,
it shows on every surface that already shows sessions, and it does not take width from a terminal.

Delivery: a mailbox (`msg send`) plus a hook was rejected because nothing pushes mail to a running agent;
waiting for idle was rejected by the owner. Messages are typed immediately.

## Design

### Handles

`ElisCore` `SessionHandle` derives a short Latin handle from a session or workspace display name:
transliterate Cyrillic (Ukrainian national table, own map, no ICU dependency on Linux), lowercase,
split on non-alphanumerics, drop stopwords (`за`, `і`, `та`, `the`, `a`, `of`, …), keep the first two words,
shorten a word over six characters to four, join with `-`, cap at 12 characters, `[a-z0-9-]` only.
A collision within the window gets `-2`, `-3` in sidebar order. Example: «Міграція Linux-версії за планом»
→ `mihr-linux`. Handles are derived on demand, never persisted; tree session and workspace nodes report `handle`.
The exact shortening rule is the builder's within these limits.

### Targets

`ElisCore` `AssistantTargets.resolve(tags, tree)` expands tags to session ids:
`@handle` → that session; `@ws:handle` → its sessions with a detected agent; `@all` → every session with a
detected agent. Unknown tags are errors naming the tag. Duplicates collapse.
A session whose status is `blocked` is never typed into (owner's choice): Enter could answer its permission
prompt or picker. Groups skip it, an explicit tag to it fails, and the reply lists it under `skipped`, which
the chat shows as "not delivered: waiting for your approval". Nothing is queued for later.

### Message line

`ElisCore` `AssistantMessage.line(text, from:)` builds the typed line:
`[Elis] <text> — reply: elisctl reply "<answer>"`. Newlines and control characters fold to spaces; the line is
capped so the terminal input limit is never hit; NUL is refused (as `session.type` does).
Typing goes through the existing `session.type` path, so its submit gap applies.

### The chat engine

Every composer message goes to the model (owner's choice); tags tell it whom the message is about, and it
acts through `elisctl`: `assistant send` to message sessions (verbatim when that is what was asked),
and the rest of the API to drive them.

The Elis session is a **live stream**, not a process per message (owner's requirement): the provider runs
as one long-lived process in `<stateDir>/assistant/`, and every input, from the user or from another agent,
is written into it as a new message. `ElisCore` `AssistantProvider` owns each provider's streaming argv and
message framing, built on `SessionLauncher`: `claude -p --input-format stream-json --output-format stream-json`,
Codex's app-server protocol, OpenCode's server, Antigravity's equivalent. The builder verifies each against the
installed version; a provider with no streaming mode is driven by resuming its conversation per input, which
keeps the same stream semantics for the user and for other agents.
The process starts when the row is first used, restarts with the conversation resumed when it dies,
and stops on app quit. Switching provider stops the old one and starts the new one with the chat inlined.
Inputs that arrive during a turn queue in the stream in arrival order; output streams into the chat.

The system prompt: what Elis is, the `elisctl` skill pointer, the handle table (handle, session id, workspace,
agent, status), that agent replies arrive as messages marked with their sender, and that a reply is not a
request to message that agent again unless the user asked.

Permissions: the provider may run `elisctl` and nothing else (Claude `--allowedTools "Bash(elisctl:*)"`,
the matching sandbox or approval policy for the others), so the assistant cannot touch the user's files;
the working directory is pre-trusted so no folder-trust prompt can stall it. The builder picks the flags.

### Transcript and persistence

`<stateDir>/assistant/chat.jsonl`, one JSON object per message
(`kind`: `user`, `assistant`, `sent`, `reply`, `error`; `from`, `to`, `text`, `ts`), trimmed to the last 500.
The provider choice and each provider's resume id persist beside it.

### Scope of one chat

One Elis chat per app (per state directory), shared by every window: each sidebar shows the same row and
unread count. Handles are unique across the app's windows, and targets resolve across them.
The Elis row is not a `Session`: it has no pty and is absent from session nodes, `session.go`, MRU, recent
closed and session search; the palette gets one "Show Elis" action. Tree carries it as top-level `assistant`.

### Replies

`assistant.reply` accepts any session's `ELIS_SESSION_ID`, asked or not; each reply is a card and a stream
input. A sent-to session shows a dot until the user's next message starts a new exchange: waiting, then
replied, or not delivered. The dots clear when that next message is sent, so none outlives its exchange.

### UI (both platforms)

- Sidebar: the Elis row is pinned above workspaces in every sidebar mode, not movable, closable or renamable.
  Unread count = replies since the chat was last shown.
- Main area: centered chat column; a reply card per answering session with a "go to session" link.
- Right rail: who is in the conversation, with status and agent.
- Composer: tag chips, `@` completion (sessions, `@ws:`, `@all`), drop target for sidebar rows,
  provider picker listing detected agents by name only, send button.

### Control API

- `assistant.ask TEXT` — post a user message into the stream, as the composer does; `--wait` blocks until
  the turn it starts ends.
- `assistant.send --to TAG… TEXT` — type the message line into the resolved sessions; replies `affected` ids.
- `assistant.reply TEXT` — from a session (`ELIS_SESSION_ID`); appends a reply card. CLI: `elisctl reply`.
- `assistant.read [--last N]` — the transcript.
- `assistant.provider [NAME]` — read or set the provider.
- `assistant.show` — select the Elis row.
- Tree top level: `assistant {provider, providers, running, unread}`; nodes: `handle`.
- Events: `assistant.message` with kind and sender, in `EventFormatter.human`.

### Remote and phone

A remote row is a target like any other: `assistant.send` types through the row's existing remote typing path.
Its agent's `elisctl reply` reaches the origin's socket, not the viewing Mac, so the origin must forward the
reply to the presenting Mac; that path is designed in the Mac phase and needs the owner's decision if any part
is left out. The phone shows the Elis row and chat in a later phase.

### Delivery order

1. `ElisCore`: handles, targets, message line, provider argv and framing, protocol and dispatcher, tests.
2. Linux, once the Linux phase 1 and the ElisBridge branch are on master: bridge functions, commands,
   provider process, sidebar row, chat view, composer.
3. Mac, on a Mac: SwiftUI row and chat, the provider process, and the remote reply route.

## Tests

- ElisCore: handles (Cyrillic, mixed, collisions, caps), target expansion (agent-only groups, unknown tag),
  message line (newline folding, caps, NUL), provider argv and resume, dispatcher round trips.
- Linux: `test_core` for the commands and transcript; `test_ui` for the pinned row, selection and composer drop.

## Left to the builder

Exact shortening rule, stopword list, line cap, how the provider stream is parsed per provider, widget structure.
