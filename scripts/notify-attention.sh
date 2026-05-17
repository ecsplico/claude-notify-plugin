#!/usr/bin/env bash
command -v say &>/dev/null || { echo "claude-notification-plugin: 'say' not found — install a TTS backend (e.g. spd-say, mimic3, piper) and symlink it to say" >&2; exit 0; }
session_id=$(jq -r '.session_id // empty')

session_num=""
if [ -n "$session_id" ]; then
    transcript=$(find ~/.claude/projects -name "${session_id}.jsonl" 2>/dev/null | head -1)
    if [ -f "$transcript" ]; then
        session_num=$(grep '"type":"custom-title"' "$transcript" | tail -1 | jq -r '.customTitle' 2>/dev/null | grep -oP '(?<=^#)\d{4}')
    fi
fi

if [ -n "$session_num" ]; then
    say "Claude ${session_num} needs attention"
else
    say "Claude needs attention"
fi
