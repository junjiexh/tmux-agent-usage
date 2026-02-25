#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER_CMD="#(${CURRENT_DIR}/scripts/render_status.sh)"

set_option_if_unset() {
  local option="$1"
  local default_value="$2"
  local value
  value="$(tmux show-option -gqv "$option")"
  if [[ -z "$value" ]]; then
    tmux set-option -gq "$option" "$default_value"
  fi
}

append_status_right() {
  local current
  local separator
  current="$(tmux show-option -gqv status-right)"
  separator="$(tmux show-option -gqv @claude_usage_separator)"
  if [[ -z "$separator" ]]; then
    separator=" | "
  fi

  if [[ "$current" == *"$RENDER_CMD"* ]]; then
    return 0
  fi

  if [[ -z "$current" ]]; then
    tmux set-option -g status-right "$RENDER_CMD"
  else
    tmux set-option -g status-right "${current}${separator}${RENDER_CMD}"
  fi
}

ensure_status_right_length() {
  local auto_expand
  local min_len
  local current_len

  auto_expand="$(tmux show-option -gqv @claude_usage_auto_expand_right_length)"
  if [[ "$auto_expand" != "on" ]]; then
    return 0
  fi

  min_len="$(tmux show-option -gqv @claude_usage_min_right_length)"
  current_len="$(tmux show-option -gqv status-right-length)"

  if [[ -z "$min_len" ]]; then
    min_len="120"
  fi
  if [[ -z "$current_len" ]]; then
    current_len="40"
  fi

  if [[ "$current_len" =~ ^[0-9]+$ ]] && [[ "$min_len" =~ ^[0-9]+$ ]] && (( current_len < min_len )); then
    tmux set-option -g status-right-length "$min_len"
  fi
}

main() {
  set_option_if_unset "@claude_usage_label" "CLAUDE"
  set_option_if_unset "@claude_usage_refresh_seconds" "120"
  set_option_if_unset "@claude_usage_cache_file" "$HOME/.cache/tmux-claude-usage/usage.json"
  set_option_if_unset "@claude_usage_show_seven_day" "on"
  set_option_if_unset "@claude_usage_show_reset" "on"
  set_option_if_unset "@claude_usage_auto_append_right" "on"
  set_option_if_unset "@claude_usage_auto_expand_right_length" "on"
  set_option_if_unset "@claude_usage_min_right_length" "120"
  set_option_if_unset "@claude_usage_separator" " | "

  if [[ "$(tmux show-option -gqv @claude_usage_auto_append_right)" == "on" ]]; then
    append_status_right
  fi

  ensure_status_right_length
}

main
