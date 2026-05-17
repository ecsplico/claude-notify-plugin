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

Three scripts, wired through `hooks/hooks.json`:

| Script | Hook | Sync? | Role |
|---|---|---|---|
| `capture-window.sh` | `SessionStart` | sync | Record which VS Code window hosts the session |
| `speak-recap.sh` | `Stop` | async | Speak (optional) + desktop notification for turn-finished |
| `notify-attention.sh` | `Notification` | async | Speak (optional) + desktop notification for needs-attention |

`number-session.sh` (existing `Stop` sync hook) is unchanged.

### Data flow

```
SessionStart ── capture-window.sh ──► ~/.claude/notification-windows/<session_id>
                                       (plain file: workspace-name match string)

Stop/Notification ── speak-recap.sh / notify-attention.sh
       │
       ├─ say "..."                              (if CLAUDE_NOTIFY_AUDIO != 0 and `say` present)
       └─ notify-send --action ... "Claude #NNNN" "<message>"   (if CLAUDE_NOTIFY_DESKTOP != 0 and `notify-send` present)
                │
                └─ user clicks ──► read ~/.claude/notification-windows/<session_id>
                                   └─ wlrctl toplevel focus app_id:code title:<workspace>
```

## Components

### `capture-window.sh` (new — SessionStart hook)

Runs on every session start/resume/clear/compact. Steps:

1. Read `session_id` and `cwd` from the hook's stdin JSON.
2. Determine the VS Code window for the session:
   - **Primary — active window.** `wlrctl toplevel find` cannot print the
     active toplevel, so the script lists `code:` toplevels
     (`wlrctl toplevel list`) and probes each:
     `wlrctl toplevel find state:active app_id:code "title:<T>"`. The title that
     returns success is the active VS Code window. Because the user just
     started/resumed the session, that window is theirs.
   - **Fallback — cwd match.** If no active `code:` window is found, match the
     basenames of `cwd` and its ancestor directories against the `code:` window
     titles from `wlrctl toplevel list`. The deepest matching ancestor is the
     workspace root.
3. Extract the **workspace-name segment** from the chosen window title: split
   the title on ` - `, drop a trailing `Visual Studio Code` segment, and take
   the last remaining segment. Example:
   `localhost:4001 (localhost:4001) - skaile-dev-matthias - Visual Studio Code`
   → `skaile-dev-matthias`; `resona - Visual Studio Code` → `resona`.
4. Write the workspace-name string to
   `~/.claude/notification-windows/<session_id>` (directory created if absent).
   One plain file per session — no JSON, no write races between parallel
   sessions, consistent with the existing `~/.claude/session-counter` style.
5. If no VS Code window can be resolved, write nothing (later focus is a no-op).
6. Prune: delete files under `~/.claude/notification-windows/` older than 7 days
   (`find ... -mtime +7 -delete`) to bound growth.

The hook always exits 0 so it never blocks session start.

### `speak-recap.sh` (modified — Stop hook)

Restructured so audio and desktop notification are independent:

- Audio: speak the existing ready/recap message **only if**
  `CLAUDE_NOTIFY_AUDIO` is unset or not `0`, **and** `say` is on `PATH`.
  A missing/disabled `say` no longer aborts the script.
- Desktop notification: **only if** `CLAUDE_NOTIFY_DESKTOP` is unset or not `0`,
  **and** `notify-send` is on `PATH`. Fire:
  `notify-send --app-name="Claude Code" --action="default=Focus" --action="focus=Focus window" -t <timeout> "Claude #NNNN" "<ready! | re-caps: ...>"`.
  `--action` makes `notify-send` block until the notification is clicked or
  expires — acceptable because this hook is `async: true`.
- On click, `notify-send` prints the chosen action name (`default` or `focus`)
  on stdout. For either, the script reads
  `~/.claude/notification-windows/<session_id>` and runs
  `wlrctl toplevel focus app_id:code "title:<workspace>"`. Missing mapping file
  or non-zero `wlrctl` exit → silent no-op.

### `notify-attention.sh` (modified — Notification hook)

Same audio/desktop split as `speak-recap.sh`, with the existing
needs-attention message. Notification body text: `needs attention`.

### `hooks.json` (modified)

Add a `SessionStart` block running `capture-window.sh` (type `command`, sync).
Existing `Stop` and `Notification` blocks unchanged.

## Configuration

Two environment variables, read by the scripts; both default to enabled:

| Variable | Default | `0` disables |
|---|---|---|
| `CLAUDE_NOTIFY_AUDIO` | enabled | spoken `say` output |
| `CLAUDE_NOTIFY_DESKTOP` | enabled | `notify-send` desktop notifications |

Set in the `env` block of `~/.claude/settings.json`. README documents both.

## Error handling

- All hooks exit 0 on any failure; notifications/focus are best-effort.
- Missing `say` → skip audio, keep desktop notification.
- Missing `notify-send` → skip desktop notification, keep audio (warn to stderr
  once).
- Missing `wlrctl` → desktop notification still shows; click is a no-op.
- No mapping file for the session → click is a no-op.
- `wlrctl toplevel focus` non-zero exit → silent no-op.

## Limitations (accepted)

- Focus targets the **VS Code window**, not a specific terminal tab. Multiple
  sessions tabbed inside one window all focus that same window.
- `app_id` is hardcoded `code` (official VS Code). VSCodium / `code-oss` /
  Cursor would require changing the `app_id` value.
- Wayland-only; relies on `wlr-foreign-toplevel-management`. GNOME Wayland and
  other non-wlroots compositors will not support click-to-focus (notifications
  still work).

## Testing

- `capture-window.sh`: feed sample stdin JSON; assert the mapping file contains
  the expected workspace name for (a) active-window path and (b) cwd-fallback
  path; assert prune removes an old file and keeps a fresh one.
- `speak-recap.sh` / `notify-attention.sh`: with `say`/`notify-send` stubbed on
  `PATH`, assert correct invocation under each combination of
  `CLAUDE_NOTIFY_AUDIO` / `CLAUDE_NOTIFY_DESKTOP`; assert a `focus`/`default`
  line on stdout triggers the expected `wlrctl` call.
- Manual end-to-end: run a session in a VS Code window, trigger Stop and
  Notification events, confirm the notification appears and clicking it raises
  the correct window.

## Out of scope

- Per-terminal-tab focus inside a VS Code window.
- X11 / non-wlroots compositor support for click-to-focus.
- A standalone (non-VS-Code) terminal workflow.
