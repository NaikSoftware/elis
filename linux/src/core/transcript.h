#pragma once

#include <QJsonObject>
#include <QString>

// session.transcript through ElisBridge (linux/bridge): ElisCore's own argument check and reader, shared with the Mac.
// The spec docs/superpowers/specs/2026-11-20-phone-chat-mode-design.md owns the page shape.

// ClaudeHome.directory: configDir (CLAUDE_CONFIG_DIR) when it is absolute, else <home>/.claude
QString claudeHome(const QString &configDir, const QString &home);

// The Mac's argument check: {"ok":true,"result":{"pane":…}} with the pane asked for (absent: the agent's pane), or
// its refusal.
QJsonObject transcriptArguments(const QJsonObject &args);

// One page of the Claude session sessionId under claudeDirectory as the Mac's whole reply. Blocks on file reads, and
// ElisCore traps when it runs on the process's main thread: call it from a worker.
QJsonObject transcriptPage(const QJsonObject &args, const QString &claudeDirectory, const QString &sessionId, const QString &pane);
