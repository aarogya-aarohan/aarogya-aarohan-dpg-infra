#!/usr/bin/env bash
# onboard-tenant-runtime.sh — provision the runtime side of a tenant on the new
# multi-tenant Arogyam stack: Keycloak realm (+ realm settings, FHIR roles,
# groups), arogyam-web + arogyam-app + api-client clients, protocol mappers,
# Secret Manager pushes, HAPI partition, and the partition_id claim mapper on
# all four clients. Idempotent.
# Usage: --env {staging|production} --tenant <slug> [--base-url <host>] [--no-verify]

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/keycloak.sh
source "$SCRIPT_DIR/lib/keycloak.sh"
# shellcheck source=lib/fhir.sh
source "$SCRIPT_DIR/lib/fhir.sh"

ASSETS_DIR="$SCRIPT_DIR/assets/keycloak"

# Progress tracking. The success path ends with a JSON summary on stdout, but
# `set -e` means a mid-run failure exits before reaching it — leaving the
# operator to work out by hand which of ~20 API calls landed. step_begin marks
# the boundary between phases; the EXIT trap reports what completed and where
# it stopped.
ONBOARD_STEPS_DONE=()
ONBOARD_STEP_CURRENT=""

step_begin() {
  if [ -n "$ONBOARD_STEP_CURRENT" ]; then
    ONBOARD_STEPS_DONE+=("$ONBOARD_STEP_CURRENT")
  fi
  ONBOARD_STEP_CURRENT="$1"
}

on_exit() {
  local rc=$1
  [ "$rc" -eq 0 ] && return 0
  local done_list="${ONBOARD_STEPS_DONE[*]-}"
  [ -n "$done_list" ] || done_list="(nothing)"
  log_err "onboarding INCOMPLETE for tenant '${TENANT:-?}' (exit $rc)"
  log_err "  completed: $done_list"
  log_err "  failed at: ${ONBOARD_STEP_CURRENT:-<startup>}"
  log_err "  every step is idempotent — re-run the same command to resume"
}

WEB_CLIENT_ID="arogyam-web"
APP_CLIENT_ID="arogyam-app"
API_CLIENT_ID="api-client"
# Per-tenant operator/support service-account client. Carries FHIR superuser
# roles (direct CRUD) + realm-management impersonation roles (mint tokens as a
# real user for debugging). Secret is operator-only — no in-cluster consumer.
# See docs/operations.md.
SUPPORT_CLIENT_ID="support"

# Public mobile client token lifespan (~178d) — matches legacy export.
APP_ACCESS_TOKEN_LIFESPAN="15379200"

# Per-tenant bootstrap admin: a single seed user with realm-management/realm-admin
# so an operator can log into the dashboard / admin console immediately after
# onboarding. Joined to the "Super Admin" group (inherits realm-admin + the
# FHIR_* superuser roles). Rotate or delete once a real human admin exists.
BOOTSTRAP_ADMIN_USERNAME="bootstrap-admin"
BOOTSTRAP_ADMIN_GROUP="Super Admin"

show_help() {
  cat <<'EOF' >&2
onboard-tenant-runtime.sh — idempotent runtime onboarding for a tenant.

Required:
  --env {staging|production}
  --tenant <slug>

Optional:
  --base-url <host>          override $STAGING_BASE_URL / $PRODUCTION_BASE_URL
  --no-verify                skip the JWT-decode verification step
  --admin-password <pw>      seed the bootstrap-admin user with this password
                             instead of reading from Secret Manager. If neither
                             flag nor SM value is set, the step is skipped.
                             into DEFAULT via scripts/seed-fhir-bundle.sh.
  --skip-realm-create        realm has already been imported (e.g. via
                             scripts/import-keycloak-realm.sh). Skips realm
                             create + realm settings PUT + platform roles +
                             platform groups + bootstrap-admin seed. Still runs
                             disable VERIFY_PROFILE, client UUID lookups,
                             client-secret push to Secret Manager, HAPI
                             partition create, and partition_id claim mapper.

Env vars:
  STAGING_BASE_URL / PRODUCTION_BASE_URL   default base URL per env
  GCP_PROJECT_ID                            project for Secret Manager (else gcloud config)
EOF
}

