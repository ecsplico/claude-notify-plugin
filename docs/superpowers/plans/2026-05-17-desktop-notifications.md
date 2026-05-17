# Desktop Notifications + Click-to-Focus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native Linux desktop notifications to `claude-notification-plugin`, where clicking a notification focuses the VS Code window hosting the originating Claude Code session.

**Architecture:** A new `SessionStart` hook (`capture-window.sh`) records which VS Code window hosts each session into a per-session file under `~/.claude/notification-windows/`. The existing `Stop`/`Notification` hook scripts keep their transcript-reading and audio logic (audio now gated on an env var) and additionally launch a fully detached helper (`desktop-notify.sh`) that shows the notification via `notify-send --action` and, on click, focuses the right window via `wlrctl`. Detachment is mandatory because Claude Code may terminate async-hook process trees at turn end.

**Tech Stack:** Bash, `jq`, `wlrctl` (wlr-foreign-toplevel-management), `notify-send` (libnotify), `setsid` (util-linux). Tests are plain bash with stubbed binaries — no test framework dependency.

**Spec:** `docs/superpowers/specs/2026-05-17-desktop-notifications-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `tests/lib.sh` | Create | Test helpers: sandbox, stubs, assertions |
| `tests/run.sh` | Create | Runs every `tests/test_*.sh`, reports pass/fail |
| `tests/test_capture_window.sh` | Create | Tests for `capture-window.sh` |
| `tests/test_desktop_notify.sh` | Create | Tests for `desktop-notify.sh` |
| `tests/test_speak_recap.sh` | Create | Tests for `speak-recap.sh` |
| `tests/test_notify_attention.sh` | Create | Tests for `notify-attention.sh` |
| `scripts/capture-window.sh` | Create | `SessionStart` hook — resolve + store the session's VS Code window |
| `scripts/desktop-notify.sh` | Create | Detached helper — show notification, focus on click |
| `scripts/speak-recap.sh` | Modify | Keep transcript/audio logic; gate audio; dispatch detached helper |
| `scripts/notify-attention.sh` | Modify | Same restructuring as `speak-recap.sh` |
| `hooks/hooks.json` | Modify | Add `SessionStart` → `capture-window.sh` |
| `README.md` | Modify | Document new scripts, hook, env vars |

All scripts are `chmod +x`. The two new hook/helper scripts go in `scripts/` alongside the existing three.

---

## Task 1: Test harness

**Files:**
- Create: `tests/lib.sh`
- Create: `tests/run.sh`

This task builds infrastructure used by every later test. No TDD cycle — it is verified by being exercised in Task 2.

- [ ] **Step 1: Write `tests/lib.sh`**

```bash
#!/usr/bin/env bash
# Minimal bash test helpers: sandboxed HOME, stubbed binaries, assertions.

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

# setup_sandbox — fresh temp HOME + stub bin dir on PATH. Call before each test.
setup_sandbox() {
    SANDBOX=$(mktemp -d)
    STUBS="$SANDBOX/bin"
    STUB_LOG="$SANDBOX/log"
    mkdir -p "$STUBS" "$STUB_LOG" "$SANDBOX/home"
    export HOME="$SANDBOX/home"
    export PATH="$STUBS:$PATH"
}

# teardown_sandbox — remove the temp tree.
teardown_sandbox() {
    [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

# stub <name> — install an executable stub on PATH. Stub body is read from
# stdin; argv is logged (one space-joined line per call) to $STUB_LOG/<name>.calls
# before the body runs.
stub() {
    local name="$1"
    {
        echo '#!/usr/bin/env bash'
        echo "printf '%s\\n' \"\$*\" >> \"$STUB_LOG/$name.calls\""
        cat
    } > "$STUBS/$name"
    chmod +x "$STUBS/$name"
}

# calls_of <name> — print the logged calls for a stub (empty if never called).
calls_of() {
    cat "$STUB_LOG/$1.calls" 2>/dev/null || true
}

assert_eq() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$1" = "$2" ]; then
        echo "  ok: $3"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: $3"
        echo "    expected: [$1]"
        echo "    actual:   [$2]"
    fi
}

assert_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$1" | grep -qF -- "$2"; then
        echo "  ok: $3"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: $3"
        echo "    haystack: [$1]"
        echo "    needle:   [$2]"
    fi
}

