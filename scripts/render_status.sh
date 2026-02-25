#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

get_tmux_option() {
  local option="$1"
  local default_value="$2"
  local value=""

  if command -v tmux >/dev/null 2>&1 && [[ -n "${TMUX:-}" ]]; then
    value="$(tmux show-option -gqv "$option" 2>/dev/null || true)"
  fi

  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default_value"
  fi
}

format_percent() {
  local value="$1"
  if [[ -z "$value" || "$value" == "null" ]]; then
    printf '%s' "--"
    return 0
  fi
  printf '%.0f' "$value"
}

format_percent_token() {
  local value="$1"
  local style="$2"
  local pct
  local ring

  pct="$(format_percent "$value")"
  if [[ "$pct" == "--" ]]; then
    printf '%s' "--"
    return 0
  fi

  if [[ "$style" == "number" ]]; then
    printf '%s%%' "$pct"
    return 0
  fi

  if [[ "$style" == "ring" || "$style" == "ring_number" || "$style" == "number_ring" ]]; then
    local level

    if (( pct < 0 )); then
      pct=0
    fi
    if (( pct > 100 )); then
      pct=100
    fi

    # 8-step Nerd Font ring (mdi circle-slice), rounded from percent.
    level=$(( (pct * 8 + 50) / 100 ))
    case "$level" in
      0) ring="○" ;;
      1) ring="󰪞" ;;
      2) ring="󰪟" ;;
      3) ring="󰪠" ;;
      4) ring="󰪡" ;;
      5) ring="󰪢" ;;
      6) ring="󰪣" ;;
      7) ring="󰪤" ;;
      *) ring="󰪥" ;;
    esac
  else
    printf '%s%%' "$pct"
    return 0
  fi

  case "$style" in
    ring) printf '%s' "$ring" ;;
    ring_number) printf '%s%s%%' "$ring" "$pct" ;;
    number_ring) printf '%s%%%s' "$pct" "$ring" ;;
    *) printf '%s%%' "$pct" ;;
  esac
}

validate_percent_style() {
  local style="$1"
  case "$style" in
    number|ring|ring_number|number_ring) printf '%s' "$style" ;;
    *) printf '%s' "number" ;;
  esac
}

parse_epoch_from_iso() {
  local ts="$1"
  if [[ -z "$ts" || "$ts" == "null" ]]; then
    printf '%s' ""
    return 0
  fi

  jq -nr --arg ts "$ts" '
    ($ts
      | sub("\\.[0-9]+"; "")
      | sub("\\+00:00$"; "Z")
    ) as $clean
    | ($clean | fromdateiso8601)
  ' 2>/dev/null || true
}

format_remaining() {
  local seconds="$1"
  if [[ -z "$seconds" || "$seconds" == "null" ]]; then
    printf '%s' "--"
    return 0
  fi
  if (( seconds <= 0 )); then
    printf '%s' "0m"
    return 0
  fi

  local days hours minutes
  days=$((seconds / 86400))
  hours=$(((seconds % 86400) / 3600))
  minutes=$(((seconds % 3600) / 60))

  if (( days > 0 )); then
    printf '%sd%sh' "$days" "$hours"
  elif (( hours > 0 )); then
    printf '%sh%sm' "$hours" "$minutes"
  else
    printf '%sm' "$minutes"
  fi
}

trigger_refresh_if_needed() {
  local cache_file="$1"
  local refresh_seconds="$2"
  local now cache_epoch
  now="$(date +%s)"
  cache_epoch=0

  if [[ -f "$cache_file" ]] && command -v jq >/dev/null 2>&1; then
    cache_epoch="$(jq -r '.fetched_at_epoch // 0' "$cache_file" 2>/dev/null || printf '0')"
  fi

  if (( now - cache_epoch >= refresh_seconds )); then
    "${PLUGIN_DIR}/scripts/fetch_oauth_usage.sh" >/dev/null 2>&1 &
  fi
}

main() {
  local label refresh_seconds cache_file show_week show_reset percent_style
  local error_file now fetched_at_epoch stale_mark
  local five_hour_util seven_day_util five_reset_epoch reset_in reset_text
  local five_text seven_text segment

  label="${CLAUDE_USAGE_LABEL:-$(get_tmux_option '@claude_usage_label' 'CLAUDE')}"
  refresh_seconds="${CLAUDE_USAGE_REFRESH_SECONDS:-$(get_tmux_option '@claude_usage_refresh_seconds' '120')}"
  cache_file="${CLAUDE_USAGE_CACHE_FILE:-$(get_tmux_option '@claude_usage_cache_file' "$HOME/.cache/tmux-claude-usage/usage.json")}"
  show_week="${CLAUDE_USAGE_SHOW_SEVEN_DAY:-$(get_tmux_option '@claude_usage_show_seven_day' 'on')}"
  show_reset="${CLAUDE_USAGE_SHOW_RESET:-$(get_tmux_option '@claude_usage_show_reset' 'on')}"
  percent_style="${CLAUDE_USAGE_PERCENT_STYLE:-$(get_tmux_option '@claude_usage_percent_style' 'number')}"
  percent_style="$(validate_percent_style "$percent_style")"
  error_file="${cache_file}.error"

  trigger_refresh_if_needed "$cache_file" "$refresh_seconds"

  if ! command -v jq >/dev/null 2>&1 || [[ ! -f "$cache_file" ]]; then
    printf '%s' "${label} --"
    exit 0
  fi

  now="$(date +%s)"
  fetched_at_epoch="$(jq -r '.fetched_at_epoch // 0' "$cache_file" 2>/dev/null || printf '0')"
  five_hour_util="$(jq -r '.five_hour_utilization // empty' "$cache_file" 2>/dev/null || true)"
  seven_day_util="$(jq -r '.seven_day_utilization // empty' "$cache_file" 2>/dev/null || true)"

  five_text="$(format_percent_token "$five_hour_util" "$percent_style")"
  seven_text="$(format_percent_token "$seven_day_util" "$percent_style")"
  stale_mark=""

  if (( now - fetched_at_epoch > refresh_seconds * 3 )); then
    stale_mark="!"
  fi
  if [[ -f "$error_file" ]]; then
    stale_mark="!"
  fi

  segment="${label} 5h:${five_text}"
  if [[ "$show_week" == "on" ]]; then
    segment="${segment} 7d:${seven_text}"
  fi

  if [[ "$show_reset" == "on" ]]; then
    five_reset_epoch="$(parse_epoch_from_iso "$(jq -r '.five_hour_resets_at // empty' "$cache_file" 2>/dev/null || true)")"
    if [[ -n "$five_reset_epoch" ]]; then
      reset_in=$((five_reset_epoch - now))
      reset_text="$(format_remaining "$reset_in")"
      segment="${segment} r:${reset_text}"
    fi
  fi

  printf '%s' "${segment}${stale_mark}"
}

main "$@"
