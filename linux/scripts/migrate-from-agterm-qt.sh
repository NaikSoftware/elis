#!/usr/bin/env bash
# One-time move from agterm-qt to Elis. Run it after you install Elis, with agterm-qt and Elis both quit.
# It ends the old session daemons (each pane comes back by re-running its command), moves your windows, phone
# pairing and config, and removes what agterm-qt installed. Elis's first start then replaces the agent hooks.
# Safe to run twice. Paths follow HOME, XDG_DATA_HOME, XDG_CONFIG_HOME and XDG_RUNTIME_DIR, as the apps do;
# KBUILDSYCOCA names the menu cache rebuild (default kbuildsycoca6).
set -euo pipefail
case "${1:-}" in
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
esac
command -v flock >/dev/null || { echo "flock (util-linux) is required." >&2; exit 1; }

data=$(printf %s "${XDG_DATA_HOME:-$HOME/.local/share}" | tr -s /)
data=${data%/}
cfg=${XDG_CONFIG_HOME:-$HOME/.config}
old_state=$data/agterm-qt new_state=$data/elis
old_conf=$HOME/.config/agterm-qt new_conf=$HOME/.config/elis
bin=$HOME/.local/bin

did="" left=""
note_did() { did+="  - $1"$'\n'; }
note_left() { left+="  - $1"$'\n'; }
short() { case "$1" in "$HOME"/*) echo "~${1#"$HOME"}" ;; *) echo "$1" ;; esac; }

# Both apps hold a flock on their state dir's lock file while they run: this sees only the state being migrated.
owned() { [ -e "$1" ] && ! flock -n "$1" true 2>/dev/null; }
if owned "$old_state/agterm.lock"; then echo "Quit agterm-qt first, then run this again." >&2; exit 1; fi
if owned "$new_state/elis.lock"; then echo "Quit Elis first, then run this again." >&2; exit 1; fi

# The old daemons listen under <runtime>/agterm-qt-<sha1 of the state dir>; each is ended through its own socket.
live=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/agterm-qt-$(printf %s "$old_state" | sha1sum | cut -c1-8)
if [ -d "$live" ]; then
    host=$bin/agterm-session-host
    [ -x "$host" ] || host=$(command -v elis-session-host || true)
    n=0
    for s in "$live"/*; do
        [ -S "$s" ] || continue
        n=$((n + 1)) code=0
        [ -z "$host" ] || timeout 5 "$host" --kill "$s" >/dev/null 2>&1 || code=$?
        [ $code -ne 1 ] || rm -f "$s" # nothing listens: a crashed daemon's socket
    done
    rm -f "$live"/*.pid "$live"/*.id 2>/dev/null || true
    still=$(find "$live" -mindepth 1 -type s | wc -l)
    rmdir "$live" 2>/dev/null || true
    [ "$n" -gt 0 ] && note_did "end $((n - still)) old session daemons; their panes start again with their commands"
    [ "$still" -gt 0 ] && note_left "$still old session daemons under $live did not stop; end each with elis-session-host --kill <socket>"
fi

moved=()
# move_entries SRC DST SKIP...: what DST already has stays where it is
move_entries() {
    local src=$1 dst=$2 p n
    shift 2
    moved=()
    [ -d "$src" ] || return 0
    mkdir -p "$dst"
    for p in "$src"/* "$src"/.[!.]*; do
        [ -e "$p" ] || [ -L "$p" ] || continue
        n=${p##*/}
        case " $* " in *" $n "*) continue ;; esac
        if [ -e "$dst/$n" ] || [ -L "$dst/$n" ]; then
            note_left "$(short "$dst/$n") already exists, so $(short "$p") stays. Quit Elis, move one of them away and run this again."
        else
            mv "$p" "$dst/$n"
            moved+=("$n")
        fi
    done
}

