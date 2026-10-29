# shellcheck shell=bash
# keycloak.sh — Keycloak admin REST helpers.
# Auth: master realm password grant; admin/admin-password from aa-<short>-keycloak-admin Secret Manager entry.
# Source after lib/common.sh.

set -euo pipefail

# Cap individual curl calls so a single hung connection can't run past the KC
# admin token's 60s lifespan and leave the rest of the run 401'ing.
KC_CURL_MAX_TIME="${KC_CURL_MAX_TIME:-20}"
KC_CURL_RETRIES="${KC_CURL_RETRIES:-3}"
# --retry-all-errors covers curl-side errors (e.g. connect timeout, exit 28) on
# top of curl's default transient HTTP retries. Bastion→KC ingress shows
# sporadic 15s+ connect stalls; the retry budget masks them. Per-call total
# dwell is bounded by (max-time * (retries+1) + retry-delay * retries).
_kc_curl() {
  _curl --max-time "$KC_CURL_MAX_TIME" \
       --retry "$KC_CURL_RETRIES" --retry-delay 2 \
       --retry-connrefused --retry-all-errors \
       "$@"
}

# Cache TTL kept below the master-realm access token lifespan so callers that
# re-invoke kc_admin_token between steps get a fresh token in time.
_KC_TOKEN_CACHE_TTL=45

_kc_token_cache_path() {
  local base="$1"
  local sanitized
  sanitized=$(echo "$base" | tr -c '[:alnum:]' '_')
  echo "${TMPDIR:-/tmp}/aa-kc-token-${sanitized}"
}

# kc_admin_token <env> <base-url>  → echoes a master-realm bearer token.
# Caches in $TMPDIR for $_KC_TOKEN_CACHE_TTL seconds.
kc_admin_token() {
  local env="$1" base="$2"
  local short
  short=$(env_short "$env")
  local cache
  cache=$(_kc_token_cache_path "$base")

  if [ -f "$cache" ]; then
    local mtime now
    if mtime=$(stat -f %m "$cache" 2>/dev/null) || mtime=$(stat -c %Y "$cache" 2>/dev/null); then
      now=$(date +%s)
      if [ $((now - mtime)) -lt "$_KC_TOKEN_CACHE_TTL" ]; then
        cat "$cache"
        return 0
      fi
    fi
  fi

  local creds
  creds=$(get_secret "aa-${short}-keycloak-admin")
  local user pass
  user=$(echo "$creds" | jq -r '.username')
  pass=$(echo "$creds" | jq -r '.password')
  if [ -z "$user" ] || [ "$user" = "null" ] || [ -z "$pass" ] || [ "$pass" = "null" ]; then
    log_err "keycloak admin credentials missing in aa-${short}-keycloak-admin (need {username,password})"
    return 1
  fi

  local resp
  resp=$(_kc_curl -fsS -X POST \
    "https://${base}/auth/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" \
    --data-urlencode "username=${user}" \
    --data-urlencode "password=${pass}")

  local token
  token=$(echo "$resp" | jq -r '.access_token')
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    log_err "keycloak admin token request returned no access_token"
    return 1
  fi

  umask 077
  printf '%s' "$token" >"$cache"
  echo "$token"
}

# kc_realm_exists <token> <base> <realm>  → 0 if exists, 1 if not.
kc_realm_exists() {
  local token="$1" base="$2" realm="$3"
  local code
  code=$(_kc_curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $token" \
    "https://${base}/auth/admin/realms/${realm}")
  case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    *) log_err "kc_realm_exists: unexpected HTTP $code"; return 2 ;;
  esac
}

kc_create_realm() {
  local token="$1" base="$2" realm="$3"
  local body
  body=$(jq -n --arg r "$realm" '{realm:$r, enabled:true, sslRequired:"external"}')
  _kc_curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms" >/dev/null
}

