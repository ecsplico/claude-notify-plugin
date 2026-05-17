#!/usr/bin/env bash
# SessionStart hook: resolve which VS Code window hosts this session and store
# a wlrctl title-match string at ~/.claude/notification-windows/<session_id>.
# Requires bash 4+ (mapfile).
set -u

map_dir="$HOME/.claude/notification-windows"
suffix=" - Visual Studio Code"

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
cwd=$(printf '%s'        "$input" | jq -r '.cwd // empty'        2>/dev/null)

# session_id is used as a filename — reject anything that is not a plain token.
case "$session_id" in
    "" | */* | *..*) exit 0 ;;
esac

# Prune stale mappings (>7 days), best effort.
[ -d "$map_dir" ] && find "$map_dir" -type f -mtime +7 -delete 2>/dev/null

command -v wlrctl >/dev/null 2>&1 || exit 0

# VS Code toplevel titles, one per line.
mapfile -t titles < <(wlrctl toplevel list 2>/dev/null | sed -n 's/^code: //p')
[ "${#titles[@]}" -gt 0 ] || exit 0

# Derive each title's workspace-name segment. A VS Code title looks like
# "<file> - <workspace> - Visual Studio Code" or "<workspace> - Visual Studio Code";
# the workspace is the last " - "-delimited segment before the app-name suffix.
# Titles with no workspace segment (bare "Visual Studio Code") are dropped.
declare -a ws_names=()
for t in "${titles[@]}"; do
    case "$t" in
        *"$suffix")
            prefix="${t%"$suffix"}"
            ws="${prefix##* - }"
            [ -n "$ws" ] && ws_names+=("$ws")
            ;;
    esac
done
[ "${#ws_names[@]}" -gt 0 ] || exit 0

# cwd-match: a workspace whose name exactly equals a cwd ancestor-dir basename.
# Exact equality (not substring) avoids false hits like "u" matching "Visual".
# Walking up from cwd, the first (deepest, closest to cwd) match wins.
match=""
if [ -n "$cwd" ]; then
    dir="$cwd"
    while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        base=$(basename "$dir")
        for ws in "${ws_names[@]}"; do
            if [ "$ws" = "$base" ]; then
                match="$ws"
                break
            fi
        done
        [ -n "$match" ] && break
        dir=$(dirname "$dir")
    done
fi

[ -n "$match" ] || exit 0

mkdir -p "$map_dir"
printf '%s\n' "${match}${suffix}" > "$map_dir/$session_id"
exit 0
