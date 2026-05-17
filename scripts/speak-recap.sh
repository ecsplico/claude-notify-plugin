#!/usr/bin/env bash
command -v say &>/dev/null || { echo "claude-notification-plugin: 'say' not found — install a TTS backend (e.g. spd-say, mimic3, piper) and symlink it to say" >&2; exit 0; }
session_id=$(jq -r '.session_id')
# Wait for the current turn to be committed to the transcript before reading
sleep 1
transcript=$(find ~/.claude/projects -name "${session_id}.jsonl" 2>/dev/null | head -1)
[ -f "$transcript" ] || exit 0

# Get last assistant message that has text content (skip tool-only turns)
text=$(tac "$transcript" | jq -rn '
  first(
    inputs
    | select(.type == "assistant")
    | .message.content
    | if type == "array" then map(select(.type == "text") | .text) | join("\n") else . end
    | select(length > 0)
  )
' 2>/dev/null)
if [ -z "$text" ] || [ "$text" = "null" ]; then exit 0; fi

# Extract only the 4-digit number from custom-title (e.g. "#0001 Some title" → "0001")
session_num=$(grep '"type":"custom-title"' "$transcript" | tail -1 | jq -r '.customTitle' 2>/dev/null | grep -oP '(?<=^#)\d{4}')
prefix="Claude"
[ -n "$session_num" ] && prefix="Claude ${session_num}"

# Extract ※ recap: marker if present at end of message
recap=$(echo "$text" | grep -oP '※ recap:\s*\K.+' | tail -1)
if [ -n "$recap" ]; then
    say "${prefix} re-caps: ${recap}"
else
    say "${prefix} ready!"
fi
