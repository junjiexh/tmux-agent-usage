#!/usr/bin/env bash
set -euo pipefail

LOCK_DIR=""

cleanup() {
  if [[ -n "$LOCK_DIR" ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

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

extract_token_from_credentials_file() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -r '
      .accessToken //
      .access_token //
      .oauth.accessToken //
      .oauth.access_token //
      .claudeAiOauth.accessToken //
      .claudeAiOauth.access_token //
      .claudeAiOauth.token //
      .oauthToken //
      empty
    ' "$file" 2>/dev/null | head -n1
  else
    sed -nE 's/.*"(accessToken|access_token)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' "$file" | head -n1
  fi
}

extract_token_from_keychain() {
  if ! command -v security >/dev/null 2>&1; then
    return 1
  fi

  local raw
  raw="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)"
  if [[ -z "$raw" ]]; then
    return 1
  fi

  if [[ "$raw" == \{*\} ]]; then
    if command -v jq >/dev/null 2>&1; then
      printf '%s' "$raw" | jq -r '
        .accessToken //
        .access_token //
        .oauth.accessToken //
        .oauth.access_token //
        .claudeAiOauth.accessToken //
        .claudeAiOauth.access_token //
        .claudeAiOauth.token //
        .oauthToken //
        empty
      ' 2>/dev/null | head -n1
    else
      printf '%s\n' "$raw" | sed -nE 's/.*"(accessToken|access_token)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' | head -n1
    fi
  else
    printf '%s\n' "$raw"
  fi
}

resolve_oauth_token() {
  local credentials_file="$1"

  if [[ -n "${CLAUDE_OAUTH_ACCESS_TOKEN:-}" ]]; then
    printf '%s\n' "$CLAUDE_OAUTH_ACCESS_TOKEN"
    return 0
  fi

  local token
  token="$(extract_token_from_keychain || true)"
  if [[ -n "$token" ]]; then
    printf '%s\n' "$token"
    return 0
  fi

  token="$(extract_token_from_credentials_file "$credentials_file" || true)"
  if [[ -n "$token" ]]; then
    printf '%s\n' "$token"
    return 0
  fi

  return 1
}

write_error() {
  local error_file="$1"
  local message="$2"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" > "$error_file"
}

main() {
  local api_url beta_header credentials_file cache_file timeout_seconds
  local error_file cache_dir token response http_code body
  local lock_stale_seconds lock_mtime now_epoch
  local tmp_body_file tmp_cache_file

  api_url="${CLAUDE_OAUTH_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
  beta_header="${CLAUDE_OAUTH_BETA:-oauth-2025-04-20}"
  credentials_file="${CLAUDE_CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"
  cache_file="${CLAUDE_USAGE_CACHE_FILE:-$(get_tmux_option '@claude_usage_cache_file' "$HOME/.cache/tmux-claude-usage/usage.json")}"
  timeout_seconds="${CLAUDE_USAGE_TIMEOUT_SECONDS:-10}"
  lock_stale_seconds="${CLAUDE_USAGE_LOCK_STALE_SECONDS:-600}"

  cache_dir="$(dirname "$cache_file")"
  LOCK_DIR="${cache_file}.lock"
  error_file="${cache_file}.error"
  mkdir -p "$cache_dir"

  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    lock_mtime=""
    now_epoch="$(date +%s)"

    if [[ -d "$LOCK_DIR" ]]; then
      lock_mtime="$(stat -f '%m' "$LOCK_DIR" 2>/dev/null || true)"
      if [[ -z "$lock_mtime" ]]; then
        lock_mtime="$(stat -c '%Y' "$LOCK_DIR" 2>/dev/null || true)"
      fi
    fi

    if [[ -n "$lock_mtime" ]] && [[ "$lock_mtime" =~ ^[0-9]+$ ]] && [[ "$lock_stale_seconds" =~ ^[0-9]+$ ]] && (( now_epoch - lock_mtime > lock_stale_seconds )); then
      rmdir "$LOCK_DIR" 2>/dev/null || true
      if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        exit 0
      fi
    else
      exit 0
    fi
  fi
  trap cleanup EXIT

  if ! command -v jq >/dev/null 2>&1; then
    write_error "$error_file" "jq-not-found"
    exit 1
  fi

  token="$(resolve_oauth_token "$credentials_file" || true)"
  if [[ -z "$token" ]]; then
    write_error "$error_file" "oauth-token-not-found"
    exit 1
  fi

  if ! response="$(curl -sS --connect-timeout "$timeout_seconds" --max-time "$timeout_seconds" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: $beta_header" \
    -H "Accept: application/json" \
    -w '\n%{http_code}' \
    "$api_url")"; then
    write_error "$error_file" "network-error"
    exit 1
  fi

  http_code="$(printf '%s\n' "$response" | tail -n1)"
  body="$(printf '%s\n' "$response" | sed '$d')"

  if [[ "$http_code" != "200" ]]; then
    write_error "$error_file" "http-${http_code}"
    exit 1
  fi

  tmp_body_file="${cache_file}.body.tmp"
  tmp_cache_file="${cache_file}.tmp"
  printf '%s\n' "$body" > "$tmp_body_file"

  if ! jq '
    def root:
      if (.data != null and (.data | type == "object")) then .data else . end;
    (root) as $r
    | {
        fetched_at_epoch: (now | floor),
        fetched_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        source: "oauth_api",
        five_hour_utilization: ($r.five_hour.utilization // null),
        five_hour_resets_at: ($r.five_hour.resets_at // null),
        seven_day_utilization: ($r.seven_day.utilization // null),
        seven_day_resets_at: ($r.seven_day.resets_at // null),
        seven_day_opus_utilization: ($r.seven_day_opus.utilization // null),
        seven_day_opus_resets_at: ($r.seven_day_opus.resets_at // null),
        keys: ($r | keys)
      }
  ' "$tmp_body_file" > "$tmp_cache_file"; then
    rm -f "$tmp_body_file" "$tmp_cache_file"
    write_error "$error_file" "json-parse-error"
    exit 1
  fi

  mv "$tmp_cache_file" "$cache_file"
  rm -f "$tmp_body_file" "$error_file"
}

main "$@"