# kc_update_realm_settings <token> <base> <realm> <settings-json>
# PUTs the merged settings onto /admin/realms/{r}. The `realm` field is injected
# automatically so the asset file doesn't need to know the tenant name.
kc_update_realm_settings() {
  local token="$1" base="$2" realm="$3" settings_json="$4"
  local body
  body=$(jq -c --arg r "$realm" '. + {realm:$r}' <<<"$settings_json")
  _kc_curl -fsS -X PUT \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms/${realm}" >/dev/null
}

# kc_make_email_optional <token> <base> <realm>
# User-profile attributes are managed through a separate Keycloak endpoint and
# are not part of RealmRepresentation. Removing `required` from the email
# attribute makes it optional for every user role. Idempotent.
kc_make_email_optional() {
  local token="$1" base="$2" realm="$3"
  local current body
  current=$(_kc_curl -fsS \
    -H "Authorization: Bearer $token" \
    "https://${base}/auth/admin/realms/${realm}/users/profile")
  body=$(jq -c '(.attributes[] | select(.name == "email")) |= del(.required)' <<<"$current")
  _kc_curl -fsS -X PUT \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms/${realm}/users/profile" >/dev/null
}

# kc_disable_required_action <token> <base> <realm> <alias>
# Disables a built-in required action (e.g. VERIFY_PROFILE) on the realm. Needed
# because KC 26 ships VERIFY_PROFILE enabled by default, and combined with the
# stock user-profile config (email/firstName/lastName required for role `user`)
# any password grant for a user lacking those attributes fails with
# `invalid_grant — Account is not fully set up`. FLW users seeded by migration
# legitimately have no email, so we turn the action off realm-wide.
# Idempotent: GET → set enabled=false → PUT.
kc_disable_required_action() {
  local token="$1" base="$2" realm="$3" alias="$4"
  local current
  current=$(_kc_curl -fsS \
    -H "Authorization: Bearer $token" \
    "https://${base}/auth/admin/realms/${realm}/authentication/required-actions/${alias}")
  if [ "$(jq -r '.enabled' <<<"$current")" = "false" ]; then
    return 0
  fi
  local body
  body=$(jq -c '.enabled = false | .defaultAction = false' <<<"$current")
  _kc_curl -fsS -X PUT \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms/${realm}/authentication/required-actions/${alias}" >/dev/null
}

# kc_role_exists <token> <base> <realm> <role-name>  → 0 if exists, 1 if not.
kc_role_exists() {
  local token="$1" base="$2" realm="$3" name="$4"
  local code
  code=$(_kc_curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $token" \
    "https://${base}/auth/admin/realms/${realm}/roles/${name}")
  case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    *) log_err "kc_role_exists($name): unexpected HTTP $code"; return 2 ;;
  esac
}

# kc_create_role <token> <base> <realm> <role-name> [description] [composite]
kc_create_role() {
  local token="$1" base="$2" realm="$3" name="$4"
  local desc="${5:-}" composite="${6:-false}"
  local body
  body=$(jq -n \
    --arg n "$name" --arg d "$desc" --argjson c "$composite" \
    '{name:$n, description:$d, composite:$c, clientRole:false}')
  _kc_curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms/${realm}/roles" >/dev/null
}

# kc_get_realm_roles <token> <base> <realm>  → echoes JSON array of {id,name,...}.
kc_get_realm_roles() {
  local token="$1" base="$2" realm="$3"
  _kc_curl -fsS \
    -H "Authorization: Bearer $token" \
    "https://${base}/auth/admin/realms/${realm}/roles?max=500"
}

# kc_get_group_id_by_name <token> <base> <realm> <name>  → echoes uuid or empty.
# Uses /groups?search=<name> then filters for exact name match (search is substring).
kc_get_group_id_by_name() {
  local token="$1" base="$2" realm="$3" name="$4"
  _kc_curl -fsS -G \
    -H "Authorization: Bearer $token" \
    --data-urlencode "search=$name" \
    "https://${base}/auth/admin/realms/${realm}/groups" \
    | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -n1
}

