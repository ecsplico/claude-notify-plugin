# Design: Desktop notifications + click-to-focus

**Date:** 2026-05-17
**Status:** Approved (design phase)

## Goal

Extend `claude-notification-plugin` so that, in addition to the existing spoken
audio, Claude Code events raise native Linux desktop notifications. Clicking a
notification focuses the VS Code window that hosts the originating session.

## Target environment

The plugin already targets Linux. This feature is verified against the user's
setup and degrades gracefully elsewhere:

- Wayland session, Budgie desktop, **labwc** compositor (wlroots-based).
- Claude Code runs inside the **VS Code integrated terminal**; VS Code runs
  natively on Wayland (no XWayland).
- `notify-send` 0.8.8 — supports `--action` (clickable notifications).
- `wlrctl` installed at `/usr/bin/wlrctl` — uses the
  `wlr-foreign-toplevel-management` protocol, which labwc implements.
- Each project is opened in its own VS Code window; window titles contain the
  workspace name (e.g. `katrin`, `resona`, `skaile-dev-matthias`).

X11 tools (`wmctrl`, `xdotool`) are **not** used — they cannot see native
Wayland windows.

## Architecture

Four scripts, wired through `hooks/hooks.json`:

| Script | Hook | Sync? | Role |
|---|---|---|---|
| `capture-window.sh` | `SessionStart` | sync | Record which VS Code window hosts the session |
| `speak-recap.sh` | `Stop` | async | Speak (optional) + dispatch desktop notification for turn-finished |
| `notify-attention.sh` | `Notification` | async | Speak (optional) + dispatch desktop notification for needs-attention |
| `desktop-notify.sh` | — (helper) | — | Detached helper: shows the notification, handles the click |

All four scripts live in the plugin's existing `scripts/` directory.
`desktop-notify.sh` is not a hook. It is launched **fully detached** (`setsid`,
stdio redirected to `/dev/null`) by `speak-recap.sh` and `notify-attention.sh`.

This detachment is required: `notify-send --action` blocks until the
notification is clicked or closed, which can be long after the turn ends.
Claude Code does **not** wait for async hooks and may terminate their process
tree at turn/session end. A detached process survives independently, so the
click handler keeps working after the turn is over.

### Data flow

```
SessionStart ── capture-window.sh ──► ~/.claude/notification-windows/<session_id>
                                       (plain file: window-title match string)

Stop/Notification ── speak-recap.sh / notify-attention.sh
       │   (existing transcript-reading logic preserved — see below)
       │
       ├─ say "..."                          (if CLAUDE_NOTIFY_AUDIO != 0 and `say` present)
       └─ setsid desktop-notify.sh "<title>" "<body>" "<session_id>"   (detached)
                │
                └─ notify-send --action="default=..." "<title>" "<body>"   (blocks)
                       │
                       └─ user clicks ──► read ~/.claude/notification-windows/<session_id>
                                          └─ wlrctl toplevel focus app_id:code "title:<match>"
```

`number-session.sh` (existing `Stop` sync hook) is unchanged.

## Components

### `capture-window.sh` (new — SessionStart hook)

Runs on every session start/resume/clear/compact. Steps:

1. Read `session_id`, `cwd`, and `source` from the hook's stdin JSON
   (`source` ∈ `startup` | `resume` | `clear` | `compact`).
2. List VS Code toplevels with `wlrctl toplevel list` and keep the `code:`
   entries (each line is `code: <title>`).
3. Determine the VS Code window for the session:
   - **Primary — cwd match (deterministic, not racy).** Match the basenames of
     `cwd` and its ancestor directories against the `code:` window titles. The
     candidate matching the *deepest* ancestor is the workspace root. cwd-match
     is the primary signal because it does not depend on which window happens
     to be focused when the hook fires.
   - **Tiebreak — active window, `startup` only.** If cwd-match yields more than
     one candidate *and* `source` is `startup`, probe each candidate with
     `wlrctl toplevel find state:active app_id:code "title:<T>"` and pick the
     active one. (`wlrctl toplevel find` cannot print the active toplevel, so it
     is probed per candidate.) Active-window probing is **not** used for
     `resume`/`clear`/`compact`, because the focused window at that moment is
     unrelated to the session. If still ambiguous, pick the deepest-match
     candidate deterministically.
