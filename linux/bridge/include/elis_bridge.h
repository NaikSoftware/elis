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
// agent is "claude" or "antigravity"; dir and sessionID are that agent's directory and conversation.
char *elis_transcript_read(const char *argsJSON, const char *agent, const char *dir, const char *sessionID, const char *pane);
// session.upload for a local row: {"ok":true,"result":{"upload":{"path":…}}} with a reserved file under
// <stateDir>/uploads/<sessionID>/, or the Mac's refusal. argsJSON is the request's args ({"name","size"}).
char *elis_upload_reserve(const char *stateDir, const char *sessionID, const char *argsJSON);
// Removes upload folders no id in keepJSON (an array of session ids) names, and files older than a week; "null" keeps every folder.
void elis_upload_sweep(const char *stateDir, const char *keepJSON);
// sidebar.density's mode against the current density: {"ok":true,"density":"default|compact"} or the Mac's refusal.
// Input {"mode"?,"current"}; an absent mode toggles.
char *elis_sidebar_density(const char *json);
// A row tint by the Mac's parse: command session.tint/workspace.tint takes {"mode","tint"?,"tintOn"?}, any other a new's
// {"tint"?,"tintOn"?}. {"ok":true,"tint"?} is the normalized tint the row gets (absent: none), else the Mac's refusal.
char *elis_tint_parse(const char *command, const char *argsJSON);
// {"colors":[{"name","light","dark"}],"shownParts":[…]}: the palette in menu order as #rrggbb per appearance, and the
// tree's tintOn.
char *elis_tint_palette(void);
// session.move's placement intent: {"ok":true} with "to", "workspace", or "anchor" and "after"; else the Mac's refusal.
char *elis_session_move_arguments(const char *argsJSON);
// Where session.move --after/--before lands by the Mac's drop math (bridge Sources/ElisBridge/Moves.swift has the shape).
char *elis_session_placement(const char *json);
// {"to","index","count"} -> {"ok":true,"destination"?}: a --to step, absent at that end.
char *elis_reorder_destination(const char *json);
// A project folder normalized, {"ok":true,"folder"}, or the Mac's refusal; existence is not checked.
char *elis_project_folder(const char *path);
// Each cwd's GitHub CI from gh, in order: [{"ci"?:{branch,sha,pr?,runs},"spans":[{text,bold,italic,code,dim,color?}]}],
// "ci" absent for none. Input a JSON array of cwds. Blocks on gh, so call it off the GUI thread, one call at a time.
char *elis_ci_statuses(const char *cwdsJSON);
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

// The assistant chat (bridge Sources/ElisBridge/Chat.swift), all on the process main thread; no pointer is ever NULL.
// Until open, the chat lives in memory only. peersJSON is [{sessionID,window,workspaceID,workspaceName,name,agent?,
// status?}] and providersJSON ["claude",…], or the JSON text null when the host cannot list them; anything else that
// does not decode is refused ("invalid peers", "invalid providers").
char *elis_assistant_open(const char *stateDir); // {}; <stateDir>/assistant/chat.jsonl, the same path again a no-op
// requestJSON is an assistant.* request. {"reply":<response>,"effects":[effect]}, or
// {"plan":{targets,line,body,cut,skipped,skippedIDs,handles}} for the host to type and pass to finish_send. An effect is
// {"type":"input","entry","streamText"}, {"type":"sent","entry"}, {"type":"providerChanged","provider"}, {"type":"seen"},
// {"type":"cleared"} (the host stops its provider) or {"type":"show","window"?}; the host performs a show and calls
// elis_assistant_mark_seen only when it succeeded.
// A refusal is {"reply":{"ok":false,"error"},"effects":[]}.
char *elis_assistant_run(const char *requestJSON, const char *peersJSON, const char *providersJSON);
// A typed plan's outcome, failuresJSON {sessionID: typing error}: {"reply","effects"} as run's.
char *elis_assistant_finish_send(const char *planJSON, const char *failuresJSON);
// The host's tree with workspace and session "handle", session "assistantMark" and top-level "assistant" added; every
// other key is kept. Null peers leave the tree as it is; a bad tree, peers or providers is {"error"}.
char *elis_assistant_stamp(const char *treeJSON, const char *peersJSON, const char *providersJSON);
void elis_assistant_turn_ended(void);
char *elis_assistant_turn_failed(const char *message); // the error entry it stores; ends that turn only
char *elis_assistant_provider_failed(const char *message); // the error entry it stores; drops every queued input
void elis_assistant_mark_seen(void);
char *elis_assistant_append_assistant(const char *text); // the assistant entry it stores
// {"argv":[…],"mode":"stream|perInput","environment":{…},"preamble"?} for provider, its system prompt listing peersJSON
// and resuming its stored conversation. A perInput provider's argv is empty. A provider is one the picker offers
// (never terminal); any other name, here and below, is {"error"}, and encode's "".
char *elis_assistant_launch(const char *provider, const char *peersJSON);
// A perInput provider's argv for one input, the system prompt prepended while no conversation is stored; [] for a
// stream provider.
char *elis_assistant_turn_argv(const char *provider, const char *input, const char *peersJSON);
char *elis_assistant_encode(const char *provider, const char *text); // one NDJSON input line, not JSON-quoted; "" for none
// One provider stdout line as [{"text"}|{"conversation"}|{"turnEnded":true,"error"?}]; a conversation is stored as the
// provider's resume id.
char *elis_assistant_decode(const char *provider, const char *line);
// plain text: the last 50 entries, less the inputs still queued, for a newly started provider's first input
char *elis_assistant_recap(void);
// the conversation a launch of provider resumes, "" for none; forget drops it, so the next launch starts afresh
char *elis_assistant_resume(const char *provider);
void elis_assistant_forget_resume(const char *provider);
// session.attach and the phone relay's lines (Sources/ElisBridge/Attach.swift)
char *elis_zmx_build_cutoff(const char *json); // records this zmx build in the state dir; when it first ran there
char *elis_session_attach(const char *json);   // a Live pane's viewer or claiming attach
char *elis_phone_relay_line(const char *line); // one relay stderr line, viewer and lead lines counted
char *elis_phone_viewers_reset(void);          // the relay stopped: what every count held
char *elis_phone_viewers(const char *paneID);  // a pane's viewer count and lead