# kc_create_group <token> <base> <realm> <name>  → echoes uuid.
kc_create_group() {
  local token="$1" base="$2" realm="$3" name="$4"
  local body
  body=$(jq -n --arg n "$name" '{name:$n}')
  _kc_curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms/${realm}/groups" >/dev/null
  kc_get_group_id_by_name "$token" "$base" "$realm" "$name"
}

# kc_set_group_attributes <token> <base> <realm> <group-uuid> <name> <attrs-json>
# Attributes is an object whose values are string arrays (KC group attr shape).
kc_set_group_attributes() {
  local token="$1" base="$2" realm="$3" gid="$4" name="$5" attrs="$6"
  local body
  body=$(jq -n --arg n "$name" --argjson a "$attrs" '{name:$n, attributes:$a}')
  _kc_curl -fsS -X PUT \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms/${realm}/groups/${gid}" >/dev/null
}

# kc_add_realm_roles_to_group <token> <base> <realm> <group-uuid> <role-names-json-array>
# Resolves names→{id,name} via /roles, then POSTs to role-mappings/realm. KC ignores
# already-mapped roles, so this is idempotent.
kc_add_realm_roles_to_group() {
  local token="$1" base="$2" realm="$3" gid="$4" names_json="$5"
  local all body
  all=$(kc_get_realm_roles "$token" "$base" "$realm")
  body=$(jq -c --argjson names "$names_json" --argjson all "$all" \
    '[$all[] | select(.name as $n | $names | index($n)) | {id, name}]' <<<'null')
  if [ "$(jq 'length' <<<"$body")" = "0" ]; then
    return 0
  fi
  _kc_curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms/${realm}/groups/${gid}/role-mappings/realm" >/dev/null
}

# kc_add_client_roles_to_group <token> <base> <realm> <group-uuid> <client-id> <role-names-json>
kc_add_client_roles_to_group() {
  local token="$1" base="$2" realm="$3" gid="$4" client_id="$5" names_json="$6"
  local cuuid all body
  cuuid=$(kc_get_client_id_by_clientid "$token" "$base" "$realm" "$client_id")
  [ -n "$cuuid" ] || { log_err "kc_add_client_roles_to_group: client $client_id not found"; return 1; }
  all=$(_kc_curl -fsS \
    -H "Authorization: Bearer $token" \
    "https://${base}/auth/admin/realms/${realm}/clients/${cuuid}/roles")
  body=$(jq -c --argjson names "$names_json" --argjson all "$all" \
    '[$all[] | select(.name as $n | $names | index($n)) | {id, name}]' <<<'null')
  if [ "$(jq 'length' <<<"$body")" = "0" ]; then
    return 0
  fi
  _kc_curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms/${realm}/groups/${gid}/role-mappings/clients/${cuuid}" >/dev/null
}

# kc_get_client_id_by_clientid <token> <base> <realm> <clientId> → echoes uuid or empty.
kc_get_client_id_by_clientid() {
  local token="$1" base="$2" realm="$3" client_id="$4"
  _kc_curl -fsS \
    -H "Authorization: Bearer $token" \
    "https://${base}/auth/admin/realms/${realm}/clients?clientId=${client_id}" \
    | jq -r '.[0].id // empty'
}