4. Build the **match string** from the chosen window title: split the title on
   ` - `, and take the workspace segment together with the trailing
   `Visual Studio Code` segment — i.e. store `<workspace> - Visual Studio Code`.
   Examples:
   `localhost:4001 (localhost:4001) - skaile-dev-matthias - Visual Studio Code`
   → `skaile-dev-matthias - Visual Studio Code`;
   `resona - Visual Studio Code` → `resona - Visual Studio Code`.
   Keeping the ` - Visual Studio Code` suffix makes the later `wlrctl` substring
   match specific enough that one workspace name being a prefix of another
   (e.g. `skaile` vs `skaile-dev-matthias`) cannot focus the wrong window.
5. Write the match string to `~/.claude/notification-windows/<session_id>`
   (directory created if absent). One plain file per session — no JSON, no write
   races between parallel sessions, consistent with the existing
   `~/.claude/session-counter` style.
6. If no VS Code window can be resolved, or the extracted workspace segment is
   empty / the title is bare `Visual Studio Code` (no folder open), write
   nothing — later focus is then a graceful no-op.
7. Prune: delete files under `~/.claude/notification-windows/` older than 7 days
   (`find ... -mtime +7 -delete`) to bound growth.

The hook always exits 0 so it never blocks session start.

### `speak-recap.sh` (modified — Stop hook)

The existing transcript-reading logic is **preserved unchanged**: read
`session_id` from stdin JSON, `sleep 1`, locate the session transcript under
`~/.claude/projects`, extract the last assistant text via the `tac | jq`
pipeline, derive the `#NNNN` number from the latest `custom-title` line, and
detect the `※ recap:` marker. The message text comes from the transcript file,
**not** from stdin. Only the output stage is restructured:

- The early `exit 0` when `say` is missing is **removed**, so a missing or
  disabled `say` no longer suppresses the desktop notification.
- Audio: speak the existing ready/recap message **only if**
  `CLAUDE_NOTIFY_AUDIO` is unset or not `0`, **and** `say` is on `PATH`.
- Desktop notification: launch `desktop-notify.sh` **detached**
  (`setsid "$CLAUDE_PLUGIN_ROOT/scripts/desktop-notify.sh" "<title>" "<body>" "<session_id>" </dev/null >/dev/null 2>&1 &`),
  passing title `Claude #NNNN` and body `ready!` or `re-caps: <text>`.
  The hook returns immediately; the detached helper owns the rest.

### `notify-attention.sh` (modified — Notification hook)

Same restructuring as `speak-recap.sh`. Note `notify-attention.sh` only reads
the transcript to extract the `#NNNN` number from the latest `custom-title`
line — it has no recap text and does **not** use the `tac | jq` message
pipeline. Existing `session_id` / `#NNNN` logic preserved, early `say`-missing
`exit 0` removed, audio gated on `CLAUDE_NOTIFY_AUDIO`. Launches
`desktop-notify.sh` detached with title `Claude #NNNN` and body
`needs attention`.

### `desktop-notify.sh` (new — detached helper, not a hook)

Invoked detached by the two hook scripts. Arguments: `<title> <body> <session_id>`.

1. If `CLAUDE_NOTIFY_DESKTOP` is `0`, or `notify-send` is not on `PATH`, exit 0.
2. Run `notify-send --app-name="Claude Code" --action="default=Focus window" "<title>" "<body>"`.
   The single `default` action is the notification body click — no extra
   button. `--action` implies `--wait`, so `notify-send` blocks until the
   notification is clicked or closed by the daemon. Because this helper is
   detached, that blocking is harmless.