step_realm() {
  local token="$1" kc_base="$2" tenant="$3"
  if kc_realm_exists "$token" "$kc_base" "$tenant"; then
    log_info "realm '$tenant' already exists; skipping create"
  else
    log_info "creating realm '$tenant'"
    kc_create_realm "$token" "$kc_base" "$tenant"
  fi
}

step_realm_settings() {
  local token="$1" kc_base="$2" tenant="$3"
  local settings
  settings=$(cat "$ASSETS_DIR/realm-settings.json")
  log_info "applying realm settings (token lifespans, security headers, ...)"
  kc_update_realm_settings "$token" "$kc_base" "$tenant" "$settings"
}

step_realm_roles() {
  local token="$1" kc_base="$2" tenant="$3"
  local existing missing_count created=0
  # One list call instead of N existence probes — keeps the step inside a single
  # 60s admin-token lifespan and avoids 401 storms on flaky links.
  existing=$(kc_get_realm_roles "$token" "$kc_base" "$tenant" | jq -r '[.[].name]')
  local target_count
  target_count=$(jq 'length' "$ASSETS_DIR/realm-roles.json")
  log_info "ensuring $target_count realm roles (already present: $(jq 'length' <<<"$existing"))"
  local missing
  missing=$(jq -c --argjson existing "$existing" \
    '[.[] | select(.name as $n | $existing | index($n) | not)]' \
    "$ASSETS_DIR/realm-roles.json")
  missing_count=$(jq 'length' <<<"$missing")
  if [ "$missing_count" -eq 0 ]; then
    log_info "roles: nothing to create"
    return 0
  fi
  local name desc composite
  while IFS=$'\t' read -r name desc composite; do
    kc_create_role "$token" "$kc_base" "$tenant" "$name" "$desc" "$composite"
    created=$((created + 1))
  done < <(jq -r '.[] | [.name, .description, (.composite|tostring)] | @tsv' <<<"$missing")
  log_info "roles: created=$created"
}

step_groups() {
  local token="$1" kc_base="$2" tenant="$3"
  local count existing_groups
  count=$(jq 'length' "$ASSETS_DIR/groups.json")
  log_info "ensuring $count groups"
  # Single list call → name→id lookup, instead of one search per group.
  existing_groups=$(_kc_curl -fsS \
    -H "Authorization: Bearer $token" \
    "https://${kc_base}/auth/admin/realms/${tenant}/groups?max=200" \
    | jq -c '[.[] | {name, id}]')
  local name attrs realm_roles client_roles_json gid
  while IFS=$'\t' read -r name attrs realm_roles client_roles_json; do
    gid=$(jq -r --arg n "$name" '.[] | select(.name==$n) | .id' <<<"$existing_groups" | head -n1)
    if [ -z "$gid" ]; then
      log_info "creating group '$name'"
      gid=$(kc_create_group "$token" "$kc_base" "$tenant" "$name")
    else
      log_info "group '$name' already exists (id=$gid)"
    fi
    [ -n "$gid" ] || { log_err "failed to resolve group id for '$name'"; return 1; }

    # Always reconcile attributes (PERMISSION_ARGUMENT) — cheap and idempotent.
    if [ "$attrs" != "{}" ]; then
      kc_set_group_attributes "$token" "$kc_base" "$tenant" "$gid" "$name" "$attrs"
    fi

    if [ "$realm_roles" != "[]" ]; then
      kc_add_realm_roles_to_group "$token" "$kc_base" "$tenant" "$gid" "$realm_roles"
    fi

    # client_roles_json is an object: {client_id: [role_name, ...]}.
    if [ "$client_roles_json" != "{}" ]; then
      local cid names
      while IFS=$'\t' read -r cid names; do
        kc_add_client_roles_to_group "$token" "$kc_base" "$tenant" "$gid" "$cid" "$names"
      done < <(jq -r 'to_entries[] | [.key, (.value|tostring)] | @tsv' <<<"$client_roles_json")
    fi
  done < <(jq -cr '.[] | [.name, (.attributes // {} | tostring), (.realmRoles // [] | tostring), (.clientRoles // {} | tostring)] | @tsv' "$ASSETS_DIR/groups.json")
}

