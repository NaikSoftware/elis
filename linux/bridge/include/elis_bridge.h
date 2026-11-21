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
// sidebar.density's mode against the current density: {"ok":true,"density":"default|compact"} or the Mac's refusal.
// Input {"mode"?,"current"}; an absent mode toggles.
char *elis_sidebar_density(const char *json);
// A row tint by the Mac's parse: command session.tint/workspace.tint takes {"mode","tint"?,"tintOn"?}, any other a new's
// {"tint"?,"tintOn"?}. {"ok":true,"tint"?} is the normalized tint the row gets (absent: none), else the Mac's refusal.
char *elis_tint_parse(const char *command, const char *argsJSON);
// {"colors":[{"name","light","dark"}],"shownParts":[…]}: the palette in menu order as #rrggbb per appearance, and the
// tree's tintOn.
char *elis_tint_palette(void);
void elis_free(char *result);

#ifdef __cplusplus
}
#endif
