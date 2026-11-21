#pragma once

// ElisBridge (linux/bridge): ElisCore's Swift code behind a C ABI. Every call takes and returns UTF-8 JSON, and the
// caller frees each result with elis_free.
#ifdef __cplusplus
extern "C" {
#endif

// session.transcript's argument check, before the host resolves the target: {"ok":true,"result":{"pane":…}} with the
// pane asked for (absent: the agent's pane), or the Mac's refusal.
char *elis_transcript_arguments(const char *argsJSON);
// One session.transcript page as the Mac's whole reply. Blocks on file reads, and traps on the process main thread.
char *elis_transcript_read(const char *argsJSON, const char *claudeDir, const char *sessionID, const char *pane);
void elis_free(char *result);

#ifdef __cplusplus
}
#endif