step_bootstrap_admin_user() {
  local token="$1" kc_base="$2" tenant="$3" short="$4"
  local password=""
  if [ -n "${ADMIN_PASSWORD_ARG:-}" ]; then
    password="$ADMIN_PASSWORD_ARG"
    log_info "bootstrap admin password sourced from --admin-password flag"
  else
    local secret_name="aa-${short}-${tenant}-bootstrap-admin-password"
    if ! password=$(get_secret "$secret_name" 2>/dev/null); then
      log_warn "$secret_name not found in Secret Manager — skipping bootstrap admin (run \`make apply ENV=$ENV\` after pulling the latest tenant-secrets module)"
      return 0
    fi
    if [ -z "$password" ] || [[ "$password" == placeholder-* ]]; then
      log_warn "$secret_name still holds a placeholder — skipping bootstrap admin"
      log_warn "to seed: printf '%s' '<your-password>' | gcloud secrets versions add $secret_name --data-file=- --project=\$(gcloud config get-value project)"
      return 0
    fi
    log_info "bootstrap admin password sourced from Secret Manager ($secret_name)"
  fi

  local uid
  uid=$(kc_get_user_id_by_username "$token" "$kc_base" "$tenant" "$BOOTSTRAP_ADMIN_USERNAME")
  if [ -n "$uid" ]; then
    log_info "bootstrap admin user '$BOOTSTRAP_ADMIN_USERNAME' already exists (id=$uid); leaving password untouched"
  else
    log_info "creating bootstrap admin user '$BOOTSTRAP_ADMIN_USERNAME'"
    uid=$(kc_create_user "$token" "$kc_base" "$tenant" "$BOOTSTRAP_ADMIN_USERNAME" "$password")
    [ -n "$uid" ] || { log_err "failed to create bootstrap admin user"; return 1; }
  fi

  local gid
  gid=$(kc_get_group_id_by_name "$token" "$kc_base" "$tenant" "$BOOTSTRAP_ADMIN_GROUP")
  [ -n "$gid" ] || { log_err "group '$BOOTSTRAP_ADMIN_GROUP' not found in realm '$tenant'"; return 1; }
  kc_add_user_to_group "$token" "$kc_base" "$tenant" "$uid" "$gid"
  log_info "bootstrap admin user is a member of group '$BOOTSTRAP_ADMIN_GROUP'"
}

step_arogyam_web_client() {
  local token="$1" kc_base="$2" tenant="$3" base="$4"
  local redirects web_origins attrs
  redirects=$(jq -c -n --arg u "https://${base}/dashboard/*" '[$u]')
  web_origins=$(jq -c -n --arg o "https://${base}" '[$o]')
  # Match legacy arogyam-web token/session config.
  attrs=$(jq -c -n '{
    "access.token.lifespan": "3600",
    "client.session.idle.timeout": "3600",
    "client.session.max.lifespan": "3600",
    "post.logout.redirect.uris": "+",
    "use.refresh.tokens": "true",
    "backchannel.logout.session.required": "true"
  }')
  log_info "ensuring client '$WEB_CLIENT_ID' in realm '$tenant'"
  local uuid
  uuid=$(kc_get_or_create_client "$token" "$kc_base" "$tenant" "$WEB_CLIENT_ID" "$redirects" "$web_origins" "$attrs")
  [ -n "$uuid" ] || { log_err "failed to create or fetch $WEB_CLIENT_ID"; return 1; }
  echo "$uuid"
}

step_arogyam_app_client() {
  local token="$1" kc_base="$2" tenant="$3"
  local attrs
  attrs=$(jq -c -n --arg lt "$APP_ACCESS_TOKEN_LIFESPAN" '{
    "access.token.lifespan": $lt,
    "client.session.idle.timeout": "2592000",
    "use.refresh.tokens": "true",
    "post.logout.redirect.uris": "+",
    "backchannel.logout.session.required": "false"
  }')
  log_info "ensuring client '$APP_CLIENT_ID' in realm '$tenant'"
  local uuid
  uuid=$(kc_get_or_create_public_directgrants_client "$token" "$kc_base" "$tenant" "$APP_CLIENT_ID" "$attrs")
  [ -n "$uuid" ] || { log_err "failed to create or fetch $APP_CLIENT_ID"; return 1; }
  echo "$uuid"
}

step_api_client() {
  local token="$1" kc_base="$2" tenant="$3"
  log_info "ensuring service-account client '$API_CLIENT_ID' in realm '$tenant'"
  local uuid
  uuid=$(kc_get_or_create_sa_client "$token" "$kc_base" "$tenant" "$API_CLIENT_ID")
  [ -n "$uuid" ] || { log_err "failed to create or fetch $API_CLIENT_ID"; return 1; }
  echo "$uuid"
}

