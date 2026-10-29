#!/usr/bin/env bash
# get-impersonation-token.sh — mint a real access token for an existing tenant
# user *without their password*, for support/debugging.
#
# Mechanism (native Keycloak admin impersonation — no preview features, no KC
# restart): the per-tenant `support` service-account client (created by
# onboard-tenant-runtime.sh) holds the realm-management `impersonation` role.
# We mint its client_credentials token, call the admin impersonation endpoint
# for the target user (which establishes a KC SSO session via cookies), then run
# the OIDC authorization-code flow as the dashboard client `arogyam-web` reusing
# that session — Keycloak issues a code with no login prompt — and exchange the
# code for an access token. The result is indistinguishable from a real
# dashboard login for that user (same sub, realm_access.roles, permission_argument,
# partition_id), so it works on the fhir-server APIs exactly as the user would.
#
# Only the end-user-facing dashboard client (arogyam-web) is used to issue the
# token; the support/service clients are never the token's azp.
#
# Run from the bastion (private KC ingress). Stdout: the access_token.
# Usage: --env {staging|production} --tenant <slug> --user <username> [--base-url <host>]

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/keycloak.sh
source "$SCRIPT_DIR/lib/keycloak.sh"

SUPPORT_CLIENT_ID="support"
WEB_CLIENT_ID="arogyam-web"

# Cookie jar holding the impersonation SSO session. Declared at script scope so
# the EXIT trap can clean it up after main() returns (a `local` would be out of
# scope by then, tripping `set -u`).
COOKIES_JAR=""
cleanup() { [ -n "$COOKIES_JAR" ] && rm -f "$COOKIES_JAR"; }
trap cleanup EXIT

show_help() {
  cat <<'EOF' >&2
get-impersonation-token.sh — mint an access token AS a tenant user (no password).

Required:
  --env {staging|production}
  --tenant <slug>
  --user <username>           the user to impersonate

Optional:
  --base-url <host>           override $STAGING_BASE_URL / $PRODUCTION_BASE_URL

Reads the per-tenant `support` client secret and the `arogyam-web` client secret
from Secret Manager (aa-<short>-<tenant>-support-client-secret /
aa-<short>-<tenant>-keycloak-client-secret). Run from the bastion.
EOF
}

main() {
  parse_common_args "$@"
  require_cmd curl jq gcloud

  if [ -z "$ENV" ] || [ -z "$TENANT" ] || [ -z "$USER_ARG" ]; then
    show_help
    exit 2
  fi
  validate_env "$ENV"
  validate_tenant "$TENANT"

  local base short
  base=$(resolve_base_url "$ENV" "$BASE_URL")
  short=$(env_short "$ENV")
  local redirect_uri="https://${base}/dashboard/"

  log_info "impersonating '$USER_ARG' in realm '$TENANT' via $SUPPORT_CLIENT_ID → $WEB_CLIENT_ID"

  # 1. support service-account token (carries the impersonation role).
  local support_secret support_token
  support_secret=$(get_secret "aa-${short}-${TENANT}-support-client-secret") \
    || { log_err "missing aa-${short}-${TENANT}-support-client-secret — run onboard-tenant-runtime.sh --env $ENV --tenant $TENANT"; exit 1; }
  support_token=$(kc_sa_token "$base" "$TENANT" "$SUPPORT_CLIENT_ID" "$support_secret") \
    || { log_err "could not mint $SUPPORT_CLIENT_ID service-account token"; exit 1; }

  # 2. resolve the target user id (support SA has view-users/query-users).
  local uid
  uid=$(kc_get_user_id_by_username "$support_token" "$base" "$TENANT" "$USER_ARG")
  [ -n "$uid" ] || { log_err "user '$USER_ARG' not found in realm '$TENANT'"; exit 1; }

  # Cookie jar holds the impersonation SSO session; cleaned up by the EXIT trap.
  COOKIES_JAR=$(mktemp "${TMPDIR:-/tmp}/aa-impersonate-XXXXXX")

  # 3. native admin impersonation → sets KEYCLOAK_IDENTITY/KEYCLOAK_SESSION cookies.
  _kc_curl -fsS -X POST \
    -H "Authorization: Bearer $support_token" \
    -c "$COOKIES_JAR" \
    --data '' \
    "https://${base}/auth/admin/realms/${TENANT}/users/${uid}/impersonation" >/dev/null \
    || { log_err "impersonation request failed (does $SUPPORT_CLIENT_ID have the realm-management 'impersonation' role?)"; exit 1; }

  # 4. authorization-code request as arogyam-web, reusing the session cookie. KC
  #    skips the login form and 302s straight to redirect_uri with ?code=...
  local headers location code
  headers=$(_kc_curl -sS -G -o /dev/null -D - \
    -b "$COOKIES_JAR" \
    --data-urlencode "client_id=${WEB_CLIENT_ID}" \
    --data-urlencode "response_type=code" \
    --data-urlencode "scope=openid" \
    --data-urlencode "redirect_uri=${redirect_uri}" \
    --data-urlencode "state=impersonate" \
    "https://${base}/auth/realms/${TENANT}/protocol/openid-connect/auth")
  location=$(printf '%s' "$headers" | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r' | tail -n1)
  code=$(printf '%s' "$location" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
  if [ -z "$code" ]; then
    log_err "no authorization code in redirect (Location: ${location:-<none>})"
    log_err "check that $WEB_CLIENT_ID allows redirect_uri ${redirect_uri} and the standard flow"
    exit 1
  fi

  # 5. exchange the code for the user's access token (arogyam-web is confidential).
  local web_secret resp token
  web_secret=$(get_secret "aa-${short}-${TENANT}-keycloak-client-secret") \
    || { log_err "missing aa-${short}-${TENANT}-keycloak-client-secret"; exit 1; }
  resp=$(_kc_curl -fsS -X POST \
    "https://${base}/auth/realms/${TENANT}/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "code=${code}" \
    --data-urlencode "client_id=${WEB_CLIENT_ID}" \
    --data-urlencode "client_secret=${web_secret}" \
    --data-urlencode "redirect_uri=${redirect_uri}")
  token=$(echo "$resp" | jq -r '.access_token')
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    log_err "no access_token in code-exchange response"
    echo "$resp" >&2
    exit 1
  fi
  printf '%s\n' "$token"
}

main "$@"
