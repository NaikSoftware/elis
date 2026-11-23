---
worth: yes
where: macos/Elis/SessionLaunchers.swift, ControlServer.buildTree, linux MainWindow::chromeState, elis-server catalog
added: 2026-11-23
---
# A remote window offers the viewing computer's agents

The workspace "+" menu and `tree.launchers`, which the phone's New session reads, list the agents on the PATH of the
computer showing the window. In a remote window the session starts on the host, where the launcher types `claude`,
`codex` and so on into the host's shell.
An agent installed only here is offered and ends in `command not found`; one installed only on the host is never offered.

The owner chose to ship the phone list matching the "+" menu (2026-11-23, #96) and fix both together:
- elis-server and an origin Mac detect their own launchers (`SessionLauncher.available`) and publish them in the catalog;
- a remote window's "+" menu and `tree.launchers` use that list, local windows keep the local one;
- tests on the catalog round-trip and on which list a remote window reports.
