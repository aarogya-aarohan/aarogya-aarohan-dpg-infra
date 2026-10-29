#!/usr/bin/env bash
# import-keycloak-realm.sh — import a Keycloak realm JSON export into the
# multi-tenant Arogyam Keycloak under a renamed realm. Rewrites .realm and
# .defaultRole.name to the target tenant slug, drops .id so KC regenerates,
# then POSTs to /auth/admin/realms with the master-realm admin token.
#
# Pair with onboard-tenant-runtime.sh --skip-realm-create to push client
# secrets to Secret Manager, create the HAPI partition, and add the
# partition_id claim mapper to the imported clients.
#
# Usage: --env {staging|production} --tenant <slug> --input <export.json>
#        [--base-url <host>]

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/keycloak.sh
source "$SCRIPT_DIR/lib/keycloak.sh"

show_help() {
  cat <<'EOF' >&2
import-keycloak-realm.sh — import a renamed realm export into Keycloak.

Required:
  --env {staging|production}
  --tenant <slug>           target realm name on the destination KC
  --input <path>            realm JSON export from the source Keycloak

Optional:
  --base-url <host>         override $STAGING_BASE_URL / $PRODUCTION_BASE_URL

Environment:
  CURL_CONNECT_TO           tunnel all requests for the public host through a
                            local port-forward while keeping URLs, TLS SNI and
                            Host intact (skips the NAT/LB hairpin):
                              kubectl -n ingress-nginx port-forward \
                                svc/ingress-nginx-controller 8443:443 &
                              CURL_CONNECT_TO=<public-host>:443:127.0.0.1:8443
  CURL_INSECURE=1           with CURL_CONNECT_TO only: skip TLS verification.
                            Required with the port-forward above — the real
                            cert terminates at the platform LB, so nginx
                            presents a self-signed one inside the tunnel.

Behaviour:
  - Rewrites .realm to <tenant>, drops .id, and remaps
    .defaultRole.name "default-roles-<source>" → "default-roles-<tenant>".
  - Fails if the target realm already exists (use the KC admin console to
    delete it first if you're re-running).
  - On success: prints the next-step command for onboard-tenant-runtime.sh
    --skip-realm-create.
EOF
}

main() {
  parse_common_args "$@"
  require_cmd jq gcloud curl

  if [ -z "$ENV" ] || [ -z "$TENANT" ] || [ -z "$INPUT_DIR" ]; then
    show_help
    exit 2
  fi
  validate_env "$ENV"
  validate_tenant "$TENANT"

  # --input is reused (the common parser stores it in INPUT_DIR) but here it's
  # a file, not a directory.
  local input="$INPUT_DIR"
  if [ ! -f "$input" ]; then
    log_err "--input file not found: $input"
    exit 2
  fi

  local source_realm
  source_realm=$(jq -r '.realm // empty' "$input")
  if [ -z "$source_realm" ]; then
    log_err "no .realm field in $input"
    exit 2
  fi

  local base kc_base
  base=$(resolve_base_url "$ENV" "$BASE_URL")
  kc_base="$base"
  log_info "env=$ENV target_tenant=$TENANT source_realm=$source_realm base=$base"

  local token
  token=$(kc_admin_token "$ENV" "$kc_base")

  if kc_realm_exists "$token" "$kc_base" "$TENANT"; then
    log_err "realm '$TENANT' already exists on $kc_base; delete it from the admin console before re-importing"
    exit 1
  fi

  # Tempfile registered at script scope so the EXIT trap can see it after
  # main() returns and the local goes out of scope.
  rewritten=$(mktemp)
  trap 'rm -f "${rewritten:-}" "${body:-}"' EXIT

  # jq rewrite: rename realm, drop every server-assigned id, remap
  # default-roles-<old> to default-roles-<new> on both the realm-level pointer
  # and the roles list. The roles array entry that the realm pointer references
  # must also be renamed, otherwise KC rejects the import with "default role
  # not found".
  #
  # Ids are stripped *recursively*, not just at the realm level. Keycloak UUIDs
  # are unique per server across all realms, and the legacy per-site realms are
  # clones of one template — every export carries identical client/role/group
  # ids. Whichever clone is imported first claims them (state-a did), so any later
  # one fails the whole import with a bare 409 "Duplicate resource error" that
  # names neither the colliding object nor the realm that holds it. Dropping
  # them lets KC mint fresh ids; nothing in a realm import references an object
  # by id that isn't also resolvable by name.
  #
  # walk/1 is defined inline rather than relied on as a builtin — it is absent
  # from some jq 1.5 builds still found on older bastion images.
  jq --arg new "$TENANT" --arg old "$source_realm" '
    def walk(f): . as $in
      | if type == "object" then
          reduce keys_unsorted[] as $key ({}; . + { ($key): ($in[$key] | walk(f)) }) | f
        elif type == "array" then map(walk(f)) | f
        else f end;
    . as $root
    | .realm = $new
    | walk(if type == "object" then del(.id) else . end)
    | if .defaultRole?.name == ("default-roles-" + $old) then
        .defaultRole.name = ("default-roles-" + $new)
      else . end
    | if .roles?.realm? then
        .roles.realm |= map(
          if .name == ("default-roles-" + $old) then
            .name = ("default-roles-" + $new)
          else . end
        )
      else . end
    # Catch every *remaining* reference to the old default role, wherever it
    # appears — most importantly .users[].realmRoles, but also group and
    # subgroup realmRoles and composite lists. Renaming only the roles entry and
    # the .defaultRole pointer leaves users pointing at a name that no longer
    # exists, and Keycloak silently auto-creates a bare non-composite role to
    # satisfy them. The realm then carries two default-role entries and every
    # migrated user is bound to the empty one, losing offline_access,
    # uma_authorization and the account client roles. Observed on site-d.
    | walk(
        if type == "string" and . == ("default-roles-" + $old)
        then ("default-roles-" + $new)
        else . end
      )
  ' "$input" > "$rewritten"

  local http_code
  body=$(mktemp)
  http_code=$(_kc_curl -sS -o "$body" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data-binary @"$rewritten" \
    "https://${kc_base}/auth/admin/realms")

  if [ "$http_code" != "201" ]; then
    log_err "realm import failed: HTTP $http_code"
    cat "$body" >&2 || true
    exit 1
  fi

  log_info "realm '$TENANT' imported successfully"
  log_info "next: scripts/onboard-tenant-runtime.sh --env $ENV --tenant $TENANT --skip-realm-create"
}

main "$@"