# kc_get_or_create_client <token> <base> <realm> <clientId> <redirectUris-json> [webOrigins-json] [attrs-json]
# Creates a confidential client with standard browser flow (used for arogyam-web).
# Optional webOrigins / attrs default to [] and {}.
kc_get_or_create_client() {
  local token="$1" base="$2" realm="$3" client_id="$4" redirects="$5"
  local web_origins="${6:-[]}" attrs="${7:-{\}}"
  local existing
  existing=$(kc_get_client_id_by_clientid "$token" "$base" "$realm" "$client_id")
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi
  local body
  body=$(jq -n \
    --arg cid "$client_id" \
    --argjson redirects "$redirects" \
    --argjson webOrigins "$web_origins" \
    --argjson attrs "$attrs" \
    '{
      clientId: $cid,
      enabled: true,
      publicClient: false,
      protocol: "openid-connect",
      standardFlowEnabled: true,
      directAccessGrantsEnabled: false,
      serviceAccountsEnabled: false,
      redirectUris: $redirects,
      webOrigins: $webOrigins,
      attributes: $attrs
    }')
  _kc_curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms/${realm}/clients" >/dev/null
  kc_get_client_id_by_clientid "$token" "$base" "$realm" "$client_id"
}

# kc_get_or_create_public_directgrants_client <token> <base> <realm> <clientId> [attrs-json]
# Public client (no secret) with Direct Access Grants enabled — used for arogyam-app
# (mobile, password grant). Standard flow disabled.
kc_get_or_create_public_directgrants_client() {
  local token="$1" base="$2" realm="$3" client_id="$4"
  local attrs="${5:-{\}}"
  local existing
  existing=$(kc_get_client_id_by_clientid "$token" "$base" "$realm" "$client_id")
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi
  local body
  body=$(jq -n \
    --arg cid "$client_id" \
    --argjson attrs "$attrs" \
    '{
      clientId: $cid,
      enabled: true,
      publicClient: true,
      protocol: "openid-connect",
      standardFlowEnabled: false,
      directAccessGrantsEnabled: true,
      serviceAccountsEnabled: false,
      implicitFlowEnabled: false,
      redirectUris: [],
      webOrigins: [],
      attributes: $attrs
    }')
  _kc_curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms/${realm}/clients" >/dev/null
  kc_get_client_id_by_clientid "$token" "$base" "$realm" "$client_id"
}

# kc_get_or_create_sa_client <token> <base> <realm> <clientId> → echoes uuid.
# Confidential client with serviceAccountsEnabled=true; no browser flows.
kc_get_or_create_sa_client() {
  local token="$1" base="$2" realm="$3" client_id="$4"
  local existing
  existing=$(kc_get_client_id_by_clientid "$token" "$base" "$realm" "$client_id")
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi
  local body
  body=$(jq -n \
    --arg cid "$client_id" \
    '{
      clientId: $cid,
      enabled: true,
      publicClient: false,
      protocol: "openid-connect",
      standardFlowEnabled: false,
      directAccessGrantsEnabled: false,
      serviceAccountsEnabled: true,
      redirectUris: []
    }')
  _kc_curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms/${realm}/clients" >/dev/null
  kc_get_client_id_by_clientid "$token" "$base" "$realm" "$client_id"
}

# kc_fhir_bootstrap_token <env> <base> → master-realm fhir-bootstrap SA bearer token.
# Uses aa-<short>-fhir-bootstrap-secret (provisioned by seed-fhir-bundle.sh first run).
# This is the token the arogyam-backend gateway accepts for system-level FHIR ops
# ($partition-management-*, cross-tenant PUT, etc.); kc_admin_token (admin user
# password grant) is rejected by the gateway with 401.
# Cache TTL for fhir-bootstrap tokens. Paired with the client's
# access.token.lifespan attribute (3600s) set by seed-fhir-bundle.sh — we cache
# for slightly less so the cached token can never present-as-expired to HAPI.
_KC_FHIR_BOOTSTRAP_CACHE_TTL=3000