assert_not_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$1" | grep -qF -- "$2"; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: $3"
        echo "    unexpectedly found: [$2]"
    else
        echo "  ok: $3"
    fi
}

assert_file_missing() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -e "$1" ]; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL: $2 (file exists: $1)"
    else
        echo "  ok: $2"
    fi
}

# finish — print summary and set exit status. Call at end of each test file.
finish() {
    echo "--- $TESTS_RUN run, $TESTS_FAILED failed ---"
    [ "$TESTS_FAILED" -eq 0 ]
}
```

- [ ] **Step 2: Write `tests/run.sh`**

```bash
#!/usr/bin/env bash
# Runs every tests/test_*.sh and aggregates the result.
set -u
cd "$(dirname "$0")"
rc=0
for t in test_*.sh; do
    [ -e "$t" ] || continue
    echo "=== $t ==="
    bash "$t" || rc=1
done
exit $rc
```

- [ ] **Step 3: Make the harness executable**

Run: `chmod +x tests/lib.sh tests/run.sh`

- [ ] **Step 4: Verify the runner is a no-op when no tests exist yet**

Run: `bash tests/run.sh; echo "exit=$?"`
Expected: no `=== ... ===` lines, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add tests/lib.sh tests/run.sh
git commit -m "test: add bash test harness (sandbox, stubs, assertions)"
```

---

## Task 2: `capture-window.sh` — SessionStart hook

**Files:**
- Create: `scripts/capture-window.sh`
- Test: `tests/test_capture_window.sh`

Resolves which VS Code window hosts the session and writes a `wlrctl` title-match string to `~/.claude/notification-windows/<session_id>`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_capture_window.sh`:

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/lib.sh"
SCRIPT="$DIR/../scripts/capture-window.sh"

# wlrctl stub: `list` prints $WLR_LIST; `find ... title:T` exits 0 iff T == $WLR_ACTIVE.
wlrctl_stub() {
    stub wlrctl <<EOF
case "\$1 \$2" in
  "toplevel list") printf '%s\n' "$WLR_LIST" ;;
  "toplevel find")
    for a in "\$@"; do
      case "\$a" in title:*) [ "\${a#title:}" = "$WLR_ACTIVE" ] && exit 0 ;; esac
    done
    exit 1 ;;
esac
exit 0
EOF
}

# --- unique cwd match -> mapping file holds "<workspace> - Visual Studio Code"
setup_sandbox
WLR_LIST='code: app.js - resona - Visual Studio Code
code: main.py - katrin - Visual Studio Code'
WLR_ACTIVE=""
wlrctl_stub
echo '{"session_id":"s1","cwd":"/home/u/projects/resona/src","source":"startup"}' \
    | bash "$SCRIPT"
assert_eq "resona - Visual Studio Code" "$(cat "$HOME/.claude/notification-windows/s1" 2>/dev/null)" \
    "unique cwd match writes workspace match string"
teardown_sandbox

# --- ambiguous cwd match on startup -> active-window tiebreak
setup_sandbox
WLR_LIST='code: a.js - resona - Visual Studio Code
code: b.js - resona - Visual Studio Code'
WLR_ACTIVE='b.js - resona - Visual Studio Code'
wlrctl_stub
echo '{"session_id":"s2","cwd":"/home/u/resona","source":"startup"}' | bash "$SCRIPT"
assert_eq "resona - Visual Studio Code" "$(cat "$HOME/.claude/notification-windows/s2" 2>/dev/null)" \
    "ambiguous match resolved on startup still yields workspace string"
teardown_sandbox

# --- resume source: no active-window probe is performed
setup_sandbox
WLR_LIST='code: a.js - resona - Visual Studio Code'
WLR_ACTIVE='a.js - resona - Visual Studio Code'
wlrctl_stub
echo '{"session_id":"s3","cwd":"/home/u/resona","source":"resume"}' | bash "$SCRIPT"
assert_not_contains "$(calls_of wlrctl)" "find" "resume source does not probe active window"
teardown_sandbox

# --- no cwd match -> no mapping file
setup_sandbox
WLR_LIST='code: a.js - resona - Visual Studio Code'
WLR_ACTIVE=""
wlrctl_stub
echo '{"session_id":"s4","cwd":"/home/u/unrelated","source":"startup"}' | bash "$SCRIPT"
assert_file_missing "$HOME/.claude/notification-windows/s4" "no cwd match writes nothing"
teardown_sandbox

# --- bare "Visual Studio Code" title -> no mapping file
setup_sandbox
WLR_LIST='code: Visual Studio Code'
WLR_ACTIVE=""
wlrctl_stub
echo '{"session_id":"s5","cwd":"/home/u/projects","source":"startup"}' | bash "$SCRIPT"
assert_file_missing "$HOME/.claude/notification-windows/s5" "bare VS Code title writes nothing"
teardown_sandbox

# --- prune removes mapping files older than 7 days, keeps fresh ones
setup_sandbox
mkdir -p "$HOME/.claude/notification-windows"
touch -d '10 days ago' "$HOME/.claude/notification-windows/old"
touch "$HOME/.claude/notification-windows/fresh"
WLR_LIST='code: a.js - resona - Visual Studio Code'
WLR_ACTIVE=""
wlrctl_stub
echo '{"session_id":"s6","cwd":"/home/u/resona","source":"startup"}' | bash "$SCRIPT"
assert_file_missing "$HOME/.claude/notification-windows/old" "prune removes stale mapping"
assert_eq "0" "$([ -e "$HOME/.claude/notification-windows/fresh" ] && echo 0 || echo 1)" \
    "prune keeps fresh mapping"
teardown_sandbox

finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `chmod +x tests/test_capture_window.sh && bash tests/test_capture_window.sh`
Expected: FAIL — `scripts/capture-window.sh` does not exist (`bash: .../capture-window.sh: No such file or directory`).

- [ ] **Step 3: Write `scripts/capture-window.sh`**

```bash
#!/usr/bin/env bash
# SessionStart hook: resolve which VS Code window hosts this session and store
# a wlrctl title-match string at ~/.claude/notification-windows/<session_id>.
set -u