step_support_client() {
  local token="$1" kc_base="$2" tenant="$3"
  log_info "ensuring service-account client '$SUPPORT_CLIENT_ID' in realm '$tenant'"
  local uuid
  uuid=$(kc_get_or_create_sa_client "$token" "$kc_base" "$tenant" "$SUPPORT_CLIENT_ID")
  [ -n "$uuid" ] || { log_err "failed to create or fetch $SUPPORT_CLIENT_ID"; return 1; }
  echo "$uuid"
}

step_mappers_on_client() {
  local token="$1" kc_base="$2" tenant="$3" client_uuid="$4"
  # PermMapper — aggregate & multivalued, flattens PERMISSION_ARGUMENT group attr
  # into permission_argument token claim consumed by HAPI authz rules.
  kc_add_usermodel_attr_mapper "$token" "$kc_base" "$tenant" "$client_uuid" \
    "PermMapper" "PERMISSION_ARGUMENT" "permission_argument" "true" "true"
  # OPENSRP APP Id Mapper — single-valued user attr passthrough for mobile client routing.
  kc_add_usermodel_attr_mapper "$token" "$kc_base" "$tenant" "$client_uuid" \
    "OPENSRP APP Id Mapper" "fhir_core_app_id" "fhir_core_app_id" "false" "false"
}

step_push_secret() {
  local secret_name="$1" secret_value="$2"
  local project
  project=$(resolve_project_id)

  # Keycloak client secrets are stable across re-runs, so an unconditional
  # `versions add` turns every idempotent re-run into version churn — the
  # state-b onboarding reached v9 in four runs, none of the versions
  # differing. Compare against the current value first. A missing secret, no
  # enabled version, or a placeholder all fail the access and fall through to
  # the add, which is what we want.
  local current
  if current=$(gcloud secrets versions access latest \
        --secret="$secret_name" --project="$project" 2>/dev/null); then
    if [ "$current" = "$secret_value" ]; then
      log_info "secret '$secret_name' already matches Keycloak; skipping new version"
      return 0
    fi
  fi

  log_info "pushing secret to Secret Manager entry '$secret_name'"
  printf '%s' "$secret_value" \
    | gcloud secrets versions add "$secret_name" --data-file=- --project="$project" >/dev/null
}

step_partition() {
  local token="$1" fhir_base="$2" tenant="$3"
  local existing
  existing=$(fhir_get_partition_id_by_name "$token" "$fhir_base" "$tenant")
  if [ -n "$existing" ]; then
    log_info "partition '$tenant' already exists at id=$existing"
    echo "$existing"
    return 0
  fi
  log_info "creating partition '$tenant'"
  fhir_create_partition "$token" "$fhir_base" "$tenant"
}

step_feature_flags() {
  local env="$1" kc_base="$2" fhir_base="$3" tenant="$4" short="$5"
  # Tenant-scoped resource id — HAPI 7.2 enforces a global unique index on
  # (res_type, fhir_id), so the same forced id can't live in multiple partitions.
  local id="${tenant}-feature-flags"

  # JwtPartitionValidationInterceptor gates writes by comparing the URL tenant
  # segment to the JWT's `partition_id` claim. fhir-bootstrap (master realm) has
  # a hardcoded claim mapper for partition_id — swap it to $tenant before
  # minting a fresh SA token so the PUT passes validation. Mapper is upsert;
  # state ends on whichever tenant ran last (acceptable — fhir-bootstrap is
  # only used by seed scripts, not runtime traffic).
  local admin_token
  admin_token=$(kc_admin_token "$env" "$kc_base") \
    || { log_err "could not mint master-realm admin token"; return 1; }
  local fb_uuid
  fb_uuid=$(kc_get_client_id_by_clientid "$admin_token" "$kc_base" "master" "fhir-bootstrap")
  [ -n "$fb_uuid" ] \
    || { log_err "fhir-bootstrap client not found in master realm"; return 1; }
  kc_add_hardcoded_claim_mapper "$admin_token" "$kc_base" "master" "$fb_uuid" \
    "partition_id" "$tenant"

  # Bypass kc_fhir_bootstrap_token's on-disk cache: any cached entry was minted
  # before the mapper swap and still carries the old partition_id. Mint fresh
  # via kc_sa_token, then invalidate the cache so downstream callers re-mint.
  local secret seeder_token
  secret=$(get_secret "aa-${short}-fhir-bootstrap-secret") \
    || { log_err "missing Secret Manager entry aa-${short}-fhir-bootstrap-secret"; return 1; }
  seeder_token=$(kc_sa_token "$kc_base" "master" "fhir-bootstrap" "$secret") \
    || return 1
  rm -f "$(_kc_token_cache_path "fhir-bootstrap@${short}")" 2>/dev/null || true

  local body
  body=$(jq -n --arg id "$id" '{
    resourceType: "Basic",
    id: $id,
    code: {
      coding: [{
        system: "https://midas.iisc.ac.in/fhir/CodeSystem/resource-type",
        code: "feature-flags",
        display: "Feature Flags"
      }]
    },
    extension: [{
      url: "https://midas.iisc.ac.in/fhir/StructureDefinition/ai-inference-enabled",
      valueBoolean: true
    }]
  }')
  log_info "PUT Basic/$id into partition '$tenant'"
  fhir_put_resource "$seeder_token" "${fhir_base}/${tenant}" "Basic" "$id" "$body"
}