kc_fhir_bootstrap_token() {
  local env="$1" base="$2"
  local short
  short=$(env_short "$env")

  local cache
  cache=$(_kc_token_cache_path "fhir-bootstrap@${short}")
  if [ -f "$cache" ]; then
    local mtime now
    if mtime=$(stat -f %m "$cache" 2>/dev/null) || mtime=$(stat -c %Y "$cache" 2>/dev/null); then
      now=$(date +%s)
      if [ $((now - mtime)) -lt "$_KC_FHIR_BOOTSTRAP_CACHE_TTL" ]; then
        cat "$cache"
        return 0
      fi
    fi
  fi

  local secret
  secret=$(get_secret "aa-${short}-fhir-bootstrap-secret") || {
    log_err "missing Secret Manager entry aa-${short}-fhir-bootstrap-secret — run scripts/seed-fhir-bundle.sh --env $env first"
    return 1
  }
  local token
  token=$(kc_sa_token "$base" "master" "fhir-bootstrap" "$secret") || return 1
  umask 077
  printf '%s' "$token" >"$cache"
  printf '%s' "$token"
}

# kc_sa_token <base> <realm> <client_id> <client_secret> → echoes access_token.
# Uses client_credentials grant against the tenant realm.
kc_sa_token() {
  local base="$1" realm="$2" client_id="$3" client_secret="$4"
  local resp
  resp=$(_kc_curl -fsS -X POST \
    "https://${base}/auth/realms/${realm}/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${client_id}" \
    --data-urlencode "client_secret=${client_secret}")
  local token
  token=$(echo "$resp" | jq -r '.access_token')
  if [ -z "$token" ] || [ "$token" = "null" ]; then
    log_err "client_credentials token request for ${client_id}@${realm} returned no access_token"
    return 1
  fi
  echo "$token"
}

# kc_get_sa_user_id <token> <base> <realm> <client-uuid> → echoes the service-account
# user uuid for a serviceAccountsEnabled client.
kc_get_sa_user_id() {
  local token="$1" base="$2" realm="$3" client_uuid="$4"
  _kc_curl -fsS \
    -H "Authorization: Bearer $token" \
    "https://${base}/auth/admin/realms/${realm}/clients/${client_uuid}/service-account-user" \
    | jq -r '.id // empty'
}

# kc_assign_realm_roles_to_user <token> <base> <realm> <user-uuid> <role-names-json>
# Resolves names→{id,name} via /roles, then POSTs to /users/{uid}/role-mappings/realm.
# KC ignores duplicate mappings, so this is idempotent.
kc_assign_realm_roles_to_user() {
  local token="$1" base="$2" realm="$3" uid="$4" names_json="$5"
  local all body
  all=$(kc_get_realm_roles "$token" "$base" "$realm")
  body=$(jq -c --argjson names "$names_json" --argjson all "$all" \
    '[$all[] | select(.name as $n | $names | index($n)) | {id, name}]' <<<'null')
  if [ "$(jq 'length' <<<"$body")" = "0" ]; then
    return 0
  fi
  _kc_curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms/${realm}/users/${uid}/role-mappings/realm" >/dev/null
}

# kc_assign_client_roles_to_user <token> <base> <realm> <user-uuid> <client-id> <role-names-json>
# Resolves names→{id,name} on the named client (e.g. realm-management), then POSTs to
# /users/{uid}/role-mappings/clients/{cuuid}. KC ignores duplicate mappings, so this is idempotent.
kc_assign_client_roles_to_user() {
  local token="$1" base="$2" realm="$3" uid="$4" client_id="$5" names_json="$6"
  local cuuid all body
  cuuid=$(kc_get_client_id_by_clientid "$token" "$base" "$realm" "$client_id")
  [ -n "$cuuid" ] || { log_err "kc_assign_client_roles_to_user: client $client_id not found"; return 1; }
  all=$(_kc_curl -fsS \
    -H "Authorization: Bearer $token" \
    "https://${base}/auth/admin/realms/${realm}/clients/${cuuid}/roles")
  body=$(jq -c --argjson names "$names_json" --argjson all "$all" \
    '[$all[] | select(.name as $n | $names | index($n)) | {id, name}]' <<<'null')
  if [ "$(jq 'length' <<<"$body")" = "0" ]; then
    return 0
  fi
  _kc_curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms/${realm}/users/${uid}/role-mappings/clients/${cuuid}" >/dev/null
}