map_dir="$HOME/.claude/notification-windows"

# Prune stale mappings (>7 days), best effort.
[ -d "$map_dir" ] && find "$map_dir" -type f -mtime +7 -delete 2>/dev/null

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
cwd=$(printf '%s'        "$input" | jq -r '.cwd // empty'        2>/dev/null)
source=$(printf '%s'     "$input" | jq -r '.source // empty'     2>/dev/null)

[ -n "$session_id" ] || exit 0
command -v wlrctl >/dev/null 2>&1 || exit 0

# VS Code toplevel titles, one per line.
mapfile -t titles < <(wlrctl toplevel list 2>/dev/null | sed -n 's/^code: //p')
[ "${#titles[@]}" -gt 0 ] || exit 0

# cwd-match: titles containing an ancestor-dir basename; deepest (closest to
# cwd, i.e. smallest depth) wins. Collect all candidates at the best depth.
declare -a candidates=()
best_depth=-1
if [ -n "$cwd" ]; then
    dir="$cwd"; depth=0
    while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        base=$(basename "$dir")
        if [ -n "$base" ]; then
            for t in "${titles[@]}"; do
                if [ "${t#*"$base"}" != "$t" ]; then
                    if [ "$best_depth" -eq -1 ] || [ "$depth" -lt "$best_depth" ]; then
                        best_depth=$depth; candidates=("$t")
                    elif [ "$depth" -eq "$best_depth" ]; then
                        candidates+=("$t")
                    fi
                fi
            done
        fi
        dir=$(dirname "$dir"); depth=$((depth + 1))
    done
fi

[ "${#candidates[@]}" -gt 0 ] || exit 0

# Choose a window.
chosen=""
if [ "${#candidates[@]}" -eq 1 ]; then
    chosen="${candidates[0]}"
else
    # Tiebreak: active window, but only at startup (focus is meaningless on
    # resume/clear/compact).
    if [ "$source" = "startup" ]; then
        for t in "${candidates[@]}"; do
            if wlrctl toplevel find state:active app_id:code "title:$t" 2>/dev/null; then
                chosen="$t"; break
            fi
        done
    fi
    # Deterministic fallback: first deepest-match candidate.
    [ -n "$chosen" ] || chosen="${candidates[0]}"
fi

# Extract "<workspace> - Visual Studio Code" from the chosen title.
suffix=" - Visual Studio Code"
case "$chosen" in
    *"$suffix")
        prefix="${chosen%"$suffix"}"
        workspace="${prefix##* - }"
        ;;
    *)
        workspace=""
        ;;
