#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib.sh"
SCRIPT="$DIR/../scripts/notify-attention.sh"

write_title() {
    local sid="$1"
    local d="$HOME/.claude/projects/proj"
    mkdir -p "$d"
    printf '%s\n' '{"type":"custom-title","customTitle":"#0007 Some title"}' \
        > "$d/$sid.jsonl"
}

# --- numbered session: audio + helper use "needs attention"
setup_sandbox
write_title s1
stub say    <<'EOF'
exit 0
EOF
stub setsid <<'EOF'
exit 0
EOF
echo '{"session_id":"s1"}' | bash "$SCRIPT"
assert_contains "$(calls_of say)"    "Claude 0007 needs attention" "audio speaks numbered attention"
assert_contains "$(calls_of setsid)" "desktop-notify.sh"           "helper dispatched"
assert_contains "$(calls_of setsid)" "Claude #0007"                "helper gets numbered title"
assert_contains "$(calls_of setsid)" "needs attention"             "helper gets attention body"
teardown_sandbox

# --- CLAUDE_NOTIFY_AUDIO=0: no audio, helper still dispatched
setup_sandbox
write_title s2
stub say    <<'EOF'
exit 0
EOF
stub setsid <<'EOF'
exit 0
EOF
echo '{"session_id":"s2"}' | CLAUDE_NOTIFY_AUDIO=0 bash "$SCRIPT"
assert_eq       "" "$(calls_of say)"               "CLAUDE_NOTIFY_AUDIO=0 suppresses audio"
assert_contains "$(calls_of setsid)" "desktop-notify.sh" "helper still dispatched without audio"
teardown_sandbox

# --- say genuinely unavailable (PATH excludes ~/.local/bin): no abort, helper dispatched
setup_sandbox
write_title s3
stub setsid <<'EOF'
exit 0
EOF
echo '{"session_id":"s3"}' | PATH="$STUBS:/usr/bin:/bin" bash "$SCRIPT"
assert_contains "$(calls_of setsid)" "desktop-notify.sh" "missing say does not abort the script"
teardown_sandbox

finish
