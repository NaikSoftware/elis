#!/bin/bash
# A provider for tests, builtins only so a killed one leaves no child behind. Each input is one turn answering
# "pid <pid>: <text>", with " early" when the next line arrived before that turn's result and " leaked" when the host
# passed ELIS_SESSION_ID or CLAUDECODE on. The inputs "env", "fail" and "crash" answer ELIS_STATE_DIR and PATH, end
# the turn with an error, and die. Run as `codex exec …` it answers its last argument in codex's shape; else claude's.
leaked=
[[ -n $ELIS_SESSION_ID$CLAUDECODE ]] && leaked=' leaked'
answer() { # the text to answer, JSON-escaped, or "" for an error turn
    case $1 in
    env) text="$ELIS_STATE_DIR $PATH" ;;
    fail) text= ;;
    crash) kill -9 $$ ;;
    *) text="pid $$: $1$2$leaked" ;;
    esac
}
if [[ $1 == exec ]]; then
    input=${!#}
    input=${input//\\/\\\\} input=${input//\"/\\\"} input=${input//$'\n'/\\n}
    answer "$input"
    printf '{"type":"thread.started","thread_id":"fake-%s"}\n' $$
    printf '{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"%s"}}\n' "$text"
    printf '{"type":"turn.completed"}\n'
    exit
fi
re='"text":"(([^"\\]|\\.)*)"'
init= next=
while if [[ -n $next ]]; then line=$next next=; else IFS= read -r line; fi; do
    [[ -z $init ]] && init=1 && printf '{"type":"system","subtype":"init","session_id":"fake-%s"}\n' $$
    [[ $line =~ $re ]] && input=${BASH_REMATCH[1]} || input=
    early=
    if IFS= read -r -t 0.3 next; then early=' early'; else next=; fi
    answer "$input" "$early"
    if [[ -z $text ]]; then
        printf '{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["boom"]}\n'
        continue
    fi
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$text"
    printf '{"type":"result","subtype":"success","is_error":false,"session_id":"fake-%s"}\n' $$
done