# kc_set_client_attribute <token> <base> <realm> <client-uuid> <key> <value>
# Upsert a single key in the client's `attributes` map. Idempotent: noop if the
# stored value already matches. KC API requires a PUT of the full client rep,
# so we GET, mutate, PUT.
kc_set_client_attribute() {
  local token="$1" base="$2" realm="$3" client_uuid="$4" key="$5" value="$6"
  local url="https://${base}/auth/admin/realms/${realm}/clients/${client_uuid}"
  local client current
  client=$(_kc_curl -fsS -H "Authorization: Bearer $token" "$url")
  current=$(jq -r --arg k "$key" '.attributes[$k] // ""' <<<"$client")
  if [ "$current" = "$value" ]; then
    log_info "client attribute $key=$value already current on $client_uuid; skipping"
    return 0
  fi
  local updated
  updated=$(jq --arg k "$key" --arg v "$value" '.attributes = ((.attributes // {}) + {($k): $v})' <<<"$client")
  _kc_curl -fsS -X PUT \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$updated" \
    "$url" >/dev/null
  log_info "updated client attribute $key on $client_uuid: '$current' → '$value'"
}

# kc_get_client_secret <token> <base> <realm> <client-uuid> → echoes secret value.
kc_get_client_secret() {
  local token="$1" base="$2" realm="$3" client_uuid="$4"
  _kc_curl -fsS \
    -H "Authorization: Bearer $token" \
    "https://${base}/auth/admin/realms/${realm}/clients/${client_uuid}/client-secret" \
    | jq -r '.value'
}

# kc_add_hardcoded_claim_mapper <token> <base> <realm> <client-uuid> <claim> <value>
# Upsert: creates the mapper if missing, updates the value in-place if it exists
# with a different value, no-ops if the value already matches.
kc_add_hardcoded_claim_mapper() {
  local token="$1" base="$2" realm="$3" client_uuid="$4" claim="$5" value="$6"
  local mappers_url="https://${base}/auth/admin/realms/${realm}/clients/${client_uuid}/protocol-mappers/models"
  local existing
  existing=$(_kc_curl -fsS -H "Authorization: Bearer $token" "$mappers_url" \
    | jq -c --arg n "$claim" '.[] | select(.name==$n)' | head -n1)

  local body
  body=$(jq -n \
    --arg name "$claim" \
    --arg val "$value" \
    '{
      name: $name,
      protocol: "openid-connect",
      protocolMapper: "oidc-hardcoded-claim-mapper",
      consentRequired: false,
      config: {
        "claim.name": $name,
        "claim.value": $val,
        "jsonType.label": "String",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true"
      }
    }')

  if [ -z "$existing" ]; then
    _kc_curl -fsS -X POST \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$body" \
      "$mappers_url" >/dev/null
    log_info "created claim mapper '$claim'=$value on client $client_uuid"
    return 0
  fi

  local existing_id existing_val
  existing_id=$(jq -r '.id' <<<"$existing")
  existing_val=$(jq -r '.config["claim.value"] // empty' <<<"$existing")
  if [ "$existing_val" = "$value" ]; then
    log_info "claim mapper '$claim'=$value already current on client $client_uuid; skipping"
    return 0
  fi
  local updated
  updated=$(jq --arg id "$existing_id" '. + {id: $id}' <<<"$body")
  _kc_curl -fsS -X PUT \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$updated" \
    "$mappers_url/$existing_id" >/dev/null
  log_info "updated claim mapper '$claim' on client $client_uuid: '$existing_val' → '$value'"
}