3. If `notify-send` prints `default` on stdout (body clicked), read
   `~/.claude/notification-windows/<session_id>`; if it exists and is non-empty,
   run `wlrctl toplevel focus app_id:code "title:<match>"`.
4. Missing mapping file, missing `wlrctl`, or non-zero `wlrctl` exit → silent
   no-op. Always exit 0.

### `hooks.json` (modified)

Add a `SessionStart` block running `capture-window.sh` (type `command`, sync).
Existing `Stop` and `Notification` blocks unchanged.

## Configuration

Two environment variables, read by the scripts; both default to enabled:

| Variable | Default | `0` disables |
|---|---|---|
| `CLAUDE_NOTIFY_AUDIO` | enabled | spoken `say` output |
| `CLAUDE_NOTIFY_DESKTOP` | enabled | `notify-send` desktop notifications |

Set in the `env` block of `~/.claude/settings.json`.

`README.md` is updated alongside the code: document both env vars, add
`capture-window.sh` and `desktop-notify.sh` to the "File layout" section, add
the `SessionStart` hook to the wiring description, and note in the
enable/disable section that removing the desktop-notification feature means
dropping the `SessionStart` entry and the `desktop-notify.sh` dispatch.

## Error handling

- All hooks and the helper exit 0 on any failure; audio/notification/focus are
  all best-effort and independent.
- Missing `say` → skip audio, desktop notification still dispatched.
- Missing `notify-send` → `desktop-notify.sh` exits silently; audio unaffected.
- Missing `wlrctl` → desktop notification still shows; click is a no-op.
- No mapping file for the session → click is a no-op.
- `wlrctl toplevel focus` non-zero exit → silent no-op.
- `desktop-notify.sh` runs detached with stdio redirected to `/dev/null`, so its
  failures are invisible to Claude Code by design (the hook already returned).

## Limitations (accepted)

- Focus targets the **VS Code window**, not a specific terminal tab. Multiple
  sessions tabbed inside one window all focus that same window.
- `app_id` is hardcoded `code` (official VS Code). VSCodium / `code-oss` /
  Cursor would require changing the `app_id` value.
- Wayland-only; relies on `wlr-foreign-toplevel-management`. GNOME Wayland and
  other non-wlroots compositors will not support click-to-focus (notifications
  still work).

## Testing

- `capture-window.sh`: with `wlrctl` stubbed on `PATH` to return a fixed
  toplevel list, feed sample stdin JSON and assert the mapping file holds the
  expected `<workspace> - Visual Studio Code` string for (a) a unique cwd-match,
  (b) an ambiguous cwd-match resolved by the `startup` active-window tiebreak,
  and (c) a `resume` source (no active-window probe). Assert no file is written
  for an unresolvable cwd or a bare `Visual Studio Code` title. Assert prune
  removes an old file and keeps a fresh one.
- `speak-recap.sh` / `notify-attention.sh`: with `say` and `desktop-notify.sh`
  stubbed, assert audio fires only when `CLAUDE_NOTIFY_AUDIO != 0` and `say`
  present, and that `desktop-notify.sh` is always invoked detached with the
  expected title/body/session_id arguments.
- `desktop-notify.sh`: with `notify-send` and `wlrctl` stubbed, assert it exits
  early when `CLAUDE_NOTIFY_DESKTOP=0`; assert a `default` line on the stubbed
  `notify-send` stdout triggers a `wlrctl toplevel focus` call with the match
  string from the mapping file; assert no `wlrctl` call when the mapping file is
  absent.
- Manual end-to-end: run a session in a VS Code window, trigger Stop and
  Notification events, confirm the notification appears and clicking it raises
  the correct window — including a click made after the turn has ended.

## Out of scope

- Per-terminal-tab focus inside a VS Code window.
- X11 / non-wlroots compositor support for click-to-focus.
- A standalone (non-VS-Code) terminal workflow.
