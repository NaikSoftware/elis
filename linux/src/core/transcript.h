#pragma once

#include <QJsonObject>
#include <QString>

#include <optional>

// session.transcript's seam to the transcript reader. The reader is ElisCore's ClaudeTranscript (Swift, shared with the
// Mac); the spec docs/superpowers/specs/2026-11-20-phone-chat-mode-design.md owns the page shape.

constexpr int transcriptPageBudget = 49152;

// ClaudeHome.directory: configDir (CLAUDE_CONFIG_DIR) when it is absolute, else <home>/.claude
QString claudeHome(const QString &configDir, const QString &home);

struct TranscriptRequest {
    QString sessionId; // the Claude conversation id from the tree, never a path
    std::optional<qint64> after, before;
    std::optional<QString> held; // the id the caller holds; only compared
    int maxBytes = transcriptPageBudget;
};

// One page of <claudeDirectory>/projects/*/<id>.jsonl as the whole reply: {ok, result} or {ok: false, error}.
QJsonObject transcriptPage(const QString &claudeDirectory, const TranscriptRequest &request);
