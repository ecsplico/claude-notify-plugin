#!/usr/bin/env bash
session_id=$(jq -r '.session_id')
# Wait for the current turn to be committed to the transcript before reading.
sleep 1
transcript=$(find ~/.claude/projects -name "${session_id}.jsonl" 2>/dev/null | head -1)
[ -f "$transcript" ] || exit 0

# Get last assistant message that has text content (skip tool-only turns).
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

# Extract only the 4-digit number from custom-title (e.g. "#0001 Some title" -> "0001").
session_num=$(grep '"type":"custom-title"' "$transcript" | tail -1 | jq -r '.customTitle' 2>/dev/null | grep -oP '(?<=^#)\d{4}')
prefix="Claude"
[ -n "$session_num" ] && prefix="Claude ${session_num}"

# Extract ※ recap: marker if present at end of message.
recap=$(echo "$text" | grep -oP '※ recap:\s*\K.+' | tail -1)
if [ -n "$recap" ]; then
    body="re-caps: ${recap}"
    speech="${prefix} re-caps: ${recap}"
else
    body="ready!"
    speech="${prefix} ready!"
fi

# Audio (optional) — no longer aborts the script when 'say' is unavailable.
if [ "${CLAUDE_NOTIFY_AUDIO:-1}" != "0" ] && command -v say >/dev/null 2>&1; then
    say "$speech"
fi

# Desktop notification — `setsid -f` forks the helper into a new session and
# returns immediately, so the helper survives turn end (it blocks waiting for a
# notification click) while this hook exits without waiting.
notify_title="Claude"
[ -n "$session_num" ] && notify_title="Claude #${session_num}"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
setsid -f "${script_dir}/desktop-notify.sh" "$notify_title" "$body" "$session_id" \
    </dev/null >/dev/null 2>&1
exit 0
