#!/usr/bin/env bash
session_id=$(jq -r '.session_id // empty')

session_num=""
if [ -n "$session_id" ]; then
    transcript=$(find ~/.claude/projects -name "${session_id}.jsonl" 2>/dev/null | head -1)
    if [ -f "$transcript" ]; then
        session_num=$(grep '"type":"custom-title"' "$transcript" | tail -1 | jq -r '.customTitle' 2>/dev/null | grep -oP '(?<=^#)\d{4}')
    fi
fi

prefix="Claude"
[ -n "$session_num" ] && prefix="Claude ${session_num}"

# Audio (optional) — no longer aborts the script when 'say' is unavailable.
if [ "${CLAUDE_NOTIFY_AUDIO:-1}" != "0" ] && command -v say >/dev/null 2>&1; then
    say "${prefix} needs attention"
fi

# Desktop notification — `setsid -f` forks the helper into a new session and
# returns immediately, so the helper survives turn end (it blocks waiting for a
# notification click) while this hook exits without waiting.
notify_title="Claude"
[ -n "$session_num" ] && notify_title="Claude #${session_num}"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
setsid -f "${script_dir}/desktop-notify.sh" "$notify_title" "needs attention" "$session_id" \
    </dev/null >/dev/null 2>&1
exit 0
