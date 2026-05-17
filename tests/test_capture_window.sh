#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib.sh"
SCRIPT="$DIR/../scripts/capture-window.sh"

# wlrctl stub: `toplevel list` prints $WLR_LIST.
wlrctl_stub() {
    stub wlrctl <<EOF
case "\$1 \$2" in
  "toplevel list") printf '%s\n' "$WLR_LIST" ;;
esac
exit 0
EOF
}

# --- unique cwd match -> mapping file holds "<workspace> - Visual Studio Code"
setup_sandbox
WLR_LIST='code: app.js - resona - Visual Studio Code
code: main.py - katrin - Visual Studio Code'
wlrctl_stub
echo '{"session_id":"s1","cwd":"/home/u/projects/resona/src"}' | bash "$SCRIPT"
assert_eq "resona - Visual Studio Code" "$(cat "$HOME/.claude/notification-windows/s1" 2>/dev/null)" \
    "unique cwd match writes workspace match string"
teardown_sandbox

# --- multiple windows sharing the workspace name -> still yields it
setup_sandbox
WLR_LIST='code: a.js - resona - Visual Studio Code
code: b.js - resona - Visual Studio Code'
wlrctl_stub
echo '{"session_id":"s2","cwd":"/home/u/resona"}' | bash "$SCRIPT"
assert_eq "resona - Visual Studio Code" "$(cat "$HOME/.claude/notification-windows/s2" 2>/dev/null)" \
    "multiple same-workspace windows still yield workspace string"
teardown_sandbox

# --- deepest (closest to cwd) matching ancestor wins
setup_sandbox
WLR_LIST='code: x - projects - Visual Studio Code
code: y - resona - Visual Studio Code'
wlrctl_stub
echo '{"session_id":"s3","cwd":"/home/u/projects/resona/src"}' | bash "$SCRIPT"
assert_eq "resona - Visual Studio Code" "$(cat "$HOME/.claude/notification-windows/s3" 2>/dev/null)" \
    "deepest matching ancestor wins"
teardown_sandbox

# --- no cwd match -> no mapping file
setup_sandbox
WLR_LIST='code: a.js - resona - Visual Studio Code'
wlrctl_stub
echo '{"session_id":"s4","cwd":"/home/u/unrelated"}' | bash "$SCRIPT"
assert_file_missing "$HOME/.claude/notification-windows/s4" "no cwd match writes nothing"
teardown_sandbox

# --- absent cwd -> no mapping file
setup_sandbox
WLR_LIST='code: a.js - resona - Visual Studio Code'
wlrctl_stub
echo '{"session_id":"s5"}' | bash "$SCRIPT"
assert_file_missing "$HOME/.claude/notification-windows/s5" "absent cwd writes nothing"
teardown_sandbox

# --- bare "Visual Studio Code" title -> no mapping file
setup_sandbox
WLR_LIST='code: Visual Studio Code'
wlrctl_stub
echo '{"session_id":"s6","cwd":"/home/u/projects"}' | bash "$SCRIPT"
assert_file_missing "$HOME/.claude/notification-windows/s6" "bare VS Code title writes nothing"
teardown_sandbox

# --- session_id with path separators is rejected (no escape from map dir)
setup_sandbox
WLR_LIST='code: a.js - resona - Visual Studio Code'
wlrctl_stub
echo '{"session_id":"../evil","cwd":"/home/u/resona"}' | bash "$SCRIPT"
assert_file_missing "$HOME/.claude/evil" "unsafe session_id is rejected"
teardown_sandbox

# --- prune removes mapping files older than 7 days, keeps fresh ones
setup_sandbox
mkdir -p "$HOME/.claude/notification-windows"
touch -d '10 days ago' "$HOME/.claude/notification-windows/old"
touch "$HOME/.claude/notification-windows/fresh"
WLR_LIST='code: a.js - resona - Visual Studio Code'
wlrctl_stub
echo '{"session_id":"s7","cwd":"/home/u/resona"}' | bash "$SCRIPT"
assert_file_missing "$HOME/.claude/notification-windows/old" "prune removes stale mapping"
assert_eq "0" "$([ -e "$HOME/.claude/notification-windows/fresh" ] && echo 0 || echo 1)" \
    "prune keeps fresh mapping"
teardown_sandbox

finish
