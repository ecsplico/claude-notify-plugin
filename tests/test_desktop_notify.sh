#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib.sh"
SCRIPT="$DIR/../scripts/desktop-notify.sh"

# --- click (notify-send prints "default") -> wlrctl focus with stored match
setup_sandbox
mkdir -p "$HOME/.claude/notification-windows"
echo "resona - Visual Studio Code" > "$HOME/.claude/notification-windows/s1"
stub notify-send <<'EOF'
echo "default"
EOF
stub wlrctl <<'EOF'
exit 0
EOF
bash "$SCRIPT" "Claude #0001" "ready!" "s1"
assert_contains "$(calls_of notify-send)" "Claude #0001" "notify-send invoked with title"
assert_contains "$(calls_of notify-send)" "ready!" "notify-send invoked with body"
assert_contains "$(calls_of wlrctl)" "title:resona - Visual Studio Code" \
    "click focuses window via stored match string"
teardown_sandbox

# --- no click (notify-send prints nothing) -> no wlrctl call
setup_sandbox
mkdir -p "$HOME/.claude/notification-windows"
echo "resona - Visual Studio Code" > "$HOME/.claude/notification-windows/s2"
stub notify-send <<'EOF'
exit 0
EOF
stub wlrctl <<'EOF'
exit 0
EOF
bash "$SCRIPT" "Claude #0002" "ready!" "s2"
assert_eq "" "$(calls_of wlrctl)" "no click -> wlrctl not invoked"
teardown_sandbox

# --- click but no mapping file -> no wlrctl call
setup_sandbox
stub notify-send <<'EOF'
echo "default"
EOF
stub wlrctl <<'EOF'
exit 0
EOF
bash "$SCRIPT" "Claude" "needs attention" "missing"
assert_eq "" "$(calls_of wlrctl)" "missing mapping file -> wlrctl not invoked"
teardown_sandbox

# --- CLAUDE_NOTIFY_DESKTOP=0 -> notify-send not invoked at all
setup_sandbox
stub notify-send <<'EOF'
echo "default"
EOF
CLAUDE_NOTIFY_DESKTOP=0 bash "$SCRIPT" "Claude" "ready!" "s4"
assert_eq "" "$(calls_of notify-send)" "CLAUDE_NOTIFY_DESKTOP=0 suppresses notification"
teardown_sandbox

# --- click with unsafe session_id -> no wlrctl call (path-traversal guard)
setup_sandbox
stub notify-send <<'EOF'
echo "default"
EOF
stub wlrctl <<'EOF'
exit 0
EOF
bash "$SCRIPT" "Claude" "ready!" "../../etc/hostname"
assert_eq "" "$(calls_of wlrctl)" "unsafe session_id -> wlrctl not invoked"
teardown_sandbox

# --- notify-send absent from PATH -> exits silently, no focus attempt
setup_sandbox
mkdir -p "$HOME/.claude/notification-windows"
echo "resona - Visual Studio Code" > "$HOME/.claude/notification-windows/s9"
stub wlrctl <<'EOF'
exit 0
EOF
# Run with PATH restricted to the stub dir, so notify-send cannot be found.
# desktop-notify.sh uses only shell builtins before its notify-send guard,
# so it exits cleanly without needing any external binary.
PATH="$STUBS" /usr/bin/bash "$SCRIPT" "Claude" "ready!" "s9"
rc=$?
assert_eq "0" "$rc" "missing notify-send -> exits 0"
assert_eq "" "$(calls_of wlrctl)" "missing notify-send -> no focus attempt"
teardown_sandbox

finish