// phone.* (Sources/ElisBridge/Phone.swift)
char *elis_phone_request(const char *requestJSON); // {cmd,target?,args?} checked: {"ok":true,"op",mode?|port?|host?}
char *elis_phone_link_with_host(const char *link, const char *host, int port); // the Mac's PhonePairLink.withHost

// Page overlays (Sources/ElisBridge/Pages.swift has the page shape: source and flags).
char *elis_overlay_page_arguments(const char *argsJSON); // {"ok":true,"page":source|null} or the Mac's refusal
char *elis_html_navigation_decide(const char *json);     // {source,flags,action:{url,target,userActivated}} -> {"decision"}
char *elis_html_identity(const char *json);              // {source,flags,page?} -> {"identity"}
char *elis_html_theme_script(const char *json);          // {background,foreground,dark,palette?,themed} -> {"script"}
char *elis_html_zoom(const char *json);                  // {action,zoom} -> {"zoom"}, null for a non-font action
// Outcomes, on the process main thread only: register a pending page, answer it once, read result --page's reply.
char *elis_page_outcome_register(void); // {"pageID"}
char *elis_page_outcome_submit(const char *pageID, const char *value); // {"ok"}: false when it was not pending
void elis_page_outcome_dismiss(const char *pageID);
char *elis_page_outcome_result(const char *pageID);
// The saved browser store and browser.* (Sources/ElisBridge/Browser.swift)
char *elis_browser_profile(const char *json); // {directory} -> {"ok":true,"id"}, created when missing, or {"ok":false,"error"}
char *elis_browser_clear(const char *json);   // {target?,window?,directory,openPages} -> {"ok":true,"id"|null} or the Mac's refusal
char *elis_browser_links(const char *json);   // {target?,window?,mode?,current} -> {"ok":true,"mode"} or the Mac's refusal
// Markdown, image, text and document pages (Sources/ElisBridge/PageContent.swift); any thread
char *elis_page_open_check(const char *json);          // {source,navigation?,log?} -> {ok,navigation,links?,pixels?,language?,diff} or refusal
char *elis_markdown_assets(const char *directory);     // {script,style,textScript,textStyle}
char *elis_markdown_page(const char *json);            // {path,links?,style} -> {"html"} | {"error"}
char *elis_markdown_linked_document(const char *json); // {path,links:{path,root}} -> {"path"?}
char *elis_image_page(const char *json);               // {path} -> {"html"} | {"error"}
char *elis_image_points(const char *json);             // {width,height,scale,zoom,bounds?} -> {width,height,percent}
char *elis_document_page(const char *json);            // {path} -> {"html"} | {"error"}
char *elis_text_load(const char *json);                // {path} -> {"text"} | {"error"}
char *elis_text_page(const char *json);                // {text,path,line?,style,log?,anchor?,search?,change?,entered?,file?,wrap?} -> {"html"}
char *elis_text_log_read(const char *json);            // {path,tail,stamp?} -> {unchanged} | {stamp,snapshot?} | {error}
char *elis_text_log_shift(const char *json);           // {old?,oldStamp?,new?,newStamp?} -> {dropped,cut,replaced}
char *elis_overlay_text_action(const char *json);      // {cmd,args} -> {"ok":true,"action"} or the Mac's refusal
char *elis_text_page_constants(void);                  // {maxQuery, the text-page refusal texts}
char *elis_page_navigate_refusal(const char *json);    // {kind,to} -> {"error"?}
// session progress (Sources/ElisBridge/Progress.swift); every result is JSON freed with elis_free
char *elis_progress_parse(const char *text);    // 3/7, 40%, indeterminate, clear: {"ok":true,"progress":{…}|null} or {"ok":false,"error"}
char *elis_progress_terminal(const char *body); // OSC 9 body "4;1;40": {"update":"clear"|"set","progress"?} or null
char *elis_progress_row(const char *json);      // {"progress"?,"status","sessionTint"?,"workspaceTint"?,"active"}: {"fill":{color,fraction,alpha}|null,"wave":bool}

#ifdef __cplusplus
}
#endif
