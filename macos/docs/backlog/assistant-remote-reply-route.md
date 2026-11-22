---
worth: yes
where: shared/ElisCore/Sources/ElisCore/ControlDispatcher+Assistant.swift, elis-server ServerCommandPolicy
added: 2026-11-22
---
# Elis assistant has no path to remote sessions

elis-server refuses every `assistant.*` command, so `elisctl reply` inside a session the server runs fails. Elis cannot
type into a remote row either: its peers are the local sessions only.

The owner approved shipping the Linux assistant without this (2026-11-22). The route is built with the first host that
shows remote rows, the Mac (plan 3):
- the server forwards `assistant.reply` to the presenting host's chat;
- the host resolves remote rows as peers and types into them through the existing remote `session.type` path.
