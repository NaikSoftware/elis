#!/usr/bin/env bash
# Antigravity CLI (agy) lifecycle hook installed by elis through the elis-status agy plugin.
#
# It prints nothing: agy (1.5.15) denies a tool whose PreToolUse prints `{}`, and "allow" would
# auto-approve it, while an empty stdout leaves agy's own permission flow alone.
# agy has no hook for its own command-approval prompt, so only ask_question/ask_permission report blocked.
set -uf

action=${1:-}
payload=$(cat)

[ -n "${ELIS_SESSION_ID:-}" ] || exit 0
# an agy worker spawned by Claude Code inherits the spawner's ELIS_* and would repaint its row
[ -z "${CLAUDECODE:-}" ] && [ -z "${CLAUDE_CODE_SESSION_ID:-}" ] || exit 0

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
status_wrapper=${ELIS_STATUS_WRAPPER:-"$script_dir/elis-agent-status.sh"}

# a headless `agy -p` run shares the pane with whatever launched it, so its turns must not report
is_headless_agy() {
  local pid=$PPID cmd token found
  for _ in 1 2 3 4 5 6; do
    { [ -n "$pid" ] && [ "$pid" -gt 1 ]; } 2>/dev/null || return 1
    cmd=$(ps -o command= -p "$pid" 2>/dev/null) || return 1
    found=0
    for token in $cmd; do
      if [ "$found" -eq 0 ]; then
        case "$token" in agy | */agy) found=1 ;; esac
      else
        case "$token" in -p | --print | --prompt | --print=* | --prompt=*) return 0 ;; esac
      fi
    done
    [ "$found" -eq 1 ] && return 1
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  return 1
}
is_headless_agy && exit 0

case "$action" in
  invocation | tool-done) "$status_wrapper" active --blink ;;
  ask) "$status_wrapper" blocked ;;
  stop)
    # background work still running: a later Stop with fullyIdle true ends the turn
    idle_false='"fullyIdle"[[:space:]]*:[[:space:]]*false'
    [[ $payload =~ $idle_false ]] || "$status_wrapper" completed --auto-reset
    ;;
esac >/dev/null 2>&1
exit 0
