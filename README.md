# WezTerm Agent Deck

[![Tests](https://github.com/Eric162/wezterm-agent-deck/actions/workflows/test.yml/badge.svg)](https://github.com/Eric162/wezterm-agent-deck/actions/workflows/test.yml)

Monitor AI coding agents (Claude Code, OpenCode, Aider, etc.) in WezTerm. Shows status dots in tabs and notifications when agents need attention.

Inspired by [agent-deck](https://github.com/asheshgoplani/agent-deck).

<img width="1252" height="874" alt="Screenshot 2026-01-12 at 1 01 00 PM" src="https://github.com/user-attachments/assets/9285f6d7-cd59-4035-81ce-9d3268948622" />

## Quick Start

```lua
local wezterm = require('wezterm')
local agent_deck = wezterm.plugin.require('https://github.com/Eric162/wezterm-agent-deck')
local config = wezterm.config_builder()

agent_deck.apply_to_config(config)

return config
```

## Configuration

```lua
agent_deck.apply_to_config(config, {
    update_interval = 500,  -- ms between status checks

    colors = {
        working = '#A6E22E',   -- green: agent processing
        waiting = '#E6DB74',   -- yellow: needs input
        idle = '#66D9EF',      -- blue: ready
        inactive = '#888888',  -- gray: no agent
    },

    icons = {
        style = 'unicode',  -- or 'nerd', 'emoji'
        unicode = { working = '●', waiting = '◔', idle = '○', inactive = '◌' },
    },

    notifications = { enabled = true, on_waiting = true },
})
```

## Notifications with Sound (macOS)

WezTerm's native notifications don't support sound. For sound notifications on macOS, use [terminal-notifier](https://github.com/julienXX/terminal-notifier):

```bash
brew install terminal-notifier
```

```lua
agent_deck.apply_to_config(config, {
    notifications = {
        enabled = true,
        on_waiting = true,
        backend = 'terminal-notifier',  -- or 'native' (default)
        terminal_notifier = {
            sound = 'default',  -- or 'Ping', 'Glass', 'Funk', etc.
            title = 'WezTerm Agent Deck',  -- notification title
            activate = true,  -- focus WezTerm when notification clicked
        },
    },
})
```

## Custom Rendering

Disable built-in display and use the plugin's detection in your own handlers:

```lua
agent_deck.apply_to_config(config, {
    tab_title = { enabled = false },
    right_status = { enabled = false },
    colors = { ... },
})

-- Custom tab title with status dots
wezterm.on('format-tab-title', function(tab)
    local formatted = {}
    for _, pane_info in ipairs(tab.panes or {}) do
        local state = agent_deck.get_agent_state(pane_info.pane_id)
        if state then
            table.insert(formatted, { Foreground = { Color = agent_deck.get_status_color(state.status) } })
            table.insert(formatted, { Text = agent_deck.get_status_icon(state.status) .. ' ' })
        end
    end
    table.insert(formatted, { Text = tab.tab_title or 'Terminal' })
    return wezterm.format(formatted)
end)

-- Custom status bar
wezterm.on('update-status', function(window, pane)
    for _, tab in ipairs(window:mux_window():tabs()) do
        for _, p in ipairs(tab:panes()) do
            agent_deck.update_pane(p)
        end
    end

    local counts = agent_deck.count_agents_by_status()
    local cfg = agent_deck.get_config()
    local items = {}

    if counts.waiting > 0 then
        table.insert(items, { Foreground = { Color = cfg.colors.waiting } })
        table.insert(items, { Text = counts.waiting .. ' waiting ' })
    end

    window:set_right_status(wezterm.format(items))
end)
```

## API

```lua
agent_deck.get_agent_state(pane_id)      -- { agent_type, status }
agent_deck.get_all_agent_states()        -- all pane states
agent_deck.count_agents_by_status()      -- { working=N, waiting=N, ... }
agent_deck.get_status_icon(status)       -- configured icon
agent_deck.get_status_color(status)      -- configured color
agent_deck.update_pane(pane)             -- trigger detection
agent_deck.get_config()                  -- current config
```

## Supported Agents

OpenCode (including Plan mode), Claude Code, Gemini, Codex, Aider. Add custom agents:

```lua
agents = {
    my_agent = {
        patterns = { 'my%-agent' },
        status_patterns = {
            working = { 'thinking' },
            waiting = { 'y/n' },
        },
    },
}
```

## Hook-Based State Detection (Claude Code)

The default text-scraping approach can produce false positives when conversation content matches status patterns. For Claude Code, you can use **hooks** for reliable state detection with zero false positives.

### Setup

1. Create the hook script at `~/.claude/hooks/agent-deck-state.sh`:

```bash
#!/bin/bash
set -euo pipefail

STATE_DIR="/tmp/wezterm-agent-deck"
mkdir -p "$STATE_DIR"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

[ -z "$SESSION_ID" ] && exit 0

STATE_FILE="$STATE_DIR/$SESSION_ID"

case "$EVENT" in
    UserPromptSubmit)
        echo "working" > "$STATE_FILE.state"
        ;;
    SessionStart)
        echo "idle" > "$STATE_FILE.state"
        echo "$CWD" > "$STATE_FILE.cwd"
        CLAUDE_PID=$(ps -o ppid= -p $PPID 2>/dev/null | tr -d ' ')
        [ -n "$CLAUDE_PID" ] && echo "$CLAUDE_PID" > "$STATE_FILE.pid"
        ;;
    PreToolUse)
        echo "working" > "$STATE_FILE.state"
        ;;
    Stop)
        LAST_LINE=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' | tail -1)
        if echo "$LAST_LINE" | grep -qE '\?[[:space:]]*$'; then
            echo "waiting" > "$STATE_FILE.state"
        else
            echo "idle" > "$STATE_FILE.state"
        fi
        ;;
    Notification)
        NTYPE=$(echo "$INPUT" | jq -r '.notification_type // empty')
        case "$NTYPE" in
            permission_prompt|elicitation_dialog)
                echo "waiting" > "$STATE_FILE.state"
                ;;
        esac
        ;;
    SessionEnd)
        rm -f "$STATE_FILE.state" "$STATE_FILE.cwd" "$STATE_FILE.pid"
        ;;
esac
```

2. Make it executable: `chmod +x ~/.claude/hooks/agent-deck-state.sh`

3. Add hooks to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/agent-deck-state.sh" }] }
    ],
    "PreToolUse": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/agent-deck-state.sh" }] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/agent-deck-state.sh" }] }
    ],
    "Notification": [
      { "matcher": "permission_prompt", "hooks": [{ "type": "command", "command": "~/.claude/hooks/agent-deck-state.sh" }] },
      { "matcher": "elicitation_dialog", "hooks": [{ "type": "command", "command": "~/.claude/hooks/agent-deck-state.sh" }] }
    ],
    "SessionStart": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/agent-deck-state.sh" }] }
    ],
    "SessionEnd": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "~/.claude/hooks/agent-deck-state.sh" }] }
    ]
  }
}
```

### How It Works

- Hooks write state files to `/tmp/wezterm-agent-deck/<session_id>.{state,cwd,pid}`
- The plugin matches pane to state file by PID (process tree) then CWD
- `UserPromptSubmit` → working, `PreToolUse` → working, `Stop` → idle (or waiting if last line ends with `?`), `Notification(permission_prompt)` → waiting
- Stale state files are auto-cleaned when the Claude Code process dies
- Falls back to text-based detection for agents without hooks (OpenCode, Aider, etc.)

## Development

```lua
-- Load locally for development
local agent_deck = dofile('/path/to/wezterm-agent-deck/plugin/init.lua')
```

Debug via WezTerm console (Ctrl+Shift+L).

## License

MIT
