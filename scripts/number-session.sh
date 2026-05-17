#!/usr/bin/env bash
# Assigns a persistent ascending number prepended to the AI-generated session title.
# Runs on Stop (sync) so speak-recap.sh sees the number when it fires next.
session_id=$(jq -r '.session_id')
transcript=$(find ~/.claude/projects -name "${session_id}.jsonl" 2>/dev/null | head -1)
[ -f "$transcript" ] || exit 0

# Get existing custom-title (if any)
existing=$(grep '"type":"custom-title"' "$transcript" | tail -1 | jq -r '.customTitle' 2>/dev/null)

# Already fully titled: "#NNNN <text>" — nothing to do
echo "$existing" | grep -qP '^\#\d{4} .+' && exit 0

# Get AI-generated title (present after first response)
ai_title=$(grep '"type":"ai-title"' "$transcript" | tail -1 | jq -r '.aiTitle' 2>/dev/null)

# Determine session number — reuse existing if already assigned as bare "#NNNN"
if echo "$existing" | grep -qP '^\#\d{4}$'; then
    num=$(echo "$existing" | tr -d '#')
else
    counter_file=~/.claude/session-counter
    n=1
    [ -f "$counter_file" ] && n=$(( $(cat "$counter_file") + 1 ))
    printf '%d' $n > "$counter_file"
    num=$(printf "%04d" $n)
fi

# Build title: prepend number to ai-title if available, else bare number
if [ -n "$ai_title" ] && [ "$ai_title" != "null" ]; then
    new_title="#${num} ${ai_title}"
else
    new_title="#${num}"
fi

jq -cn --arg title "$new_title" --arg sid "$session_id" \
    '{"type":"custom-title","customTitle":$title,"sessionId":$sid}' >> "$transcript"
