# Phone Chat attachments

Date: 2026-11-24. Status: approved by the owner (decisions below). Tracking: Linear NAI-24.
Supersedes `2026-11-20-phone-camera-upload-design.md`. In this design arbitrary files are in scope, the phone writes
the prompt (the host never pastes), and channel credit paces the upload bytes, not the relay's scheduler.

## Intent

In the phone's Chat view the user picks files or photos, sees them as chips above the input, and sends them with a
prompt. The files land on the host that runs the session. The prompt names their absolute host paths, so the agent
reads them with its own file tools.

## Scope

- Chat view only, which today means claude and agy rows (`chatAgents`). The Term view gets no attach control.
- Any file type from the Android system picker, documents and photos alike. No camera capture, no image downscaling.
- Every host: the Mac app, the Linux Qt app, a row attached from another Mac, and a row in an elis-server window.
- LAN and Bluetooth links.

## Owner decisions (2026-11-24)

1. **Size cap.** 20 MiB per file (20 971 520 bytes), the same on every link, and at most 10 files per message.
2. **Retention.** A session's uploads last as long as the session.
   - At its next launch, each host removes every upload folder whose session is not open, not in a saved window and
     not in Recent Closed.
   - It also removes files older than 7 days in every folder.
   - A Recent Closed reopen keeps the session id, so a plain close deletes nothing.
3. **Rows attached from another Mac.** This work verifies Chat Send on those rows and lifts its `checks.attached` gate.
   Attachments then work there the same as everywhere else.

## Design

**Prompt.** The phone sends one line: the user's text, then ` Attached: '<path1>' '<path2>'`. With no text, the line
starts with `Attached:`. This format is deliberate:
- A paste is never a bare path. Claude can turn a lone image path into `[Image #N]`.
- It stays on one line, because TypeWriter refuses newlines.
- The single quotes cover the space in `Application Support`.

Host file names are reduced to `[A-Za-z0-9._-]`, so a quote never appears inside a path.

**Phone.**
- An attach button in the Chat composer opens the picker with multiple selection.
- Each pick becomes a chip with its name and size, and × removes it.
- Send uploads the chips one at a time, each chip showing its progress, then sends the prompt through the existing
  write gate.
- Once a chip is uploaded it keeps its host path, so a retry after a failure does not upload it again.
- The field and the chips clear only after the prompt is sent.
- The attach button is always visible. It is disabled when sending is blocked, when the link has no mux, or when the
  relay is too old to take files.

**Wire.**
- The phone opens a mux channel with OPEN `{type: "upload", target, name, size}`.
- The relay accepts with OPENED, or refuses with OPENED `{error}`.
- The phone streams DATA under a 16 KiB credit window.
- The relay ends the channel with CLOSE `{reason: "uploaded", path}` once `size` bytes are on disk, or with
  CLOSE `{reason: <error>}`.
- The mux has no half-close, so the byte count decides completion.
- A phone link carries one upload at a time.

**Host command.** `session.upload {target, name, size}` reserves a destination and writes nothing.
- A local row answers `upload.path`, set to `<stateDir>/uploads/<sessionID>/<yyyyMMdd-HHmmss>-<name>` and made unique.
- A remote row answers `upload.host` and `upload.session`: its origin host and the origin's session id.
- The command changes no model state, so it has no tree read-back. The written file is the result.

**Relay.** It first asks the app `session.upload`, then writes the bytes.
- **Local row.** It writes `<path>.part` and renames it after the last byte.
- **Remote row.** It runs `ssh -T <host> elisctl session upload --target <session> --name <name> --size <n>` and pipes
  the bytes to its stdin. The far `elisctl` reserves the path on its own app, writes the file the same way, and prints
  one JSON line.
- A cancel, a lost link or a short stream removes the `.part` file.

**`elisctl session upload`.** It reads exactly `--size` bytes from stdin into the reserved path. It always prints one
JSON line: `{"ok":true,"result":{"upload":{"path":…}}}` or an error. Scripts and the relay both reach a host this way.

## Refusals (exact copy)

| Case | Text |
| --- | --- |
| Over the cap | `file too large (max 20 MiB)` |
| A second upload on the same link | `an upload is already running` |
| A page row, or an unknown target | the existing page refusal, or the existing resolve error |
| A host without `session.upload`, or a relay that answers `unsupported channel type` | the phone shows `Update Elis on the computer to attach files` |

## Known limits

- Phone-to-host Bluetooth throughput is unmeasured, and a 20 MiB file may take many minutes over Bluetooth. The chip
  shows progress.
- Claude may ask permission to read a file outside its working folders. That prompt has no card and opens the panel.
- The transcript shows the sent prompt as text, paths included. The message bubble gets no attachment chips in this
  work.
- A bare ssh `elisctl` resolves the far host's default state dir, as every remote command does.
