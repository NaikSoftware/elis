#!/bin/bash
# A provider for tests, builtins only so a killed one leaves no child behind. Each input is one turn answering
# "pid <pid>: <text>", with " early" when the next line arrived before that turn's result and " leaked" when the host
# passed ELIS_SESSION_ID or CLAUDECODE on. The inputs "env", "fail", "crash" and "quiet" answer ELIS_STATE_DIR and PATH,
# end the turn with an error, die, and end it with no text. Asked to resume the conversation "gone", it exits at once as
# a provider does whose conversation is gone. Run as `codex exec …` it answers its last argument in codex's shape;
# else claude's.
leaked=
[[ -n $ELIS_SESSION_ID$CLAUDECODE ]] && leaked=' leaked'
prev=
for arg; do
    [[ $prev == --resume && $arg == gone ]] && { echo 'No conversation found with session ID: gone' >&2; exit 1; }
    prev=$arg
done
answer() { # the text to answer, JSON-escaped, or "" for an error turn
    quiet=
    case $1 in
    env) text="$ELIS_STATE_DIR $PATH" ;;
    fail) text= ;;
    crash) kill -9 $$ ;;
    quiet) text= quiet=1 ;;
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
init= next= wait=0.3
((BASH_VERSINFO[0] < 4)) && wait=1 # bash 3.2 (macOS) rejects a fractional read timeout
while if [[ -n $next ]]; then line=$next next=; else IFS= read -r line; fi; do
    [[ -z $init ]] && init=1 && printf '{"type":"system","subtype":"init","session_id":"fake-%s"}\n' $$
    [[ $line =~ $re ]] && input=${BASH_REMATCH[1]} || input=
    early=
    if IFS= read -r -t "$wait" next; then early=' early'; else next=; fi
    answer "$input" "$early"
    if [[ -n $quiet ]]; then
        printf '{"type":"result","subtype":"success","is_error":false,"session_id":"fake-%s"}\n' $$
        continue
    fi
    if [[ -z $text ]]; then
        printf '{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["boom"]}\n'
        continue
    fi
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$text"
    printf '{"type":"result","subtype":"success","is_error":false,"session_id":"fake-%s"}\n' $$
done
