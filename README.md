# tmux-claude-usage

tmux plugin to show Claude subscription usage in `status-right` using the OAuth usage endpoint.

## What It Shows

- `5h` utilization percent (`five_hour.utilization`)
- `7d` utilization percent (`seven_day.utilization`)
- `r` time remaining to the next 5-hour reset (`five_hour.resets_at`)

Example output:

```text
CLAUDE 5h:81% 7d:33% r:1h12m
```

If the cache is stale or last fetch failed, it appends `!`.

## Install (TPM)

In `~/.tmux.conf`:

```tmux
set -g @plugin 'junjiexh/tmux-agent-usage'
run '~/.tmux/plugins/tpm/tpm'
```

Then reload tmux and install plugins with `prefix + I`.

## Manual Use (without TPM)

In `~/.tmux.conf`:

```tmux
run-shell '/absolute/path/to/claude-usage.tmux'
```

## Options

```tmux
set -g @claude_usage_label 'CLAUDE'
set -g @claude_usage_refresh_seconds '120'
set -g @claude_usage_cache_file '~/.cache/tmux-claude-usage/usage.json'
set -g @claude_usage_show_seven_day 'on'
set -g @claude_usage_show_reset 'on'
set -g @claude_usage_percent_style 'number' # number | ring (Nerd Font 8-step circle slices)
set -g @claude_usage_auto_append_right 'on'
set -g @claude_usage_auto_expand_right_length 'on'
set -g @claude_usage_min_right_length '120'
set -g @claude_usage_separator ' | '
```

## Auth

Token resolution order:

1. `CLAUDE_OAUTH_ACCESS_TOKEN` env var
2. macOS Keychain service `Claude Code-credentials`
3. `~/.claude/.credentials.json`

OAuth request:

- URL: `https://api.anthropic.com/api/oauth/usage`
- Header: `anthropic-beta: oauth-2025-04-20`

## Script Entry Points

- Fetch cache: `scripts/fetch_oauth_usage.sh`
- Render status segment: `scripts/render_status.sh`
- Standalone test script: `scripts/test_claude_oauth_usage.sh`
