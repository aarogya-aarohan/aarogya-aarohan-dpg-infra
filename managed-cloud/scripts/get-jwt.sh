#!/usr/bin/env bash
# get-jwt.sh — smoke-test helper. Issues a password-grant token against a tenant
# realm using a dedicated public client (default 'arogyam-cli', see docs/tenant-onboarding.md).
# Usage: --env --tenant --user --password [--client arogyam-cli] [--base-url <host>]
# Stdout: the access_token. Stderr: diagnostics.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

show_help() {
  cat <<'EOF' >&2
get-jwt.sh — fetch an access token for a tenant realm via password grant.

Required:
  --env {staging|production}
  --tenant <slug>
  --user <username>
  --password <password>

Optional:
  --client <clientId>   default: arogyam-cli
  --base-url <host>     override $STAGING_BASE_URL / $PRODUCTION_BASE_URL
EOF
}

main() {
  parse_common_args "$@"
  require_cmd curl jq

  if [ -z "$ENV" ] || [ -z "$TENANT" ] || [ -z "$USER_ARG" ] || [ -z "$PASSWORD_ARG" ]; then
    show_help
    exit 2
  fi
  validate_env "$ENV"
  validate_tenant "$TENANT"

  local client="${CLIENT_ARG:-arogyam-cli}"
  local base
  base=$(resolve_base_url "$ENV" "$BASE_URL")

  log_info "fetching token for $USER_ARG against realm $TENANT (client=$client)"

  local resp
  resp=$(_curl -fsS -X POST \
    "https://${base}/auth/realms/${TENANT}/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=${client}" \
    --data-urlencode "username=${USER_ARG}" \
    --data-urlencode "password=${PASSWORD_ARG}")

  local token
  token=$(echo "$resp" | jq -r '.access_token')
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    log_err "no access_token in response"
    echo "$resp" >&2
    exit 1
  fi
  printf '%s\n' "$token"
}

main "$@"