esac
[ -n "$workspace" ] || exit 0

mkdir -p "$map_dir"
printf '%s\n' "${workspace}${suffix}" > "$map_dir/$session_id"
exit 0
```

- [ ] **Step 4: Make it executable and run the test to verify it passes**

Run: `chmod +x scripts/capture-window.sh && bash tests/test_capture_window.sh`
Expected: PASS — `--- 7 run, 0 failed ---`.

- [ ] **Step 5: Commit**

```bash
git add scripts/capture-window.sh tests/test_capture_window.sh
git commit -m "feat: add capture-window.sh SessionStart hook"
```

---

## Task 3: `desktop-notify.sh` — detached notification helper

**Files:**
- Create: `scripts/desktop-notify.sh`
- Test: `tests/test_desktop_notify.sh`

Shows the notification and, when the body is clicked, focuses the session's VS Code window.

- [ ] **Step 1: Write the failing test**

Create `tests/test_desktop_notify.sh`:

```bash
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

finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `chmod +x tests/test_desktop_notify.sh && bash tests/test_desktop_notify.sh`
Expected: FAIL — `scripts/desktop-notify.sh` does not exist.

- [ ] **Step 3: Write `scripts/desktop-notify.sh`**

```bash
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

map_file="$HOME/.claude/notification-windows/$session_id"
[ -s "$map_file" ] || exit 0
command -v wlrctl >/dev/null 2>&1 || exit 0

match=$(head -n1 "$map_file")
[ -n "$match" ] || exit 0
wlrctl toplevel focus app_id:code "title:$match" 2>/dev/null || true
exit 0
```

- [ ] **Step 4: Make it executable and run the test to verify it passes**

Run: `chmod +x scripts/desktop-notify.sh && bash tests/test_desktop_notify.sh`
Expected: PASS — `--- 5 run, 0 failed ---`.

- [ ] **Step 5: Commit**

```bash
git add scripts/desktop-notify.sh tests/test_desktop_notify.sh
git commit -m "feat: add desktop-notify.sh detached notification helper"
```

---

## Task 4: Modify `speak-recap.sh`

**Files:**
- Modify: `scripts/speak-recap.sh`
- Test: `tests/test_speak_recap.sh`

Keep the existing transcript-reading logic; remove the early `exit 0` when `say` is missing; gate audio on `CLAUDE_NOTIFY_AUDIO`; dispatch the detached helper.

- [ ] **Step 1: Write the failing test**

Create `tests/test_speak_recap.sh`:

```bash
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

# --- say missing: no early exit, helper still dispatched
setup_sandbox
write_transcript s4 'output here'
stub sleep  <<'EOF'
exit 0
EOF
stub setsid <<'EOF'
exit 0
EOF
echo '{"session_id":"s4"}' | bash "$SCRIPT"
assert_contains "$(calls_of setsid)" "desktop-notify.sh" "missing say does not abort the script"
teardown_sandbox

finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `chmod +x tests/test_speak_recap.sh && bash tests/test_speak_recap.sh`
Expected: FAIL — the current script exits early when `say` is absent and never calls `setsid`, so the `setsid` assertions fail (and pass only by accident where `say` is stubbed). At minimum the "say missing" and `CLAUDE_NOTIFY_AUDIO=0` cases fail.

- [ ] **Step 3: Replace `scripts/speak-recap.sh` with the new version**

```bash
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

# Desktop notification — launched fully detached so it survives turn end.
notify_title="Claude"
[ -n "$session_num" ] && notify_title="Claude #${session_num}"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
setsid "${script_dir}/desktop-notify.sh" "$notify_title" "$body" "$session_id" \
    </dev/null >/dev/null 2>&1 &
exit 0
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_speak_recap.sh`
Expected: PASS — `--- 11 run, 0 failed ---`.

- [ ] **Step 5: Commit**

```bash
git add scripts/speak-recap.sh tests/test_speak_recap.sh
git commit -m "feat: speak-recap dispatches detached desktop notification"
```

---

## Task 5: Modify `notify-attention.sh`

**Files:**
- Modify: `scripts/notify-attention.sh`
- Test: `tests/test_notify_attention.sh`

Same restructuring. `notify-attention.sh` only reads the transcript to extract the `#NNNN` number (no recap text).