# kc_get_user_id_by_username <token> <base> <realm> <username>  → echoes uuid or empty.
kc_get_user_id_by_username() {
  local token="$1" base="$2" realm="$3" username="$4"
  _kc_curl -fsS -G \
    -H "Authorization: Bearer $token" \
    --data-urlencode "username=$username" \
    --data-urlencode "exact=true" \
    "https://${base}/auth/admin/realms/${realm}/users" \
    | jq -r '.[0].id // empty'
}

# kc_create_user <token> <base> <realm> <username> <password>  → echoes uuid.
# Creates an enabled user with no required actions and a non-temporary password
# (so the seeded credential can be used to log in immediately). Caller should
# rotate via the admin console once a real human admin is provisioned.
kc_create_user() {
  local token="$1" base="$2" realm="$3" username="$4" password="$5"
  local body
  body=$(jq -n \
    --arg u "$username" \
    --arg p "$password" \
    '{
      username: $u,
      enabled: true,
      emailVerified: true,
      requiredActions: [],
      credentials: [{type:"password", value:$p, temporary:false}]
    }')
  _kc_curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms/${realm}/users" >/dev/null
  kc_get_user_id_by_username "$token" "$base" "$realm" "$username"
}

# kc_delete_user <token> <base> <realm> <user-uuid>
# 204/200 → deleted. 404 → already gone. Other HTTP codes fail.
kc_delete_user() {
  local token="$1" base="$2" realm="$3" uid="$4"
  local code
  code=$(_kc_curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer $token" \
    "https://${base}/auth/admin/realms/${realm}/users/${uid}")
  case "$code" in
    200|204|404) return 0 ;;
    *) log_err "kc_delete_user: unexpected HTTP $code"; return 1 ;;
  esac
}

# kc_add_user_to_group <token> <base> <realm> <user-uuid> <group-uuid>
# KC treats this as idempotent — re-PUTing a membership returns 204 without error.
kc_add_user_to_group() {
  local token="$1" base="$2" realm="$3" uid="$4" gid="$5"
  _kc_curl -fsS -X PUT \
    -H "Authorization: Bearer $token" \
    "https://${base}/auth/admin/realms/${realm}/users/${uid}/groups/${gid}" >/dev/null
}

# kc_add_usermodel_attr_mapper <token> <base> <realm> <client-uuid> <mapper-name>
#                              <user-attribute> <claim-name> [multivalued=false] [aggregate=false]
# Idempotent: skips if a mapper of this name already exists on the client.
kc_add_usermodel_attr_mapper() {
  local token="$1" base="$2" realm="$3" client_uuid="$4"
  local name="$5" user_attr="$6" claim_name="$7"
  local multivalued="${8:-false}" aggregate="${9:-false}"
  local existing
  existing=$(_kc_curl -fsS \
    -H "Authorization: Bearer $token" \
    "https://${base}/auth/admin/realms/${realm}/clients/${client_uuid}/protocol-mappers/models" \
    | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -n1)
  if [ -n "$existing" ]; then
    log_info "mapper '$name' already present on client (id=$existing); skipping"
    return 0
  fi
  local config
  config=$(jq -n \
    --arg ua "$user_attr" \
    --arg cn "$claim_name" \
    --arg mv "$multivalued" \
    --arg ag "$aggregate" \
    '{
      "user.attribute": $ua,
      "claim.name": $cn,
      "jsonType.label": "String",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "userinfo.token.claim": "true",
      "introspection.token.claim": "true",
      "lightweight.claim": "false",
      "multivalued": $mv,
      "aggregate.attrs": $ag
    }')
  local body
  body=$(jq -n \
    --arg name "$name" \
    --argjson config "$config" \
    '{
      name: $name,
      protocol: "openid-connect",
      protocolMapper: "oidc-usermodel-attribute-mapper",
      consentRequired: false,
      config: $config
    }')
  _kc_curl -fsS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://${base}/auth/admin/realms/${realm}/clients/${client_uuid}/protocol-mappers/models" >/dev/null
}
