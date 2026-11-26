# Phone Chat attachments: images as a real paste

Follow-up to `2026-11-24-phone-chat-attachments-design.md`. Approved by the owner on 2026-11-26.

## Intent

An image attached in phone Chat reaches Claude as an image attachment (`[Image #N]`), the same as a desktop Ctrl+V,
not as a host path that Claude must open with `Read`.

## Findings

- Claude Code 2.1.329 turns a bracketed paste that holds only image paths into `[Image #N]`s, one per path.
  Bare, `\ `-escaped and single-quoted paths with a space all work; `'p1' 'p2'` gives two images.
  A paste that also holds other text stays text, so today's `<text> Attached: '<p>'` line never attaches.
- Chat already renders transcript image items, so the sent bubble shows the picture.
- The path is a host path and the paste goes to that session's pty, so every host (Mac, Linux, elis-server, remote rows) behaves the same.

## Design

- Images (`png`, `jpg`, `jpeg`, `gif`, `webp`), Claude only: the text line is pasted first, as today but without the images.
  Then one paste holds the images' quoted host paths, `'<p1>' '<p2>'`, then Enter.
  The gate waits until the input shows one `[Image #` per image.
- Other files stay in the text line as `Attached: '<path>'`; Claude Code attaches no other file type on the desktop either.
- A line that starts with `/`, `!` or `#` keeps today's single line with every path, because an image there would split a
  command or a shell or memory entry.
- Antigravity keeps today's line until its handling of a pasted path is checked.
- The typed path (`session.type`, no live terminal) sends the same paste wrapped in `ESC[200~ … ESC[201~`;
  Claude Code always enables bracketed paste.

## Approaches

1. Bracketed paste of the path (chosen): works on every host, touches no clipboard, phone-only change.
2. Host clipboard plus Ctrl+V (rejected): overwrites the Mac clipboard, has no clipboard on headless Linux or elis-server,
   races with the user, images only.

## Composer UI (owner's pick B4, 2026-11-26)

The owner rejected the separate paperclip and the floating mode chip.

- One `Icons.add` icon button inside the field, on the left (the shared `Composer` gets a `prefix` slot; Term passes none).
  No label: the current mode shows only as the checked row in the menu.
- It opens ModeChip's existing bottom sheet with "Attach files" on top, a divider, a `PERMISSION MODE` header,
  the mode rows unchanged, then the "N shells" line when shells > 0.
  Rows disable by their own rules: Attach by the attach rules, mode rows by ModeChip's; the icon is disabled only
  when every row is. For agy the sheet holds Attach alone.
- Attachments are 64x64 tiles above the field, aligned with its left edge: an image shows its thumbnail, another file
  a document icon with name and size; a × badge removes it; while uploading, the tile is veiled with a progress ring.
- No separate paperclip, mode chip or mode line remains.

## Non-goals

No change to upload, relay, hosts, limits or retention.
