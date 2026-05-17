# claude-notification-plugin

Audio notifications for Claude Code via `say`. When Claude finishes a response
it speaks a short message. Parallel sessions are distinguished by an ascending
four-digit number prepended to each session title.

## What it does

| Event | Audio |
|---|---|
| Claude finishes a turn (no recap) | "Claude 0001 ready!" |
| Claude finishes a turn (recap present) | "Claude 0001 re-caps: \<text\>" |
| Claude needs attention (tool permission, etc.) | "Claude 0001 needs attention" |

Session titles in the sidebar are also updated to the format `#0001 <AI title>`.

### ※ recap: marker

To trigger a spoken recap, end your final assistant message text with:

```
※ recap: one sentence summary of what was done
```

The plugin extracts everything after `※ recap:` and speaks it instead of the
generic "ready!" message.

## Requirements

- **`jq`** — used in all scripts to parse the JSONL transcript
- **`say`** — TTS command expected on `$PATH`

If `say` is not found the audio scripts exit silently (a warning is written to
stderr). The session-numbering script (`number-session.sh`) runs regardless
since it does not call `say`.

### Installing `say` on Linux

`say` is macOS-native. On Linux create a thin wrapper that calls your TTS
backend and place it on `$PATH` (e.g. `~/.local/bin/say`):

```bash
#!/usr/bin/env bash
# ~/.local/bin/say  — wrapper around spd-say
spd-say "$*"
```

Other backends: `mimic3`, `piper`, `festival`, `espeak`.

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

Remove or comment out the `speak-recap` and `notify-attention` hook entries in
`hooks/hooks.json`. The `number-session.sh` hook will continue running and
titles will still be numbered.

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
│   └── hooks.json           hook wiring (Stop + Notification)
└── scripts/
    ├── number-session.sh    sync Stop hook — assigns #NNNN to session title
    ├── speak-recap.sh       async Stop hook — speaks ready / recap message
    └── notify-attention.sh  async Notification hook — speaks needs-attention
```
