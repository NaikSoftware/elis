#!/usr/bin/env bash
# Runs migrate-from-agterm-qt.sh on a fake HOME and runtime dir holding what agterm-qt left, with real session daemons.
#   migrate-from-agterm-qt-test.sh <elis-session-host>
set -u
script="$(cd "$(dirname "$0")/.." && pwd)/migrate-from-agterm-qt.sh"
host=${1:?usage: $0 <elis-session-host>}
# a short /tmp root keeps the daemon socket paths under the 108-byte limit
root=$(mktemp -d /tmp/aqm.XXXXXX)
H=$root/h RT=$root/rt
cleanup() {
    for s in "$RT"/*/*; do [ -S "$s" ] && timeout 5 "$host" --kill "$s" >/dev/null 2>&1; done
    wait # the attach clients exit with their daemons
    [ -n "${KEEP:-}" ] || rm -rf "$root"
}
trap cleanup EXIT
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
snap() { (cd "$H" && find . -printf '%y %p %m %l\n' | sort && find . -type f -exec md5sum {} + | sort); }
run() { out=$(bash "$script" 2>&1); code=$?; }

for v in $(env | sed -n 's/^\(AGTERM[A-Z_]*\|ELIS[A-Z_]*\|XDG_[A-Z_]*\|CODEX_HOME\|OPENCODE_CONFIG_DIR\|TMPDIR\)=.*/\1/p'); do unset "$v"; done
export HOME=$H XDG_RUNTIME_DIR=$RT KBUILDSYCOCA=$root/sycoca
printf '#!/bin/sh\necho "$@" >> %s/sycoca.log\n' "$root" > "$KBUILDSYCOCA"
chmod +x "$KBUILDSYCOCA"

state=$H/.local/share/agterm-qt conf=$H/.config/agterm-qt
live=$RT/agterm-qt-$(printf %s "$state" | sha1sum | cut -c1-8)
case "$live" in "$root"/*) ;; *) echo "refusing: $live is outside $root"; exit 1 ;; esac
mkdir -p "$state/windows" "$state/mobile" "$state/agent-status" "$state/skill/agterm" "$conf/hooks" "$conf/agent-status" \
    "$H/.local/bin" "$H/.local/share/elis/agent-status" "$H/.local/share/applications" "$H/.local/share/konsole" \
    "$H/.local/share/icons/hicolor/64x64/apps" "$live" "$RT/agterm-qt-0ther000"

printf '{"active":"w1","version":1,"windows":[{"id":"w1","name":"window 1","open":true}]}\n' > "$state/windows.json"
printf '{\n    "settings": {\n        "configDirectory": "~/.config/agterm-qt",\n        "restoreMode": "live"\n    },\n    "resume": "cd /src/agterm-qt && claude"\n}\n' > "$state/windows/w1.json"
printf 'CERT\n' > "$state/mobile/cert.pem"
printf 'TOKEN\n' > "$state/mobile/token" && chmod 600 "$state/mobile/token"
printf '999999\nagterm-qt\nhost\n' > "$state/agterm.lock"
for s in "$state/agterm.sock" "$live/gone.main"; do python3 -I -c "import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$s"; done
printf 'f\n' > "$state/extras-installed"
printf 'old\n' > "$state/agent-status/agterm-agent-status.sh"
printf '<!-- agterm-skill -->\n' > "$state/skill/agterm/SKILL.md"
printf 'elis payload\n' > "$H/.local/share/elis/agent-status/elis-agent-status.sh"

cat > "$conf/keymap.conf" <<'EOF'
# agterm-qt keymap
command "Jump" ctrl+a>j agtermctl session focus "$AGTERM_SESSION_ID" --socket ~/.local/share/agterm-qt/agterm.sock
command "Mine" ctrl+a>m echo "$AGT_SESSION_ID" "$AGTERMCTL"
EOF
printf 'on status ~/.config/agterm-qt/hooks/status.sh\n' > "$conf/hooks.conf"
printf '#!/bin/sh\nagtermctl notify "$AGT_EVENT_STATUS"\n' > "$conf/hooks/status.sh" && chmod 755 "$conf/hooks/status.sh"
printf 'vim\n' > "$conf/restore-denylist.conf"
printf 'old\n' > "$conf/agent-status/agterm-claude-status.sh"
printf '[Desktop Entry]\nDefaultProfile=agterm-qt.profile\n' > "$H/.config/agterm-qtrc" && chmod 600 "$H/.config/agterm-qtrc"
printf '[General]\nName=agterm-qt\nParent=FALLBACK/\nTerminalMargin=10\n' > "$H/.local/share/konsole/agterm-qt.profile"

printf '#!/bin/sh\n' > "$H/.local/bin/agterm-qt"
ln -s /nowhere/agtermctl "$H/.local/bin/agtermctl"
cp "$host" "$H/.local/bin/agterm-session-host"
printf '#!/bin/sh\n' > "$H/.local/bin/mine"
printf '[Desktop Entry]\nName=agterm\n' > "$H/.local/share/applications/agterm-qt.desktop"
printf '[Desktop Entry]\nName=other\n' > "$H/.local/share/applications/other.desktop"
printf 'png' > "$H/.local/share/icons/hicolor/64x64/apps/agterm-qt.png"

# a daemon of the migrated state and one of another state dir, which must survive
for s in "$live/s1.main" "$RT/agterm-qt-0ther000/d1.main"; do
    "$H/.local/bin/agterm-session-host" "$s" -- sleep 300 </dev/null >/dev/null 2>&1 &
done
for _ in $(seq 50); do [ -s "$live/s1.main.pid" ] && [ -s "$RT/agterm-qt-0ther000/d1.main.pid" ] && break; sleep 0.1; done
shell=$(cat "$live/s1.main.pid") other=$(cat "$RT/agterm-qt-0ther000/d1.main.pid")
check "fixture daemons run" 'kill -0 "$shell" && kill -0 "$other"'

: > "$H/.local/share/elis/elis.lock"
before=$(snap)
for lock in "$state/agterm.lock" "$H/.local/share/elis/elis.lock"; do
    exec 9<"$lock"
    flock 9
    run
    check "refuses while $(basename "$lock") is held" '[ $code -eq 1 ] && [[ "$out" == Quit* ]] && [ "$(snap)" = "$before" ] && kill -0 "$shell"'
    exec 9<&-
done
rm "$H/.local/share/elis/elis.lock"
before=$(snap)

run
check "first run succeeds" '[ $code -eq 0 ]'
[ $code -eq 0 ] || echo "$out"
check "the state's daemon ended" '! kill -0 "$shell" 2>/dev/null && [ ! -e "$live" ]'
check "another state's daemon survives" 'kill -0 "$other" && [ -S "$RT/agterm-qt-0ther000/d1.main" ]'
new=$H/.local/share/elis
check "windows moved" '[ -f "$new/windows.json" ] && grep -q "\"configDirectory\": \"\"" "$new/windows/w1.json"'
check "window contents are user data" 'grep -q "cd /src/agterm-qt && claude" "$new/windows/w1.json" && grep -q "\"restoreMode\": \"live\"" "$new/windows/w1.json"'
check "phone pairing moved with its mode" '[ "$(cat "$new/mobile/token")" = TOKEN ] && [ "$(stat -c %a "$new/mobile/token")" = 600 ] && [ -f "$new/mobile/cert.pem" ]'
check "Elis install payload untouched" '[ "$(cat "$new/agent-status/elis-agent-status.sh")" = "elis payload" ] && [ ! -e "$new/skill" ]'
check "old state dir removed" '[ ! -e "$state" ]'
check "keymap renamed" 'grep -q "elisctl session focus \"\$ELIS_SESSION_ID\" --socket ~/.local/share/elis/elis.sock" "$H/.config/elis/keymap.conf" &&
    grep -q "\"\$AGT_SESSION_ID\" \"\$ELISCTL\"" "$H/.config/elis/keymap.conf"'
check "hooks renamed and executable" 'grep -q "^on status ~/.config/elis/hooks/status.sh$" "$H/.config/elis/hooks.conf" &&
    [ -x "$H/.config/elis/hooks/status.sh" ] && grep -q "elisctl notify" "$H/.config/elis/hooks/status.sh"'
check "restore denylist moved" '[ "$(cat "$H/.config/elis/restore-denylist.conf")" = vim ]'
check "only the old hook scripts stay in the old config" '[ "$(ls -A "$conf")" = agent-status ]'
check "rc and profile converted" '[ "$(cat "$H/.config/elisrc")" = "$(printf "[Desktop Entry]\nDefaultProfile=elis.profile")" ] &&
    grep -qx Name=elis "$H/.local/share/konsole/elis.profile" && [ ! -e "$H/.config/agterm-qtrc" ] && [ ! -e "$H/.local/share/konsole/agterm-qt.profile" ]'
check "old binaries and link removed" '[ -z "$(ls "$H/.local/bin" | grep agterm)" ] && [ -f "$H/.local/bin/mine" ]'
check "menu entry and icons removed" '[ ! -e "$H/.local/share/applications/agterm-qt.desktop" ] && [ -f "$H/.local/share/applications/other.desktop" ] &&
    [ ! -e "$H/.local/share/icons/hicolor/64x64/apps/agterm-qt.png" ]'
check "menu cache rebuilt once" '[ "$(cat "$root/sycoca.log")" = --noincremental ]'

after=$(snap)
run
check "second run changes nothing" '[ $code -eq 0 ] && [[ "$out" == *"nothing to do"* ]] && [ "$(snap)" = "$after" ] && [ "$(wc -l < "$root/sycoca.log")" = 1 ]'

mkdir -p "$state" && printf 'OLD\n' > "$state/windows.json"
run
check "an Elis window file is never overwritten" '[ $code -eq 0 ] && [ "$(cat "$state/windows.json")" = OLD ] && [ "$(cmp "$new/windows.json" <(echo OLD) 2>/dev/null; echo $?)" != 0 ] &&
    [[ "$out" == *"windows.json already exists"* ]]'

[ $fails -eq 0 ] && echo "all passed" || echo "$fails failed"
[ $fails -eq 0 ]
