#!/usr/bin/env bash
set -euo pipefail

API_URL="${CLAUDE_OAUTH_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
BETA_HEADER="${CLAUDE_OAUTH_BETA:-oauth-2025-04-20}"
CREDENTIALS_FILE="${CLAUDE_CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
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

  # Some setups store plain token, others store JSON.
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

  token="$(extract_token_from_credentials_file "$CREDENTIALS_FILE" || true)"
  if [[ -n "$token" ]]; then
    printf '%s\n' "$token"
    return 0
  fi

  return 1
}

main() {
  if ! command -v curl >/dev/null 2>&1; then
    echo 'curl is required' >&2
    exit 2
  fi

  local token
  token="$(resolve_oauth_token || true)"
  if [[ -z "$token" ]]; then
    echo 'No OAuth token found.' >&2
    echo 'Try one of:' >&2
    echo '  1) export CLAUDE_OAUTH_ACCESS_TOKEN=<token>' >&2
    echo "  2) ensure keychain item 'Claude Code-credentials' exists" >&2
    echo "  3) ensure $CREDENTIALS_FILE contains accessToken" >&2
    exit 3
  fi

  log "Requesting OAuth usage from $API_URL"

  local response http_code body
  response="$(curl -sS --connect-timeout 10 --max-time 20 \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: $BETA_HEADER" \
    -H 'Accept: application/json' \
    -w '\n%{http_code}' \
    "$API_URL")"

  http_code="$(printf '%s\n' "$response" | tail -n1)"
  body="$(printf '%s\n' "$response" | sed '$d')"

  if [[ "$http_code" != "200" ]]; then
    echo "OAuth usage request failed: HTTP $http_code" >&2
    printf '%s\n' "$body" >&2
    exit 4
  fi

  if command -v jq >/dev/null 2>&1; then
    echo "$body" | jq '
      if (.data != null and (.data | type == "object")) then
        {
          format: "wrapped",
          keys: (.data | keys),
          five_hour: .data.five_hour,
          seven_day: .data.seven_day,
          seven_day_opus: .data.seven_day_opus,
          seven_day_sonnet: .data.seven_day_sonnet,
          iguana_necktie: .data.iguana_necktie
        }
      else
        {
          format: "flat",
          keys: (keys),
          five_hour: .five_hour,
          seven_day: .seven_day,
          seven_day_opus: .seven_day_opus,
          seven_day_sonnet: .seven_day_sonnet,
          iguana_necktie: .iguana_necktie
        }
      end
    '
  else
    printf '%s\n' "$body"
  fi
}

main "$@"
