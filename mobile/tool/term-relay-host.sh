#!/usr/bin/env bash
# The computer's side of integration_test/term_relay_test.dart, on Linux: an offscreen linux/build/elis on its own
# state dir in Live mode, its own relay (Connect a Phone, so the tree reports phoneLead), a shell session phone-target
# and claude-target, a recorded Claude Code permission dialog over a matching transcript.
#   up        prints the pairing link for --dart-define=PAIR_LINK (the emulator reaches the host as 10.0.2.2)
#   takeback  waits for the phone's typing, then claims phone-target's daemon as a key on the computer would
#   down      stops the app, its relay and its daemons
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fixtures=$PWD/test/fixtures/grid
bin=$(cd ../linux/build && pwd) || exit 1
S=${ELIS_E2E_STATE:-/tmp/elr}
PORT=${ELIS_E2E_PORT:-18766}
for v in $(env | sed -n 's/^\(ELIS_[A-Z_]*\|ZMX_[A-Z_]*\|AGTERM_[A-Z_]*\|CLAUDE[A-Z_]*\|ANTHROPIC[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
export ELIS_STATE_DIR=$S SHELL=/bin/bash
ctl() { "$bin/elisctl" "$@" --socket "$S/elis.sock"; }
zdir=${XDG_RUNTIME_DIR:-/tmp}/elis-zmx-$(python3 -I -c 'import os,sys
h=14695981039346656037
for b in os.path.realpath(sys.argv[1]).encode(): h=((h^b)*1099511628211)%2**64
print("%016x"%h)' "$S")
zmx() { ZMX_DIR=$zdir ZMX_SESSION= ZMX_SESSION_PREFIX= "$bin/zmx" "$@"; }
start() {
  (cd /tmp && exec env CLAUDE_CONFIG_DIR="$S/claude" QT_QPA_PLATFORM=offscreen "$bin/elis") >>"$S/app.log" 2>&1 &
  echo $! >"$S/app.pid"
  for _ in $(seq 50); do ctl tree >/dev/null 2>&1 && return 0; sleep 0.2; done
  echo "socket never came up"; exit 1
}
stop() {
  local p; p=$(cat "$S/app.pid" 2>/dev/null) && kill "$p" 2>/dev/null || return 0
  for _ in $(seq 50); do kill -0 "$p" 2>/dev/null || return 0; sleep 0.2; done
  kill -9 "$p"
}
paneof() { ctl tree --json | python3 -I -c 'import json,sys
d=json.load(sys.stdin); d=d.get("result",d); d=d.get("tree",d)
print([f["paneID"] for w in d["workspaces"] for s in w["sessions"] if s["name"]==sys.argv[1] for f in s["surfaces"] if f["kind"]=="left"][0])' "$1"; }
case ${1:-} in
up)
  [ -e "$S" ] && { echo "$S exists: run down first"; exit 1; }
  mkdir -p "$S/config" "$S/mobile" "$S/claude/sessions" "$S/claude/projects/-tmp"
  # the link from a hand-run serve on the same token and certificate, with the app relay's port
  "$bin/elisctl" mobile serve --bind 127.0.0.1 --host 10.0.2.2 --no-qr --port $((PORT + 1)) >"$S/probe.log" 2>&1 &
  probe=$!
  for _ in $(seq 50); do grep -q 'elis://' "$S/probe.log" && break; sleep 0.1; done
  kill "$probe"; wait "$probe" 2>/dev/null
  grep -om1 'elis://[^ ]*' "$S/probe.log" | sed "s/&p=$((PORT + 1))&/\&p=$PORT\&/" >"$S/link"
  start
  ctl restore mode live >/dev/null
  stop
  printf '{"on":true,"port":%s,"host":""}\n' "$PORT" >"$S/mobile/desktop.json"
  start
  # the pending call card-bash-45.ansi shows, as Claude Code records it
  {
    echo '{"type":"user","uuid":"u0","parentUuid":null,"isSidechain":false,"timestamp":"T","message":{"role":"user","content":"run it"}}'
    python3 -I -c 'import json,sys
c=json.load(open(sys.argv[1]))[0]
print(json.dumps({"type":"assistant","uuid":c["uuid"],"parentUuid":"u0","isSidechain":False,"timestamp":"T",
  "message":{"id":"m1","model":"m","content":[{"type":"tool_use","id":c["id"],"name":c["name"],"input":c["input"]}]}}))' \
      "$fixtures/card-bash.pending.json"
  } >"$S/claude/projects/-tmp/e2e-card-bash.jsonl"
  # stands in for claude: a child named claude for the agent sampler, its session file, the dialog redrawn per resize
  cat >"$S/claude.sh" <<'EOF'
fixtures=$1
( exec -a claude sleep 3600 ) &
printf '{"sessionId":"e2e-card-bash","cwd":"/tmp"}' >"$2/$!.json"
draw() { [ "$(stty size </dev/tty | cut -d' ' -f2)" -ge 100 ] && w=100 || w=45; printf '\033[?1049h\033[2J\033[H'; cat "$fixtures/card-bash-$w.ansi"; }
trap draw WINCH
draw
while :; do sleep 1 & wait $!; done
EOF
  ctl session new --name phone-target >/dev/null
  claude=$(ctl session new --name claude-target --no-select)
  sleep 1
  ctl session type "bash $S/claude.sh $fixtures $S/claude/sessions"$'\n' --target "$claude" >/dev/null
  for _ in $(seq 50); do ctl tree --json | grep -q '"agentSessionId":"e2e-card-bash"' && break; sleep 0.2; done
  ctl tree --json | grep -q '"agentSessionId":"e2e-card-bash"' || { echo "claude-target never read as claude"; exit 1; }
  [ "$(ctl tree --json | grep -o '"backedByZmx":true' | wc -l)" -ge 2 ] || { echo "the sessions are not Live"; exit 1; }
  for _ in $(seq 50); do timeout 2 openssl s_client -connect "127.0.0.1:$PORT" </dev/null >/dev/null 2>&1 && break; sleep 0.2; done
  cat "$S/link"
  ;;
takeback)
  for _ in $(seq 600); do ctl session text --target phone-target 2>/dev/null | grep -q 'typed-42' && break; sleep 0.5; done
  ctl session text --target phone-target | grep -q 'typed-42' || { echo "typed-42 never showed"; exit 1; }
  sleep 5 # the phone checks the grid it leads first
  rm -f "$S/claim-in" && mkfifo "$S/claim-in"
  ZMX_MANAGED=other ZMX_MANAGED_CLAIM=1 ZMX_DIR=$zdir ZMX_SESSION= ZMX_SESSION_PREFIX= \
    script -qfec "$bin/zmx attach elis-$(paneof phone-target | tr -d -)" /dev/null <"$S/claim-in" >/dev/null 2>&1 &
  claim=$!
  exec 8>"$S/claim-in"
  sleep 8
  kill "$claim"; exec 8>&-
  echo "took the lead back"
  ;;
down)
  stop
  [ -d "$zdir" ] && for n in $(zmx list --short 2>/dev/null); do zmx kill "$n" --force >/dev/null; done
  rm -rf "$zdir" "$S"
  ;;
*) echo "usage: $0 up|takeback|down"; exit 1 ;;
esac
