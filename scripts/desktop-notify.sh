#!/usr/bin/env bash
# Detached helper: show a desktop notification; on click, focus the session's
# VS Code window. Args: <title> <body> <session_id>
# Launched detached (setsid) by the Stop/Notification hook scripts so it
# survives turn end while waiting for a click.
set -u

title="${1:-Claude Code}"
body="${2:-}"
session_id="${3:-}"

[ "${CLAUDE_NOTIFY_DESKTOP:-1}" != "0" ] || exit 0
command -v notify-send >/dev/null 2>&1 || exit 0

# --action implies --wait: notify-send blocks until the notification is
# clicked or closed, then prints the chosen action name ("default") on stdout.
action=$(notify-send --app-name="Claude Code" \
                     --action="default=Focus window" \
                     "$title" "$body" 2>/dev/null)

[ "$action" = "default" ] || exit 0

# session_id is used as a filename — ignore anything that is not a plain token.
case "$session_id" in
    "" | */* | *..*) exit 0 ;;
esac

map_file="$HOME/.claude/notification-windows/$session_id"
[ -s "$map_file" ] || exit 0
command -v wlrctl >/dev/null 2>&1 || exit 0

stored=$(head -n1 "$map_file")
[ -n "$stored" ] || exit 0

# VS Code prepends the active filename to the title, so the stored workspace
# key ("ws - Visual Studio Code") may not be the current verbatim title.
# Resolve the live full title by substring-matching against all code toplevels.
current_title=$(wlrctl toplevel list 2>/dev/null \
    | sed -n 's/^code: //p' \
    | grep -F "$stored" \
    | head -n1)
[ -n "$current_title" ] || exit 0
wlrctl toplevel focus app_id:code "title:$current_title" 2>/dev/null || true
exit 0
