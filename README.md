# claude-notification-plugin

Audio notifications for Claude Code via `say`. When Claude finishes a response
it speaks a short message. Parallel sessions are distinguished by an ascending
four-digit number prepended to each session title. The plugin also raises native
Linux desktop notifications; clicking a notification focuses the VS Code window
that hosts the originating session.

## What it does

| Event | Audio | Desktop notification |
|---|---|---|
| Claude finishes a turn (no recap) | "Claude 0001 ready!" | "Claude #0001 — ready!" |
| Claude finishes a turn (recap present) | "Claude 0001 re-caps: \<text\>" | "Claude #0001 — re-caps: \<text\>" |
| Claude needs attention (tool permission, etc.) | "Claude 0001 needs attention" | "Claude #0001 — needs attention" |

> **Note:** The desktop notification text shown above is a combined representation. In practice, `notify-send` receives the title (e.g. `Claude #0001`) and body (e.g. `ready!`) as separate arguments. The exact rendered layout — whether title and body appear on separate lines, inline, or with different styling — depends on your notification daemon.

Session titles in the sidebar are also updated to the format `#0001 <AI title>`.

Each desktop notification has a **Focus window** action. Clicking it brings the
VS Code window that hosts the originating session to the foreground.

### ※ recap: marker

To trigger a spoken recap, end your final assistant message text with:

```
※ recap: one sentence summary of what was done
```

The plugin extracts everything after `※ recap:` and speaks it instead of the
generic "ready!" message. The same text is used as the desktop notification body.

## Requirements

- **`jq`** — used in all scripts to parse the JSONL transcript
- **`say`** — TTS command expected on `$PATH`
- **`notify-send`** (libnotify) — for desktop notifications
- **`wlrctl`** — for notification click-to-focus; requires a wlroots-based Wayland compositor (e.g. labwc, Sway, Hyprland)

If `say` is not found the audio scripts exit silently (a warning is written to
stderr). The session-numbering script (`number-session.sh`) runs regardless
since it does not call `say`. If `notify-send` is not found, desktop
notifications are silently skipped.

### Installing `say` on Linux

`say` is macOS-native. On Linux create a thin wrapper that calls your TTS
backend and place it on `$PATH` (e.g. `~/.local/bin/say`):

```bash
#!/usr/bin/env bash
# ~/.local/bin/say  — wrapper around spd-say
spd-say "$*"
```

Other backends: `mimic3`, `piper`, `festival`, `espeak`.

## Desktop notifications

Each turn-finished or needs-attention event raises a `notify-send` desktop
notification. Clicking the **Focus window** action in the notification focuses
the VS Code window that was hosting that session when it started.

Window tracking works as follows: at session start the `capture-window.sh`
hook uses `wlrctl toplevel list` to match the session's working directory
against the open VS Code windows and stores the result in
`~/.claude/notification-windows/<session_id>`. When a notification is clicked,
`desktop-notify.sh` reads that mapping and calls `wlrctl toplevel focus` to
raise the window.

### Requirements for click-to-focus

- **`wlrctl`** — must be installed and the compositor must be a wlroots-based
  Wayland compositor (e.g. labwc, Sway, Hyprland). On other compositors or
  under X11, notifications are still raised but clicking them has no effect.

### Limitations

- Focus targets the VS Code *window*, not a specific terminal tab within it.
  If multiple Claude sessions are tabbed inside the same window they all map
  to that window.
- The VS Code app\_id is hardcoded as `code` (official VS Code). VSCodium,
  Code-OSS, and Cursor use a different app\_id; update the `sed` filter
  `s/^code: //p` in `scripts/capture-window.sh` and the `app_id:code`
  argument in `scripts/desktop-notify.sh` to match.
- Per-session window mappings are stored in `~/.claude/notification-windows/`
  and are automatically pruned after 7 days.

## Configuration

The two feature flags are set in the `env` block of `~/.claude/settings.json`:

```json
"env": {
  "CLAUDE_NOTIFY_AUDIO": "1",
  "CLAUDE_NOTIFY_DESKTOP": "1"
}
```

| Variable | Default | Set to `0` to |
|---|---|---|
| `CLAUDE_NOTIFY_AUDIO` | enabled | disable spoken audio |
| `CLAUDE_NOTIFY_DESKTOP` | enabled | disable desktop notifications |

## Enable / disable

### Enable

The plugin is enabled globally via `~/.claude/settings.json`:

```json
"enabledPlugins": {
  "claude-notification-plugin@claude-notification-plugin": true
}
```

Set to `false` to disable without uninstalling:

```json
"claude-notification-plugin@claude-notification-plugin": false
```

### Disable audio only (keep session numbering)

Set `CLAUDE_NOTIFY_AUDIO=0` in the `env` block of `~/.claude/settings.json`
(see [Configuration](#configuration)). Session titles are still numbered and
desktop notifications are still raised.

### Disable desktop notifications only

Set `CLAUDE_NOTIFY_DESKTOP=0` in the `env` block of `~/.claude/settings.json`,
or remove the `SessionStart` hook entry from `hooks/hooks.json` and remove the
`desktop-notify.sh` dispatch lines from `scripts/speak-recap.sh` and
`scripts/notify-attention.sh`.

### Full removal

1. Remove the entry from `~/.claude/plugins/installed_plugins.json`
2. Remove or set to `false` the `enabledPlugins` entry in `settings.json`
3. Remove the `extraKnownMarketplaces` block in `settings.json`

## Session counter

The counter is stored at `~/.claude/session-counter` (a plain text file with
the last assigned number). Delete or reset it to restart numbering from 0.

## File layout

```
claude-notification-plugin/
├── .claude-plugin/
│   ├── plugin.json          plugin manifest
│   └── marketplace.json     self-referencing marketplace for local install
├── hooks/
│   └── hooks.json           hook wiring (SessionStart + Stop + Notification)
└── scripts/
    ├── number-session.sh    sync Stop hook — assigns #NNNN to session title
    ├── speak-recap.sh       async Stop hook — speaks ready / recap message
    ├── notify-attention.sh  async Notification hook — speaks needs-attention
    ├── capture-window.sh    sync SessionStart hook — records the session's VS Code window
    └── desktop-notify.sh    detached helper — shows the notification, focuses window on click
```
