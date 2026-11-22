#!/usr/bin/env bash
# End-to-end check of the built app over its control socket, offscreen and on an isolated state dir.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bin=$root/build
export ELIS_STATE_DIR=$(mktemp -d /tmp/agq.XXXX)
for v in $(env | sed -n 's/^\(ELIS_[A-Z_]*\|ZMX_[A-Z_]*\|AGTERM_[A-Z_]*\)=.*/\1/p'); do [ "$v" = ELIS_STATE_DIR ] || unset "$v"; done
ctl() { "$bin/elisctl" "$@"; }
pid=
mpid=
start() {
  CLAUDE_CONFIG_DIR=$ELIS_STATE_DIR/claude QT_QPA_PLATFORM=offscreen "$bin/elis" >"$ELIS_STATE_DIR/app.log" 2>&1 &
  pid=$!
  for _ in $(seq 50); do ctl tree >/dev/null 2>&1 && return; sleep 0.2; done
  echo "socket never came up"; cat "$ELIS_STATE_DIR/app.log"; exit 1
}
stop() { kill "$pid"; wait "$pid" 2>/dev/null || true; }
fail() { echo "FAIL: $*"; ctl tree || true; stop; exit 1; }
fail0() { echo "FAIL: $*"; exit 1; } # before the app runs
# this state dir's zmx namespace (ZmxSupport.socketDirectory: FNV-1a 64 of the resolved path)
zdir=${XDG_RUNTIME_DIR:-/tmp}/elis-zmx-$(python3 -I -c 'import os,sys
h=14695981039346656037
for b in os.path.realpath(sys.argv[1]).encode(): h=((h^b)*1099511628211)%2**64
print("%016x"%h)' "$ELIS_STATE_DIR")
zmx() { ZMX_DIR=$zdir ZMX_SESSION= ZMX_SESSION_PREFIX= "$bin/zmx" "$@"; }
daemons() { if [ -d "$zdir" ]; then zmx list --short 2>/dev/null | grep -c '^elis-' || true; else echo 0; fi; }
reap() { [ -d "$zdir" ] && for n in $(zmx list --short 2>/dev/null); do zmx kill "$n" --force >/dev/null; done; rm -rf "$zdir"; }
trap 'kill $pid $mpid 2>/dev/null || true; reap; rm -rf "$ELIS_STATE_DIR"' EXIT

mkdir -p "$ELIS_STATE_DIR/config" # an isolated state dir keeps keymap.conf and hooks.conf there too
# the installers the launch runs on install or update, run headless against a throwaway HOME
fakehome=$ELIS_STATE_DIR/home
mkdir -p "$fakehome/.claude" "$fakehome/.codex"
HOME=$fakehome SHELL=/bin/sh "$bin/elis" --install agent-hooks --home "$fakehome" | grep -q "Agent Status Hooks Installed" || fail0 "agent hooks installer"
grep -q elis-claude-status.sh "$fakehome/.claude/settings.json" || fail0 "claude hooks merged"
grep -q "hooks.Stop" "$fakehome/.codex/config.toml" || fail0 "codex hooks merged"
"$bin/elis" --install skill --home "$fakehome" | grep -q "Agent Skill Installed" || fail0 "skill installer"
[ -f "$fakehome/.codex/skills/elis/SKILL.md" ] || fail0 "codex skill copy"
"$bin/elis" --install cli --home "$fakehome" >/dev/null
rm -rf "$fakehome/.local" && HOME=$fakehome SHELL=/bin/sh "$bin/elis" --install all | grep -q "Command Line Tool Installed" || fail0 "install all"
[ -s "$ELIS_STATE_DIR/extras-installed" ] || fail0 "install all writes the launch stamp"
[ "$(readlink "$fakehome/.local/bin/elisctl")" = "$bin/elisctl" ] || fail0 "command line tool link"
cat >"$ELIS_STATE_DIR/config/keymap.conf" <<EOF
map ctrl+alt+l toggle_split
command "Mark" ctrl+a>m echo "{AGT_SESSION_ID}" > "$ELIS_STATE_DIR/mark"
map bogus toggle_split
EOF
cat >"$ELIS_STATE_DIR/config/hooks.conf" <<EOF
on app.launched touch "$ELIS_STATE_DIR/launched"
on session.created cat >> "$ELIS_STATE_DIR/created"
EOF
start
ctl version
for _ in $(seq 20); do [ -f "$ELIS_STATE_DIR/launched" ] && break; sleep 0.1; done
[ -f "$ELIS_STATE_DIR/launched" ] || fail "app.launched hook"
ctl keymap list | grep -qE '^  toggle_split +Ctrl\+Alt\+L  \(mapped\)' || fail "keymap list read-back"
ctl keymap list | grep -q "line 3: invalid chord 'bogus'" || fail "keymap diagnostics"
[ "$(ctl keymap reload)" = "1 diagnostic(s)" ] || fail "keymap reload count"
first=$(ctl tree | awk 'NR==2{print $2}')
ctl keymap run Mark --target "$first" >/dev/null
for _ in $(seq 20); do [ -s "$ELIS_STATE_DIR/mark" ] && break; sleep 0.1; done
[ "$(cat "$ELIS_STATE_DIR/mark")" = "$first" ] || fail "keymap run with {AGT_SESSION_ID}"
ctl keymap run Nope 2>/dev/null && fail "unknown custom command accepted"
ctl hooks list | grep -q 'on session.created' || fail "hooks list"
ctl theme list | grep -q ' DarkPastels' || fail "theme list"
ctl theme set DarkPastels >/dev/null
ctl theme list | grep -q '^\* DarkPastels' || fail "theme set read-back"
ctl theme set NoSuchScheme 2>/dev/null && fail "unknown theme accepted"
ctl theme set >/dev/null
[ "$(ctl tree | grep -c '^  ')" = 1 ] || fail "first launch should open one session"
id=$(ctl session new --name probe --cwd /tmp --workspace-name agents --create-workspace)
sleep 1
ctl session type 'echo MARK=$ELIS_SESSION_ID' --target "$id"
ctl session type $'\n' --target "$id"
sleep 1
ctl session text --target "$id" --lines 5 | grep -q "MARK=$id" || fail "pane env or text read-back"
ctl session status blocked --target "$id" --blink --pane main
ctl tree | grep probe | grep -q blocked || fail "status not set"
ctl session status bogus --target "$id" 2>/dev/null && fail "bogus status accepted"
ELIS_SESSION_ID=$id ctl session get | grep -q '^pid' || fail "session get by env target"
ctl session type "$root/../shared/agent-status/elis-claude-status.sh completed --auto-reset"$'
' --target "$id"
sleep 1
ctl tree | grep probe | grep -q completed || fail "Claude hook adapter from a pane"
# a claude in a pane names its conversation in the tree (its sessions/<pid>.json), which session transcript reads
cat >"$ELIS_STATE_DIR/fake-claude.sh" <<'EOF'
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
printf '{"sessionId":"c1","cwd":"/tmp"}' >"$CLAUDE_CONFIG_DIR/sessions/$$.json"
exec -a claude sleep 600
EOF
mkdir -p "$ELIS_STATE_DIR/claude/projects/-tmp"
for n in 1 2 3; do
  parent=null; [ "$n" = 1 ] || parent="\"u$((n - 1))\""
  printf '{"type":"user","uuid":"u%s","parentUuid":%s,"isSidechain":false,"timestamp":"T","message":{"role":"user","content":"prompt %s %s"}}\n' \
    "$n" "$parent" "$n" "$(printf 'x%.0s' $(seq 80))"
done >"$ELIS_STATE_DIR/claude/projects/-tmp/c1.jsonl"
agent=$(ctl session new --name agent --cwd /tmp)
sleep 1
ctl session type 'bash "$ELIS_STATE_DIR/fake-claude.sh"'$'\n' --target "$agent"
for _ in $(seq 30); do ctl --json tree | grep -q '"agentSessionId":"c1"' && break; sleep 0.2; done
ctl --json tree | grep -q '"agentPane":"left","agentSessionId":"c1"' || fail "tree agentSessionId and agentPane"
out=$(ctl session transcript --target "$agent" 2>&1) || fail "session transcript ($out)"
grep -q '^user  prompt 3 x' <<<"$out" && grep -q '^next ' <<<"$out" || fail "session transcript tail page ($out)"
start=$(ctl --json session transcript --max-bytes 200 --target "$agent" | grep -o '"start":[0-9]*' | cut -d: -f2)
[ -n "$start" ] && [ "$start" -gt 0 ] || fail "a small tail page starts past the file head"
out=$(ctl session transcript --before "$start" --max-bytes 200 --target "$agent")
grep -q '^user  prompt 2 x' <<<"$out" && ! grep -q 'prompt 3' <<<"$out" || fail "session transcript --before pages back ($out)"
out=$(ctl session transcript --pane right --target "$agent" 2>&1) || true
grep -q "no adapter" <<<"$out" || fail "session transcript: the pane without claude ($out)"
ctl session transcript --after 1 --before 2 --target "$agent" 2>/dev/null && fail "--after with --before"
ctl session close --target "$agent" >/dev/null # never captured for a re-run restore: its argv names claude
ctl session split on --axis horizontal --target "$id"
sleep 1
ctl session get --target "$id" | grep -qE '^hasSplit +true' || fail "split not created"
ctl session get --target "$id" | grep -qE '^splitAxis +horizontal' || fail "split axis"
ctl session swap --target "$id"
ctl session split close --target "$id"
ctl session get --target "$id" | grep -qE '^hasSplit +false' || fail "split not closed"
rc=0; ctl session overlay open 'exit 4' --block --target "$id" || rc=$?
[ "$rc" = 4 ] || fail "overlay --block exits with the program's status ($rc)"
[ "$(ctl session overlay result --target "$id")" = 4 ] || fail "overlay result"
ctl session overlay open 'sleep 30' --size-percent 60 --target "$id"
ctl tree --json | grep -q '"overlaySizePercent":60' || fail "floating overlay read-back"
[ "$(ctl session overlay toggle --target "$id")" = hidden ] || fail "overlay toggle hides"
ctl tree --json | grep -q '"hiddenOverlays":\["session"\]' || fail "hidden overlay read-back"
ctl session hud 'hi' --target "$id" 2>/dev/null && fail "a hud over a running program"
ctl session overlay close --target "$id"
ctl session hud 'building' --position top --spinner --target "$id"
ctl tree --json | grep -q '"position":"top-center"' || fail "hud read-back"
ctl session hud close --target "$id"
ctl session hud close --target "$id" 2>/dev/null && fail "hud close is not idempotent"
ctl dashboard "$first" "$id" --font-size 9 >/dev/null
ctl tree --json | grep -qF "\"dashboardMembers\":[\"$first:left\",\"$id:left\"]" || fail "dashboard members"
ctl tree --json | grep -q '"dashboardFontMode":"fixed"' || fail "dashboard font mode"
ctl dashboard "$id:scratch" 2>/dev/null && fail "dashboard accepted a bad pane suffix"
ctl dashboard --close
ctl tree --json | grep -q dashboardMembers && fail "dashboard --close"
bg=$(ctl session new --name bg --no-select) # a notification for the session in front of you is not a badge
ctl notify --title smoke --body hi --target "$bg"
ctl session get --target "$bg" | grep -qE '^unseen +1' || fail "unseen badge"
ctl session seen --target "$bg"
ctl session get --target "$bg" | grep -qE '^unseen +0' || fail "session seen"
sleep 0.5
ctl session type $'printf "\\033]9;from osc\\007"\n' --target "$bg"
for _ in $(seq 20); do ctl session get --target "$bg" | grep -qE '^unseen +1' && break; sleep 0.1; done
ctl session get --target "$bg" | grep -qE '^unseen +1' || fail "OSC 9 from a pane raises the badge"
grep -q "\"session\":\"$bg\"" "$ELIS_STATE_DIR/created" || fail "session.created hook got the event on stdin"
ctl filepanel show >/dev/null
ctl tree --json | grep -q '"filePanelVisible":true' || fail "file panel show"
[ "$(ctl filepanel width 260)" = 260.0 ] || fail "file panel width"
ctl tree --json | grep -q '"filePanelWidth":260' || fail "file panel width read-back"
ctl filepanel hide >/dev/null
ctl session new --parent "$id" --name logs --no-select >/dev/null
ctl tree --json | grep -q "\"parent\":\"$id\"" || fail "companion"
named=$(ctl session new --no-select)
sleep 1.5
folder=$(basename "$(ctl session get --target "$named" | awk '$1 == "cwd" {print $2}')")
[ "$folder" = "$(basename "$HOME")" ] && folder="~"
ctl tree | grep "$named" | grep -qF -- "$folder" || fail "a plain shell is named after its folder (its prompt title is not a name)"
ctl session type "sleep 4"$'\n' --target "$named"
sleep 3
ctl tree | grep "$named" | grep -q 'sleep' || fail "a running command names the session"
sleep 4 # the sampler ticks every 2 s
ctl tree | grep "$named" | grep -qF -- "$folder" || fail "the folder names the session again once the command ends"
ctl session type "sh -c 'printf \"\\033]0;Agent task\\007\"; sleep 3'"$'\n' --target "$named"
sleep 2
ctl tree | grep "$named" | grep -q 'Agent task' || fail "a running program's title names the session"
ctl session rename renamed --target probe
ctl session go --to next >/dev/null
gone=$(ctl session new --name exits --no-select)
sleep 1
ctl session type $'echo BG_OK\n' --target "$gone"
sleep 1
ctl session text --target "$gone" | grep -q BG_OK || fail "background session text"
ctl session type $'exit\n' --target "$gone"
sleep 1.5
ctl tree | grep -q exits && fail "exited shell should end its session"
doomed=$(ctl session new --name doomed --no-select)
sleep 1
dpid=$(ctl session get --target "$doomed" | awk '/^pid /{print $2}')
kill -0 "$dpid" || fail "no shell pid for doomed"
ctl session close --target "$doomed"
for _ in $(seq 20); do kill -0 "$dpid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$dpid" 2>/dev/null && fail "closing a session left its shell running"
ctl session tint red --target "$id"
ctl tree --json | grep -q '"tint":"red"' || fail "session tint read-back"
ctl session tint fuchsia --target "$id" 2>/dev/null && fail "unknown tint accepted"
ctl workspace new --name tinted --tint '#33AA55' >/dev/null
ctl tree --json | grep -q '"tint":"#33aa55","tintOn":\["icon","name"\]' || fail "workspace new --tint hex"
mkdir -p "$ELIS_STATE_DIR/proj/sub"
wsorder() { ctl tree | awk '!/^ /{print $1}'; }
rows() { ctl tree | awk -v w="$1" '!/^ /{on = $1 == w; next} on {print ($1 == "*") ? $2 : $1}'; }
pws=$(ctl workspace new pinned --collapsed --folder "$ELIS_STATE_DIR/proj")
ctl tree --json | grep -q "\"collapsed\":true,\"id\":\"$pws\",\"name\":\"pinned\",\"projectFolder\":\"$ELIS_STATE_DIR/proj\"" \
  || fail "workspace new positional --collapsed --folder"
err=$(ctl workspace new --folder / 2>&1) && fail "workspace new --folder / accepted"
[[ $err == *'project folder must not be / or the home folder'* ]] || fail "workspace new --folder / error ($err)"
err=$(ctl workspace new --folder "$ELIS_STATE_DIR/nope" 2>&1) && fail "workspace new --folder missing accepted"
[[ $err == *"no such directory: $ELIS_STATE_DIR/nope"* ]] || fail "workspace new --folder missing error ($err)"
ctl workspace select --target "$pws"
ctl tree --json | grep -q "\"active\":true,\"collapsed\":true,\"id\":\"$pws\"" || fail "workspace select on an empty workspace"
ctl session select --target "$id"
routed=$(ctl session new --name inproj --cwd "$ELIS_STATE_DIR/proj/sub" --no-select)
ctl session get --target "$routed" | grep -qE "^workspace +$pws" || fail "projectFolder routes session new --cwd"
ctl workspace folder clear --target "$pws"
ctl tree --json | grep -q '"projectFolder"' && fail "workspace folder clear"
ctl workspace folder set "$ELIS_STATE_DIR/proj" --target "$pws"
ctl tree --json | grep -q "\"projectFolder\":\"$ELIS_STATE_DIR/proj\"" || fail "workspace folder set"
ctl workspace move --to top --target "$pws"
[ "$(wsorder | head -1)" = "$pws" ] || fail "workspace move --to top"
ctl workspace move --to bottom --target "$pws"
[ "$(wsorder | tail -1)" = "$pws" ] || fail "workspace move --to bottom"
fws=$(ctl session get --target "$first" | awk '/^workspace /{print $2}')
ctl session move --after "$first" --target "$routed"
[ "$(rows "$fws" | grep -A1 -x "$first" | tail -1)" = "$routed" ] || fail "session move --after"
ctl session move --to top --target "$routed"
[ "$(rows "$fws" | head -1)" = "$routed" ] || fail "session move --to top"
err=$(ctl session move --to up --after "$first" --target "$routed" 2>&1) && fail "session move --to with --after accepted"
[[ $err == *'session.move takes --after/--before or --to, not both'* ]] || fail "session move conflict error ($err)"
ctl session close --target "$routed" >/dev/null
ctl workspace delete --target "$pws"
ctl session select --target "$id"
ctl workspace focus on --target agents
ctl tree --json | grep -q '"workspaceFilter":true' || fail "workspace focus on"
ctl workspace filter off
ctl tree --json | grep -q '"workspaceFilter":false' || fail "workspace filter off"
ctl tree --json | grep -q '"focused":true' || fail "filter off keeps the marked set"
ctl font inc --target "$id"
ctl session get --target "$id" | grep -qE '^fontSize +[1-9]' || fail "font inc read-back"
ctl font reset --target "$id"
ctl session get --target "$id" | grep -qE '^fontSize +0' || fail "font reset"
src=$(ctl session new --name src --no-select)
sleep 1
ctl session type $'sleep 300\n' --target "$src"
sleep 1
dup=$(ctl session duplicate --companion --no-select --target "$src")
sleep 1
ctl session get --target "$dup" | grep -qE "^parent +$src" || fail "duplicate as companion parent"
dupid=$(ctl session get --target "$dup" | awk '/^pid /{print $2}') # exec'd: the program is the pane's process itself
grep -qx sleep "/proc/$dupid/comm" || fail "duplicate as companion runs the pane's program"
undo=$(ctl session new --name undo --no-select)
[ "$(ctl session close --undoable --target "$undo")" = "ok (undoable)" ] || fail "close --undoable"
ctl tree | grep -q undo && fail "an undoable close leaves the tree"
ctl restore capture 2>/dev/null && fail "restore capture outside rerun mode"
ctl restore mode rerun | grep -q '(restart required)' || fail "restore mode read-back"
ctl restore capture | grep -q 'captured [1-9]' || fail "restore capture"
w1=$(ctl window list | awk '$1=="*"{print $2}')
w2=$(ctl window new second)
[ "$(ctl window list | grep -c ' open$')" = 2 ] || fail "window new"
front=$(ctl window list | awk '$1=="*"{print $2}'); other=$w1; [ "$front" = "$w1" ] && other=$w2
mkdir -p "$ELIS_STATE_DIR/pin2/sub"
pin2=$(ctl workspace new pinned2 --folder "$ELIS_STATE_DIR/pin2" --window "$other")
pinned=$(ctl session new --name pinned2s --cwd "$ELIS_STATE_DIR/pin2/sub" --no-select)
ctl tree --window "$other" | grep -q pinned2s || fail "a project folder in another window takes session new --cwd"
ctl session close --target "$pinned" >/dev/null
ctl workspace delete --target "$pin2"
inw2=$(ctl session new --name inw2 --window "$w2" --no-select)
ctl tree --window "$w2" | grep -q inw2 || fail "session in the second window"
ctl tree --window "$w1" | grep -q inw2 && fail "windows share a tree"
ctl session get --target "$inw2" | grep -q '^name  *inw2' || fail "a session id reaches its window"
ctl session type 'echo WIN=$ELIS_WINDOW_ID'$'\n' --target "$inw2"
sleep 1
ctl session text --target "$inw2" | grep -q "WIN=$w2" || fail "ELIS_WINDOW_ID"
r=$(ctl window resize "$w2" --width 700 --height 500); [ "$r" = 700x500 ] || fail "window resize ($r)"
ctl window rename "$w2" renamed-window
ctl window list | grep -q renamed-window || fail "window rename"
ctl window close "$w2"
ctl window list | grep -q 'renamed-window *closed' || fail "window close keeps the bundle"
ctl tree --window "$w2" 2>/dev/null && fail "a closed window answers tree"
ctl window select "$w2"
ctl tree --window "$w2" | grep -q inw2 || fail "a reopened window keeps its sessions"
w3=$(ctl window new doomed)
err=$(ctl workspace delete --window "$w3" 2>&1) && fail "deleted last workspace"
[[ $err == *"cannot delete last workspace"* ]] || fail "last workspace delete error ($err)"
ctl window delete "$w3"
ctl window list | grep -q doomed && fail "window delete"
ctl window go --to next >/dev/null || fail "window go"
ctl window select "$w1"
# master's catalog: events, context, sidebar, text extents, pick/ask, messages, recent, batch targets, absent features
timeout 3 "$bin/elisctl" events --kind session.created >"$ELIS_STATE_DIR/events.log" &
evpid=$!
sleep 0.5
ctl session new --name evt --no-select >/dev/null
wait "$evpid" || true
grep -q 'session.created evt' "$ELIS_STATE_DIR/events.log" || fail "events stream"
ctl session context 'PR 12' --target "$id"
ctl tree --json | grep -q '"context":"PR 12"' || fail "session context read-back"
ctl session context 2>/dev/null && fail "context without text or --clear"
[ "$(ctl sidebar width 300)" = 300.0 ] || fail "sidebar width"
ctl sidebar mode flagged
ctl tree --json | grep -q '"sidebarMode":"flagged"' || fail "sidebar mode"
ctl sidebar mode tree
[ "$(ctl sidebar flagged-layout tree)" = tree ] || fail "sidebar flagged-layout"
[ "$(ctl sidebar density compact)" = compact ] || fail "sidebar density"
ctl tree --json | grep -q '"sidebarDensity":"compact"' || fail "sidebar density read-back"
ctl workspace go --to next >/dev/null || fail "workspace go"
ctl session select --target "$id"
ctl session type $'seq 1 120\n' --target "$id"
sleep 1
ctl session text --all --target "$id" | grep -qx 1 || fail "session text --all reaches the scrollback"
ctl session text --target "$id" | grep -qx 1 && fail "session text is the visible screen"
ctl session text --all --lines 2 --target "$id" 2>/dev/null && fail "--all with --lines"
ctl session search 117 --target "$id" | grep -q 'match' || fail "session search"
ctl session search --close --target "$id"
pick=$(printf 'one\ntwo\n' | ctl pick --no-block | sed 's/.*"id":"\([^"]*\)".*/\1/')
ctl tree --json | grep -q "\"pickPending\":\"$pick\"" || fail "pick pending read-back"
ctl pick cancel "$pick"
rc=0; ctl pick result "$pick" >/dev/null || rc=$?
[ "$rc" = 2 ] || fail "pick result exit after cancel ($rc)"
ask=$(ctl ask 'Ship?' --button yes=Yes --button no --no-block --target "$id" | sed 's/.*"id":"\([^"]*\)".*/\1/')
ctl tree --json | grep -q "\"ask\":{\"id\":\"$ask\"" || fail "ask read-back"
ctl ask cancel "$ask"
rc=0; ctl ask result "$ask" >/dev/null || rc=$?
[ "$rc" = 2 ] || fail "ask result exit after cancel ($rc)"
ctl ask 'No buttons' 2>/dev/null && fail "ask without buttons"
ctl session type '"$ELISCTL" msg send ping --to "$ELIS_SESSION_ID:left" >/dev/null; "$ELISCTL" msg read --ack > "'"$ELIS_STATE_DIR"'/inbox"'$'\n' --target "$id"
for _ in $(seq 20); do grep -q ping "$ELIS_STATE_DIR/inbox" 2>/dev/null && break; sleep 0.2; done
grep -q ping "$ELIS_STATE_DIR/inbox" || fail "msg send/read from a pane"
b1=$(ctl session new --name batch1 --no-select)
b2=$(ctl session new --name batch2 --no-select)
[ "$(ctl session close --target "$b1" --target "$b2")" = "2 session(s)" ] || fail "batch close"
ctl recent list | grep -q batch2 || fail "recent list"
ctl recent open "$b2" >/dev/null
ctl tree | grep -q batch2 || fail "recent open by id"
err=$(ctl zmx list 2>&1) && fail "zmx list answered"
[[ $err == *'zmx.list is not supported on this platform'* ]] || fail "absent feature error"
for ucmd in "session page" "session overlay follow" "session overlay search" "session overlay changes" "session overlay files" "session overlay wrap"; do
  err=$(ctl $ucmd --target "$id" 2>&1) && fail "$ucmd answered"
  [[ $err == *'is not supported on this platform'* ]] || fail "$ucmd absent feature error ($err)"
done
err=$(ctl session overlay copy --target "$id" 2>&1) && fail "overlay copy without overlay"
[[ $err == *'no overlay'* ]] || fail "overlay copy error ($err)"
ctl session overlay open 'sleep 30' --target "$id"
err=$(ctl session overlay copy --target "$id" 2>&1) && fail "overlay copy with nothing selected"
[[ $err == *'no selection'* ]] || fail "overlay copy reads the covering terminal ($err)"
ctl session overlay close --target "$id"
ctl notify 2>/dev/null && fail "notify without a body"
# the phone relay: TLS pinned by the link's fingerprint, the token first, then elisctl requests answered under their id
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
"$bin/elisctl" mobile serve --no-qr --port "$port" --bind 127.0.0.1 --host 127.0.0.1 >"$ELIS_STATE_DIR/relay.log" 2>&1 &
mpid=$!
for _ in $(seq 50); do grep -q 'elis://' "$ELIS_STATE_DIR/relay.log" && break; sleep 0.1; done
link=$(grep -om1 'elis://[^ ]*' "$ELIS_STATE_DIR/relay.log") || fail "relay link: $(cat "$ELIS_STATE_DIR/relay.log")"
[[ $link == "elis://pair?h=127.0.0.1&p=$port&"* ]] || fail "relay link host and port ($link)"
tok=$(sed 's/.*[?&]t=\([^&]*\).*/\1/' <<<"$link")
pin=$(openssl s_client -connect "127.0.0.1:$port" </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | tr A-F a-f)
[[ $link == *"&f=$pin&"* ]] || fail "the link pins the served certificate ($pin)"
phone() { { printf '%s\n' "$@"; sleep 1; } | timeout 5 openssl s_client -quiet -no_ign_eof -connect "127.0.0.1:$port" 2>/dev/null || true; }
out=$(phone "{\"auth\":\"$tok\",\"id\":0}" '{"id":1,"cmd":"tree"}')
grep -q '^{"id":0,"ok":true,"result":{"host"' <<<"$out" || fail "relay auth ($out)"
grep -q '^{"id":1,"ok":true,"result":{"tree"' <<<"$out" || fail "relay forwards tree under its id ($out)"
out=$(phone '{"auth":"wrong","id":0}' '{"id":1,"cmd":"tree"}')
grep -q '"error":"unauthorized"' <<<"$out" || fail "relay refuses a wrong token ($out)"
grep -q '"id":1,' <<<"$out" && fail "relay answered after a wrong token"
ctl mobile reset >/dev/null
grep -q '"error":"unauthorized"' <<<"$(phone "{\"auth\":\"$tok\"}")" || fail "mobile reset revokes the old token"
grep -q '"ok":true' <<<"$(phone "{\"auth\":\"$(cat "$ELIS_STATE_DIR/mobile/token")\"}")" || fail "the new token after reset"
kill "$mpid"; wait "$mpid" 2>/dev/null || true
fit=$(ctl session new --name fitme --no-select)
sleep 1
# session grid: the phone's Fit to phone; the program sees the phone's grid, all of it readable, until --reset
ctl session grid 48x70 --target "$fit" >/dev/null || fail "session grid"
ctl session type $'clear; stty size; seq 1 60\r' --target "$fit"
for _ in $(seq 20); do out=$(ctl session text --lines 70 --target "$fit"); [[ $out == *60* ]] && break; sleep 0.2; done
[ "$(head -1 <<<"$out")" = "70 48" ] || fail "session grid: the program sees 70x48, the first row reads back ($(head -2 <<<"$out"))"
ctl session grid --reset --target "$fit" >/dev/null
ctl --json session text --target "$fit" | grep -q '"columns":48' && fail "session grid --reset gives the grid back to the view"
# session scroll: wheel notches as a mouse would send; a shell's view scrolls back through its history
ctl session type $'clear; seq 1 300\r' --target "$fit"
# all of it first: a scroll while seq still prints keeps the view where it was then
for _ in $(seq 30); do ctl session text --target "$fit" | grep -qx 300 && break; sleep 0.2; done
ctl session scroll -30 --target "$fit" >/dev/null || fail "session scroll"
last=$(ctl session text --target "$fit" | grep -v '^$' | tail -1)
[[ $last =~ ^2[0-9][0-9]$ ]] || fail "session scroll -30 shows older rows (last row $last)"
ctl session scroll 30 --target "$fit" >/dev/null
ctl session close --target "$fit" >/dev/null
# Settings ▸ Connect a Phone switched on: the app runs the relay itself from launch and ends it with itself
printf '{"on":true,"port":%s}\n' "$port" >"$ELIS_STATE_DIR/mobile/desktop.json"
cd /tmp
ctl session type $'cd /usr\n' --target "$id"
sleep 1
stop

start
for _ in $(seq 50); do grep -q '"ok":true' <<<"$(phone "{\"auth\":\"$(cat "$ELIS_STATE_DIR/mobile/token")\"}")" && break; sleep 0.2; done
grep -q '"id":1,"ok":true,"result":{"tree"' <<<"$(phone "{\"auth\":\"$(cat "$ELIS_STATE_DIR/mobile/token")\"}" '{"id":1,"cmd":"tree"}')" \
  || fail "the app starts the relay it was switched on with"
printf '{"on":false,"port":%s}\n' "$port" >"$ELIS_STATE_DIR/mobile/desktop.json"
ctl tree | grep -q 'renamed' || fail "session not restored"
ctl tree | grep renamed | grep -q idle || fail "status must not survive a restart"
ctl tree | grep renamed | grep -q '/usr' || fail "cwd not tracked"
ctl tree --json | grep -q '"tint":"red"' || fail "tint not restored"
ctl tree --json | grep -q '"tint":"#33aa55"' || fail "hex tint not restored"
ctl tree --json | grep -q '"context":"PR 12"' || fail "context not restored"
ctl restore mode | grep -q 'active     rerun' || fail "restore mode at launch"
[ "$(ctl window list | grep -c ' open$')" = 2 ] || fail "open windows reopen at launch"
ctl tree --window "$w2" | grep -q inw2 || fail "second window restored"
for _ in $(seq 20); do ctl session get --target src | grep -qE '^foreground +sleep' && break; sleep 0.2; done
ctl session get --target src | grep -qE '^foreground +sleep' || fail "rerun restore replays the captured command"
ctl restore mode live >/dev/null
stop
timeout 3 openssl s_client -connect "127.0.0.1:$port" </dev/null >/dev/null 2>&1 && fail0 "the relay outlived the app"

start # live: every pane starts its daemon, and the captured sleep is the attach payload, run once
ctl restore mode | grep -q 'active     live' || fail "live mode at launch"
for _ in $(seq 20); do ctl session get --target src | grep -qE '^foreground +sleep' && break; sleep 0.2; done
spid=$(ctl session get --target src | awk '/^foregroundPid /{print $2}')
[ -n "$spid" ] && [ "$spid" -gt 0 ] || fail "live pane foreground"
ctl tree --json | grep -q '"backedByZmx":true' || fail "a live session reads backedByZmx"
ctl tree --json | grep -q '"kind":"left","lead":"leader","paneID":"[0-9a-f-]*","visible":true' || fail "tree surfaces[]"
out=$(ctl session attach --json --target src) || fail "session attach --json ($out)"
grep -q '"argv"' <<<"$out" && grep -q '"screen"' <<<"$out" && grep -q '"paneID"' <<<"$out" && ! grep -q '"nonce"' <<<"$out" \
  || fail "session attach --json fields ($out)"
out=$(ctl session attach --json --claim --target src) || fail "session attach --json --claim ($out)"
grep -q '"nonce"' <<<"$out" || fail "session attach --json --claim nonce ($out)"
err=$(ctl session attach --json --pane right --target src 2>&1) && fail "session attach --pane right accepted"
grep -q 'session has no split pane' <<<"$err" || fail "session attach --pane right error ($err)"
ctl session type $'LIVE_VAR=kept\n' --target renamed
sleep 0.5
stop
kill -0 "$spid" 2>/dev/null || fail "a live pane's program outlives the app"

start
for _ in $(seq 20); do ctl session get --target src | grep -qE '^foreground +sleep' && break; sleep 0.2; done
[ "$(ctl session get --target src | awk '/^foregroundPid /{print $2}')" = "$spid" ] || fail "live reattach keeps the same program"
ctl session type 'echo "V=$LIVE_VAR"'$'\n' --target renamed
for _ in $(seq 20); do ctl session text --target renamed --lines 5 | grep -q 'V=kept' && break; sleep 0.2; done
ctl session text --target renamed --lines 5 | grep -q 'V=kept' || fail "live reattach keeps the shell"
# another client claims a pane's lead, as the phone will: the pane follows, typed and read through its daemon, and
# takes the lead back once that client leaves
paneof() { ctl tree --json | python3 -I -c 'import json,sys
d=json.load(sys.stdin); d=d.get("result",d); d=d.get("tree",d)
print([f["paneID"] for w in d["workspaces"] for s in w["sessions"] if s["name"]==sys.argv[1] for f in s["surfaces"] if f["kind"]=="left"][0])' "$1"; }
claim() {
  rm -f "$ELIS_STATE_DIR/claim-in" && mkfifo "$ELIS_STATE_DIR/claim-in"
  ZMX_MANAGED=other ZMX_MANAGED_CLAIM=1 ZMX_DIR=$zdir ZMX_SESSION= ZMX_SESSION_PREFIX= \
    script -qfec "$bin/zmx attach elis-$(paneof "$1" | tr -d -)" /dev/null <"$ELIS_STATE_DIR/claim-in" >/dev/null 2>&1 &
  mpid=$!
  exec 8>"$ELIS_STATE_DIR/claim-in"
  for _ in $(seq 25); do ctl tree --json | grep -q '"lead":"follower"' && return; sleep 0.2; done
  fail "a pane another client leads reads follower"
}
release() {
  kill "$mpid"
  exec 8>&-
  for _ in $(seq 25); do ctl tree --json | grep -q '"lead":"follower"' || return 0; sleep 0.2; done
  fail "the pane takes the lead back once the other client leaves"
}
claim renamed
ctl session type 'echo "COVERED=$((40+2))"'$'\n' --target renamed || fail "a covered pane types through its daemon"
for _ in $(seq 20); do ctl session text --target renamed --lines 5 | grep -q 'COVERED=42' && break; sleep 0.2; done
ctl session text --target renamed --lines 5 | grep -q 'COVERED=42' || fail "a covered pane reads from its daemon"
out=$(ctl session copy --target renamed 2>&1 || true); grep -q 'pane is covered' <<<"$out" || fail "a covered pane refuses copy ($out)"
release
ctl session text --target renamed --lines 5 | grep -q 'COVERED=42' || fail "the taken-back pane shows the daemon's screen"
ctl dashboard "$src" >/dev/null # taken over in its dashboard cell
claim src
release
ctl tree --json | grep -q "\"dashboardMembers\":\[\"$src:left\"\]" || fail "a takeover keeps the dashboard cell"
fg=$(ctl session get --target src | awk '/^foregroundPid /{print $2}'); [ "$fg" = "$spid" ] || fail "a takeover keeps the pane's program ($fg, was $spid)"
ctl dashboard --close >/dev/null
gone=$(ctl session new --name gone --no-select)
for _ in $(seq 20); do [ "$(daemons)" -gt "$(ctl tree --json | grep -o '"kind":"left"' | wc -l)" ] && break; sleep 0.2; done
before=$(daemons)
ctl session split on --target "$gone" >/dev/null
for _ in $(seq 20); do [ "$(daemons)" -gt "$before" ] && break; sleep 0.2; done
[ "$(daemons)" -gt "$before" ] || fail "a live split starts its own daemon"
ctl session split close --target "$gone"
for _ in $(seq 20); do [ "$(daemons)" = "$before" ] && break; sleep 0.2; done
[ "$(daemons)" = "$before" ] || fail "closing a split ends its daemon"
ctl session close --target "$gone" >/dev/null
for _ in $(seq 20); do [ "$(daemons)" -lt "$before" ] && break; sleep 0.2; done
[ "$(daemons)" -lt "$before" ] || fail "deleting a session ends its daemon"
wpid=$(ctl session get --target "$inw2" | awk '/^pid /{print $2}')
[ -n "$wpid" ] && [ "$wpid" -gt 0 ] || fail "a live pane in the second window"
ctl window close "$w2"
before=$(daemons)
stop
start # a closed window's file claims its daemons from the launch reap
kill -0 "$wpid" 2>/dev/null || fail "a closed window keeps its live daemons"
[ "$(daemons)" = "$before" ] || fail "a live launch reaps only unclaimed daemons"
ctl window delete "$w2"
for _ in $(seq 20); do kill -0 "$wpid" 2>/dev/null || break; sleep 0.2; done
kill -0 "$wpid" 2>/dev/null && fail "deleting a window ends its daemons"
ctl restore mode none >/dev/null
stop

start # a Fresh shells launch ends what a live run left
kill -0 "$spid" 2>/dev/null && fail "fresh launch reaps live daemons"
[ "$(daemons)" = 0 ] || fail "fresh launch leaves no daemon"
stop
echo "smoke OK"