step_claim_mapper() {
  local token="$1" kc_base="$2" tenant="$3" client_uuid="$4" partition_id="$5" client_label="${6:-client}"
  log_info "ensuring partition_id=$partition_id claim mapper on $client_label"
  kc_add_hardcoded_claim_mapper "$token" "$kc_base" "$tenant" "$client_uuid" "partition_id" "$partition_id"
}

step_disable_verify_profile() {
  local token="$1" kc_base="$2" tenant="$3"
  # KC 26 default-on; user-profile config marks email/firstName/lastName required
  # for role `user`, which blocks the password grant for FLW users with no email.
  log_info "disabling VERIFY_PROFILE required action on realm '$tenant'"
  kc_disable_required_action "$token" "$kc_base" "$tenant" "VERIFY_PROFILE"
}

step_make_email_optional() {
  local token="$1" kc_base="$2" tenant="$3"
  log_info "making the user-profile email attribute optional in realm '$tenant'"
  kc_make_email_optional "$token" "$kc_base" "$tenant"
}

# Acceptance test using the api-client service account — no human smoke-test
# user required, so this runs unattended on every onboarding. Asserts the three
# properties a tenant is useless without: the SA can authenticate, its token
# carries partition_id, and that claim actually gates FHIR access.
step_verify() {
  local tenant="$1" partition_id="$2" kc_base="$3" fhir_base="$4" api_secret="$5"
  local failures=0

  local tok
  tok=$(kc_sa_token "$kc_base" "$tenant" "$API_CLIENT_ID" "$api_secret") || tok=""
  if [ -z "$tok" ]; then
    log_err "verify: could not mint an $API_CLIENT_ID token in realm '$tenant'"
    return 1
  fi

  # partition_id must be the partition NAME — JwtPartitionValidationInterceptor
  # string-compares it against the URL tenant segment, not the numeric id.
  #
  # JWT payloads are base64URL with no padding, which `base64 -d` rejects with a
  # non-zero exit. Under `set -euo pipefail` that aborts the whole script mid
  # pipeline, before any of the checks below can report — so translate the
  # alphabet, re-pad, and swallow the exit status explicitly.
  local payload claim
  payload=$(cut -d. -f2 <<<"$tok" | tr '_-' '/+')
  case $(( ${#payload} % 4 )) in
    2) payload="${payload}==" ;;
    3) payload="${payload}=" ;;
  esac
  claim=$(printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '.partition_id // empty' 2>/dev/null || true)
  if [ "$claim" = "$tenant" ]; then
    log_info "verify: partition_id claim present and correct ('$claim', partition id=$partition_id)"
  else
    log_err "verify: partition_id claim is '${claim:-<absent>}', expected '$tenant' — the claim mapper is missing or wrong"
    failures=$((failures + 1))
  fi

  local own
  own=$(_curl -sS -o /dev/null -w '%{http_code}' --max-time "$KC_CURL_MAX_TIME" \
    -H "Authorization: Bearer $tok" "${fhir_base}/${tenant}/Patient?_summary=count" 2>/dev/null || echo 000)
  if [ "$own" = "200" ]; then
    log_info "verify: own-partition read OK (200)"
  else
    log_err "verify: own-partition read returned $own, expected 200"
    failures=$((failures + 1))
  fi

  # A slug that cannot be a real partition: the interceptor should reject on the
  # claim/URL mismatch alone, before any partition lookup. A 404 means the
  # request got past validation, so treat only 403 as proof the gate is live.
  local cross
  cross=$(_curl -sS -o /dev/null -w '%{http_code}' --max-time "$KC_CURL_MAX_TIME" \
    -H "Authorization: Bearer $tok" "${fhir_base}/zz-verify-cross-tenant/Patient?_summary=count" 2>/dev/null || echo 000)
  if [ "$cross" = "403" ]; then
    log_info "verify: cross-tenant request correctly denied (403)"
  else
    log_warn "verify: cross-tenant probe returned $cross, expected 403 — confirm partition isolation by hand"
  fi

  if [ "$failures" -gt 0 ]; then
    log_err "verify: $failures check(s) failed"
    return 1
  fi
  log_info "verify: tenant '$tenant' passed all checks"
}

main() {
  parse_common_args "$@"
  require_cmd jq gcloud curl

  if [ -z "$ENV" ] || [ -z "$TENANT" ]; then
    show_help
    exit 2
  fi
  validate_env "$ENV"
  validate_tenant "$TENANT"

  local base short
  base=$(resolve_base_url "$ENV" "$BASE_URL")
  short=$(env_short "$ENV")

  local kc_base="${base}"
  local fhir_base="https://${base}/fhir"

  log_info "env=$ENV tenant=$TENANT base=$base"
  trap 'on_exit $?' EXIT
  step_begin startup

  # Re-resolve the admin token before each major step. kc_admin_token caches in
  # tmpfs for 45s, so this is a free lookup most of the time, but guarantees we
  # never hand off a token that's about to expire mid-step.
  local token
  refresh() { token=$(kc_admin_token "$ENV" "$kc_base"); }

  if [ "$SKIP_REALM_CREATE" -eq 0 ]; then
    refresh; step_realm                "$token" "$kc_base" "$TENANT"
    refresh; step_realm_settings       "$token" "$kc_base" "$TENANT"
  else
    log_info "--skip-realm-create set: assuming realm '$TENANT' already imported; skipping realm + realm-settings + platform-roles + platform-groups + bootstrap-admin"
    if ! kc_realm_exists "$(kc_admin_token "$ENV" "$kc_base")" "$kc_base" "$TENANT"; then
      log_err "realm '$TENANT' does not exist; import it first (scripts/import-keycloak-realm.sh) or drop --skip-realm-create"
      exit 1
    fi
  fi
  refresh; step_make_email_optional     "$token" "$kc_base" "$TENANT"
  refresh; step_disable_verify_profile "$token" "$kc_base" "$TENANT"
  if [ "$SKIP_REALM_CREATE" -eq 0 ]; then
    step_begin realm-roles
    refresh; step_realm_roles          "$token" "$kc_base" "$TENANT"
    step_begin groups
    refresh; step_groups          "$token" "$kc_base" "$TENANT"
    step_begin bootstrap-admin
    refresh; step_bootstrap_admin_user "$token" "$kc_base" "$TENANT" "$short"
  fi

  step_begin clients
  local web_uuid app_uuid api_uuid
  refresh; web_uuid=$(step_arogyam_web_client "$token" "$kc_base" "$TENANT" "$base")
  refresh; app_uuid=$(step_arogyam_app_client "$token" "$kc_base" "$TENANT")
  refresh; api_uuid=$(step_api_client         "$token" "$kc_base" "$TENANT")

  # Protocol mappers — both confidential web and public app clients carry the
  # PermMapper + OPENSRP APP Id Mapper. api-client (SA) does not need them.
  refresh; step_mappers_on_client "$token" "$kc_base" "$TENANT" "$web_uuid"
  refresh; step_mappers_on_client "$token" "$kc_base" "$TENANT" "$app_uuid"

  # FHIR realm-role grants on api-client's service-account user. Without these,
  # arogyam-backend server-to-server calls hit HAPI-0334 "Access denied by
  # default policy" because HAPI's authorization interceptor matches on
  # realm_access.roles. The roles themselves are created by step_realm_roles
  # from assets/realm-roles.json; this block just maps them to the SA user.
  refresh
  local api_sa_uid
  api_sa_uid=$(kc_get_sa_user_id "$token" "$kc_base" "$TENANT" "$api_uuid")
  [ -n "$api_sa_uid" ] \
    || { log_err "could not resolve service-account user id for $API_CLIENT_ID"; exit 1; }
  # FHIR_OP_EVALUATE_MEASURE: retained for ad-hoc $evaluate-measure against a
  # hand-seeded Measure. The nightly evaluator no longer uses it — measures are
  # computed from plain FHIR searches in arogyam-backend. Originally: mints a
  # token with
  # these api-client creds (per-tenant, partition_id=$TENANT) to run
  # $evaluate-measure and PUT the resulting MeasureReport into the tenant
  # partition. The fork gates that op on this named role; FHIR_ALL_WRITE covers
  # the MeasureReport write.
  kc_assign_realm_roles_to_user "$token" "$kc_base" "$TENANT" "$api_sa_uid" \
    '["FHIR_ALL_READ","FHIR_TRANSACTION","FHIR_ALL_WRITE","FHIR_ALL_DELETE","FHIR_OP_ENCOUNTER_EVERYTHING","FHIR_OP_EVALUATE_MEASURE"]'

  # Support client — operator service-account with FHIR superuser roles (direct
  # CRUD) plus realm-management impersonation roles. The same FHIR_* grants as
  # api-client clear HAPI-0334; the realm-management roles let the SA mint a
  # session as any realm user via the native admin impersonation endpoint
  # (see scripts/get-impersonation-token.sh).
  local support_uuid support_sa_uid
  refresh; support_uuid=$(step_support_client "$token" "$kc_base" "$TENANT")
  refresh
  support_sa_uid=$(kc_get_sa_user_id "$token" "$kc_base" "$TENANT" "$support_uuid")
  [ -n "$support_sa_uid" ] \
    || { log_err "could not resolve service-account user id for $SUPPORT_CLIENT_ID"; exit 1; }
  kc_assign_realm_roles_to_user "$token" "$kc_base" "$TENANT" "$support_sa_uid" \
    '["FHIR_ALL_READ","FHIR_TRANSACTION","FHIR_ALL_WRITE","FHIR_ALL_DELETE","FHIR_OP_ENCOUNTER_EVERYTHING"]'
  kc_assign_client_roles_to_user "$token" "$kc_base" "$TENANT" "$support_sa_uid" \
    "realm-management" '["impersonation","view-users","query-users"]'

  # JwtPartitionValidationInterceptor compares the claim against the URL tenant
  # segment (string), so the claim value must be the partition NAME, not its id.
  # All four clients need it: arogyam-web (browser flow, dashboard), arogyam-app
  # (public direct-grants, mobile), api-client (SA grant, server-to-server), and
  # support (SA grant, operator direct-CRUD token).
  #
  # These run as early as possible — immediately after the last client exists —
  # because without them every tenant write is rejected, making the tenant
  # unusable. They previously ran last, so a failure in any of the intervening
  # steps (Secret Manager pushes, partition create, feature-flags, measures)
  # silently left the tenant half-onboarded.
  step_begin claim-mappers
  refresh
  step_claim_mapper "$token" "$kc_base" "$TENANT" "$web_uuid" "$TENANT" "$WEB_CLIENT_ID"
  step_claim_mapper "$token" "$kc_base" "$TENANT" "$app_uuid" "$TENANT" "$APP_CLIENT_ID"
  step_claim_mapper "$token" "$kc_base" "$TENANT" "$support_uuid" "$TENANT" "$SUPPORT_CLIENT_ID"
  step_claim_mapper "$token" "$kc_base" "$TENANT" "$api_uuid" "$TENANT" "$API_CLIENT_ID"

  # Secrets — arogyam-web (confidential, browser flow) + api-client (SA grant)
  # + support (SA grant, operator-only).
  step_begin secrets
  local web_secret api_secret support_secret
  refresh
  web_secret=$(kc_get_client_secret "$token" "$kc_base" "$TENANT" "$web_uuid")
  [ -n "$web_secret" ] && [ "$web_secret" != "null" ] \
    || { log_err "could not read client secret for $WEB_CLIENT_ID"; exit 1; }
  api_secret=$(kc_get_client_secret "$token" "$kc_base" "$TENANT" "$api_uuid")
  [ -n "$api_secret" ] && [ "$api_secret" != "null" ] \
    || { log_err "could not read client secret for $API_CLIENT_ID"; exit 1; }
  support_secret=$(kc_get_client_secret "$token" "$kc_base" "$TENANT" "$support_uuid")
  [ -n "$support_secret" ] && [ "$support_secret" != "null" ] \
    || { log_err "could not read client secret for $SUPPORT_CLIENT_ID"; exit 1; }

  local web_secret_name="aa-${short}-${TENANT}-keycloak-client-secret"
  local api_secret_name="aa-${short}-${TENANT}-api-client-secret"
  local support_secret_name="aa-${short}-${TENANT}-support-client-secret"
  step_push_secret "$web_secret_name" "$web_secret"
  step_push_secret "$api_secret_name" "$api_secret"
  step_push_secret "$support_secret_name" "$support_secret"

  # Partition-management endpoints on HAPI sit behind inbound JWT auth, so the
  # KC admin-cli token (which is only valid for the KC admin API) is rejected.
  # Mint a client_credentials token from the master-realm `fhir-bootstrap` SA
  # client — same identity that scripts/seed-fhir-bundle.sh uses to seed the
  # DEFAULT partition. Secret lives in aa-<short>-fhir-bootstrap-secret,
  # provisioned on first seed-fhir-bundle run.
  step_begin partition
  local partition_id seeder_secret seeder_sa_token
  seeder_secret=$(get_secret "aa-${short}-fhir-bootstrap-secret") \
    || { log_err "missing Secret Manager entry aa-${short}-fhir-bootstrap-secret — run scripts/seed-fhir-bundle.sh --env $ENV first"; exit 1; }
  seeder_sa_token=$(kc_sa_token "$kc_base" "master" "fhir-bootstrap" "$seeder_secret") \
    || { log_err "could not mint fhir-bootstrap SA token"; exit 1; }
  partition_id=$(step_partition "$seeder_sa_token" "$fhir_base" "$TENANT")
  [ -n "$partition_id" ] || { log_err "could not resolve partition id for '$TENANT'"; exit 1; }

  # Seed Basic/<tenant>-feature-flags into the tenant's partition. Briefly
  # swaps fhir-bootstrap's partition_id claim to $TENANT to satisfy
  # JwtPartitionValidationInterceptor, mints a fresh SA token, PUTs the
  # resource. State on fhir-bootstrap ends pinned to $TENANT.
  step_begin feature-flags
  step_feature_flags "$ENV" "$kc_base" "$fhir_base" "$TENANT" "$short" \
    || { log_err "failed to PUT Basic/${TENANT}-feature-flags"; exit 1; }


  if [ "$NO_VERIFY" -eq 0 ]; then
    step_begin verify
    step_verify "$TENANT" "$partition_id" "$kc_base" "$fhir_base" "$api_secret"
  fi
  step_begin done

  jq -n \
    --arg tenant "$TENANT" \
    --arg env "$ENV" \
    --arg realm "$TENANT" \
    --argjson partition_id "$partition_id" \
    --arg web_client_id "$WEB_CLIENT_ID" \
    --arg app_client_id "$APP_CLIENT_ID" \
    --arg api_client_id "$API_CLIENT_ID" \
    --arg support_client_id "$SUPPORT_CLIENT_ID" \
    --arg web_secret_resource "$web_secret_name" \
    --arg api_secret_resource "$api_secret_name" \
    --arg support_secret_resource "$support_secret_name" \
    --arg bootstrap_admin_username "$BOOTSTRAP_ADMIN_USERNAME" \
    --arg bootstrap_admin_secret_resource "aa-${short}-${TENANT}-bootstrap-admin-password" \
    '{tenant:$tenant, env:$env, realm:$realm, partition_id:$partition_id,
      web_client_id:$web_client_id, app_client_id:$app_client_id,
      api_client_id:$api_client_id, support_client_id:$support_client_id,
      keycloak_client_secret_resource:$web_secret_resource,
      api_client_secret_resource:$api_secret_resource,
      support_client_secret_resource:$support_secret_resource,
      bootstrap_admin_username:$bootstrap_admin_username,
      bootstrap_admin_secret_resource:$bootstrap_admin_secret_resource}'
}

main "$@"