payload="agterm.lock agterm.sock extras-installed extras-install.log agent-status skill"
# shellcheck disable=SC2086
move_entries "$old_state" "$new_state" $payload
[ ${#moved[@]} -gt 0 ] && note_did "move ${moved[*]} from $(short "$old_state") to $(short "$new_state")"
if [ -d "$old_state" ]; then
    for n in $payload; do rm -rf "${old_state:?}/$n"; done
    rmdir "$old_state" 2>/dev/null && note_did "remove $(short "$old_state")"
fi
for w in "$new_state"/windows/*.json; do
    [ -f "$w" ] || continue
    for old in "~/.config/agterm-qt" "$HOME/.config/agterm-qt"; do
        grep -qF "\"configDirectory\": \"$old\"" "$w" &&
            sed -i "s|\"configDirectory\": \"$(printf %s "$old" | sed 's/[][\.*^$|]/\\&/g')/\{0,1\}\"|\"configDirectory\": \"\"|" "$w"
    done
done

move_entries "$old_conf" "$new_conf" agent-status
[ ${#moved[@]} -gt 0 ] && note_did "move ${moved[*]} from $(short "$old_conf") to $(short "$new_conf")"
names='agtermctl|AGTERM|\.config/agterm-qt\b|\.local/share/agterm-qt\b|agterm\.sock|agterm-session-host'
for n in "${moved[@]}"; do
    while IFS= read -r -d '' f; do
        if [ -L "$f" ]; then
            grep -qE "$names" "$f" 2>/dev/null && note_left "$(short "$f") links to $(readlink "$f"), which still names agterm: rename agtermctl and AGTERM_ in it yourself."
        elif grep -Iq . "$f" && grep -qE "$names" "$f"; then
            sed -i -E 's/agtermctl/elisctl/g; s/AGTERMCTL/ELISCTL/g; s/AGTERM_/ELIS_/g; s#\.config/agterm-qt\b#.config/elis#g;
                s#\.local/share/agterm-qt\b#.local/share/elis#g; s/\bagterm\.sock\b/elis.sock/g; s/\bagterm-session-host\b/elis-session-host/g' "$f"
            note_did "rename agterm names in $(short "$f")"
        fi
    done < <(find "$new_conf/$n" \( -type f -o -type l \) -print0)
done
[ -d "$old_conf" ] && note_left "Delete $(short "$old_conf") once Elis has started: only the old agent hook scripts are left there."

# Konsole part settings: agterm-qtrc names the default profile, which Elis reads from elisrc
if [ -f "$cfg/agterm-qtrc" ]; then
    if [ -e "$cfg/elisrc" ]; then
        note_left "$(short "$cfg/elisrc") already exists, so $(short "$cfg/agterm-qtrc") stays."
    else
        prof=$data/konsole
        if grep -qx 'DefaultProfile=agterm-qt.profile' "$cfg/agterm-qtrc" && [ -f "$prof/agterm-qt.profile" ] && [ ! -e "$prof/elis.profile" ]; then
            mv "$prof/agterm-qt.profile" "$prof/elis.profile"
            sed -i 's/^Name=agterm-qt$/Name=elis/' "$prof/elis.profile"
            note_did "rename the Konsole profile $(short "$prof/agterm-qt.profile") to elis.profile"
        fi
        mv "$cfg/agterm-qtrc" "$cfg/elisrc"
        [ -f "$prof/elis.profile" ] && sed -i 's/^DefaultProfile=agterm-qt\.profile$/DefaultProfile=elis.profile/' "$cfg/elisrc"
        note_did "move $(short "$cfg/agterm-qtrc") to $(short "$cfg/elisrc")"
    fi
fi

for f in "$bin/agterm-qt" "$bin/agtermctl" "$bin/agterm-session-host"; do
    if [ -e "$f" ] || [ -L "$f" ]; then rm -f "$f" && note_did "remove $(short "$f")"; fi
done
menu=0
if [ -f "$data/applications/agterm-qt.desktop" ]; then
    rm -f "$data/applications/agterm-qt.desktop" && menu=1 && note_did "remove the agterm-qt menu entry"
fi
icons=("$data"/icons/hicolor/*/apps/agterm-qt.*)
[ -e "${icons[0]}" ] && rm -f "${icons[@]}" && note_did "remove the agterm-qt icons"
if [ $menu -eq 1 ]; then
    sycoca=${KBUILDSYCOCA:-kbuildsycoca6}
    if "$sycoca" --noincremental >/dev/null 2>&1; then note_did "rebuild the menu cache ($sycoca)"
    else note_left "run kbuildsycoca6 --noincremental so the menu drops agterm-qt"; fi
fi

echo "agterm-qt to Elis migration"
echo
echo "Done:"
if [ -n "$did" ]; then printf '%s' "$did"; else echo "  - nothing to do; it already ran"; fi
echo
echo "Left for you:"
printf '%s' "$left"
cat <<'EOF'
  - Start Elis. It installs elisctl, the agent hooks and the skill, and removes agterm-qt's.
  - Install the Elis phone app and pair it again: its app id and link scheme changed.
  - Your own scripts outside ~/.config/agterm-qt that call agtermctl or read AGTERM_ variables: update them by hand.
EOF
