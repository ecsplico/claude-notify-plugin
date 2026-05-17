#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib.sh"
SCRIPT="$DIR/../scripts/speak-recap.sh"

# write_transcript <session_id> <assistant_text> -- create a fake transcript
# with a custom-title line (#0001) and one assistant text message.
write_transcript() {
    local sid="$1" text="$2"
    local d="$HOME/.claude/projects/proj"
    mkdir -p "$d"
    {
        printf '%s\n' '{"type":"custom-title","customTitle":"#0001 Some title"}'
        jq -cn --arg t "$text" \
            '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'
    } > "$d/$sid.jsonl"
}

# --- recap marker: audio speaks recap, helper dispatched with recap body
setup_sandbox
write_transcript s1 'did the thing
※ recap: fixed the bug'
stub sleep   <<'EOF'
exit 0
EOF
stub say     <<'EOF'
exit 0
EOF
stub setsid  <<'EOF'
exit 0
EOF
echo '{"session_id":"s1"}' | bash "$SCRIPT"
assert_contains "$(calls_of say)"    "Claude 0001 re-caps: fixed the bug" "audio speaks recap"
assert_contains "$(calls_of setsid)" "desktop-notify.sh"                  "helper dispatched"
assert_contains "$(calls_of setsid)" "Claude #0001"                       "helper gets numbered title"
assert_contains "$(calls_of setsid)" "re-caps: fixed the bug"             "helper gets recap body"
assert_contains "$(calls_of setsid)" "s1"                                 "helper gets session_id"
teardown_sandbox

# --- no recap marker: audio + helper use "ready!"
setup_sandbox
write_transcript s2 'just some normal output'
stub sleep  <<'EOF'
exit 0
EOF
stub say    <<'EOF'
exit 0
EOF
stub setsid <<'EOF'
exit 0
EOF
echo '{"session_id":"s2"}' | bash "$SCRIPT"
assert_contains "$(calls_of say)"    "Claude 0001 ready!" "audio speaks ready"
assert_contains "$(calls_of setsid)" "ready!"             "helper gets ready body"
teardown_sandbox

# --- CLAUDE_NOTIFY_AUDIO=0: no audio, helper still dispatched
setup_sandbox
write_transcript s3 'output here'
stub sleep  <<'EOF'
exit 0
EOF
stub say    <<'EOF'
exit 0
EOF
stub setsid <<'EOF'
exit 0
EOF
echo '{"session_id":"s3"}' | CLAUDE_NOTIFY_AUDIO=0 bash "$SCRIPT"
assert_eq       "" "$(calls_of say)"               "CLAUDE_NOTIFY_AUDIO=0 suppresses audio"
assert_contains "$(calls_of setsid)" "desktop-notify.sh" "helper still dispatched without audio"
teardown_sandbox

# --- say genuinely unavailable (PATH excludes ~/.local/bin): no abort, helper dispatched
setup_sandbox
write_transcript s4 'output here'
stub sleep  <<'EOF'
exit 0
EOF
stub setsid <<'EOF'
exit 0
EOF
echo '{"session_id":"s4"}' | PATH="$STUBS:/usr/bin:/bin" bash "$SCRIPT"
assert_contains "$(calls_of setsid)" "desktop-notify.sh" "missing say does not abort the script"
teardown_sandbox

# --- tool-only final turn (no assistant text): still notifies with "ready!"
setup_sandbox
mkdir -p "$HOME/.claude/projects/proj"
{
    printf '%s\n' '{"type":"custom-title","customTitle":"#0001 Some title"}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}'
} > "$HOME/.claude/projects/proj/s5.jsonl"
stub sleep  <<'EOF'
exit 0
EOF
stub say    <<'EOF'
exit 0
EOF
stub setsid <<'EOF'
exit 0
EOF
echo '{"session_id":"s5"}' | bash "$SCRIPT"
assert_contains "$(calls_of setsid)" "ready!"             "tool-only turn still dispatches ready notification"
assert_contains "$(calls_of say)"    "Claude 0001 ready!" "tool-only turn still speaks ready"
teardown_sandbox

finish