- [ ] **Step 1: Write the failing test**

Create `tests/test_notify_attention.sh`:

```bash
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

# --- say missing: no early exit, helper still dispatched
setup_sandbox
write_title s3
stub setsid <<'EOF'
exit 0
EOF
echo '{"session_id":"s3"}' | bash "$SCRIPT"
assert_contains "$(calls_of setsid)" "desktop-notify.sh" "missing say does not abort the script"
teardown_sandbox

finish
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `chmod +x tests/test_notify_attention.sh && bash tests/test_notify_attention.sh`
Expected: FAIL — the current script exits early when `say` is missing and never calls `setsid`.

- [ ] **Step 3: Replace `scripts/notify-attention.sh` with the new version**

```bash
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

# Desktop notification — launched fully detached so it survives turn end.
notify_title="Claude"
[ -n "$session_num" ] && notify_title="Claude #${session_num}"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
setsid "${script_dir}/desktop-notify.sh" "$notify_title" "needs attention" "$session_id" \
    </dev/null >/dev/null 2>&1 &
exit 0
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_notify_attention.sh`
Expected: PASS — `--- 8 run, 0 failed ---`.

- [ ] **Step 5: Commit**

```bash
git add scripts/notify-attention.sh tests/test_notify_attention.sh
git commit -m "feat: notify-attention dispatches detached desktop notification"
```

---

## Task 6: Wire the `SessionStart` hook and update docs

**Files:**
- Modify: `hooks/hooks.json`
- Modify: `README.md`

No automated test — verified by `jq` validity and inspection.

- [ ] **Step 1: Add the `SessionStart` block to `hooks/hooks.json`**

Add this entry as a sibling of the existing `Stop` and `Notification` keys inside `"hooks"`:

```json
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/capture-window.sh"
          }
        ]
      }
    ]
```

The full resulting `hooks/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/capture-window.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/number-session.sh"
          },
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/speak-recap.sh",
            "async": true
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/notify-attention.sh",
            "async": true
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Verify the JSON is valid**

Run: `jq . hooks/hooks.json >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: Update `README.md`**

Make these edits to `README.md`:

1. **Intro paragraph** — add a sentence that the plugin now also raises native
   desktop notifications which focus the originating VS Code window when clicked.

2. **"What it does" table** — add a column or note that each event also raises a
   desktop notification (clickable to focus the window).

3. **New "Desktop notifications" section** — explain:
   - Requires `notify-send` (libnotify) and, for click-to-focus, `wlrctl` on a
     wlroots-based Wayland compositor.
   - Click-to-focus targets the VS Code window hosting the session; it cannot
     switch to a specific terminal tab within a window.
   - `app_id` is hardcoded `code` (official VS Code); VSCodium/Cursor need a
     tweak in `desktop-notify.sh` and `capture-window.sh`.

4. **New "Configuration" subsection** — document the env vars (set in the `env`
   block of `~/.claude/settings.json`):

   | Variable | Default | Set to `0` to |
   |---|---|---|
   | `CLAUDE_NOTIFY_AUDIO` | enabled | disable spoken audio |
   | `CLAUDE_NOTIFY_DESKTOP` | enabled | disable desktop notifications |

5. **"File layout"** — add `capture-window.sh` (SessionStart hook) and
   `desktop-notify.sh` (detached helper) to the tree.

6. **Enable/disable section** — note that to drop the desktop-notification
   feature you remove the `SessionStart` hook entry; per-session window mappings
   live in `~/.claude/notification-windows/` and auto-prune after 7 days.

- [ ] **Step 4: Run the full test suite**

Run: `bash tests/run.sh; echo "exit=$?"`
Expected: every `test_*.sh` reports `0 failed`, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add hooks/hooks.json README.md
git commit -m "feat: wire SessionStart hook and document desktop notifications"
```

---

## Final verification

- [ ] Run `bash tests/run.sh` — all suites pass.
- [ ] Run `jq . hooks/hooks.json` — valid JSON.
- [ ] Confirm `scripts/capture-window.sh` and `scripts/desktop-notify.sh` are executable (`ls -l scripts/`).
- [ ] Manual end-to-end (cannot be automated): in a VS Code window, trigger a Stop event and a Notification event; confirm a desktop notification appears and clicking it raises the correct VS Code window — including a click made after the turn has ended.
