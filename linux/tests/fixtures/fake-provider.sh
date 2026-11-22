#!/bin/bash
# claude's stream-json for tests: each input line is one turn answering "pid <pid>: <text>", with " early" when the next
# line arrived before that turn's result and " leaked" when the host passed ELIS_SESSION_ID or CLAUDECODE on.
# Builtins only, so a killed provider leaves no child behind.
re='"text":"(([^"\\]|\\.)*)"'
init= next= leaked=
[[ -n $ELIS_SESSION_ID$CLAUDECODE ]] && leaked=' leaked'
while if [[ -n $next ]]; then line=$next next=; else IFS= read -r line; fi; do
    [[ -z $init ]] && init=1 && printf '{"type":"system","subtype":"init","session_id":"fake-%s"}\n' $$
    [[ $line =~ $re ]] && text=${BASH_REMATCH[1]} || text=
    early=
    if IFS= read -r -t 0.3 next; then early=' early'; else next=; fi
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"pid %s: %s%s%s"}]}}\n' $$ "$text" "$early" "$leaked"
    printf '{"type":"result","subtype":"success","is_error":false,"session_id":"fake-%s"}\n' $$
done
