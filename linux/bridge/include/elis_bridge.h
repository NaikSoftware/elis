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
void elis_free(char *result);

// Live panes on zmx (bridge Sources/ElisBridge/Zmx.swift documents each shape).
char *elis_zmx_names(const char *json);       // pane ids -> daemon names and the socket dir
char *elis_zmx_attach(const char *json);      // a pane's attach argv and environment; begins its lead state
char *elis_zmx_list(const char *output);      // zmx list's stdout, parsed
char *elis_zmx_reap(const char *json);        // the names a launch kills, null when no reap is safe
char *elis_zmx_lead_report(const char *json); // a pane's title as a role report
char *elis_zmx_lead_state(const char *pane);
void elis_zmx_lead_forget(const char *pane);
char *elis_zmx_surface(const char *json);     // one tree surfaces[] entry
char *elis_zmx_type_bytes(const char *text);  // session.type text as zmx type input, its final Return paced
char *elis_zmx_screen(const char *output, int lines); // zmx screen's reply as text; lines > 0 keeps the last ones

#ifdef __cplusplus
}
#endif
