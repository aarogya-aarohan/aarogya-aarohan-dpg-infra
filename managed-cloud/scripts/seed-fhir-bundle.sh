#!/usr/bin/env bash
# seed-fhir-bundle.sh — POST the platform FHIR config bundle to an env's
# DEFAULT partition (https://<base>/fhir/DEFAULT) using a master-realm service
# account `fhir-bootstrap`. The bundle holds the app's platform schema
# (SearchParameter, CodeSystem, StructureMap, Library, Questionnaire,
# PlanDefinition, Composition, Location, Binary, …) which is shared across
# every tenant; the arogyam-backend addresses it directly at /fhir/DEFAULT/...
# Tenant-scoped reads (/fhir/<tenant>/...) only carry per-tenant data.
#
# Idempotent: bundle entries are PUT-by-id, so re-runs upsert in place. The
# script also skips POST when /fhir/DEFAULT/Composition?identifier=app already
# returns a hit, unless --force is set.
#
# Usage:
#   seed-fhir-bundle.sh --env {staging|production} [--base-url <host>] \
#                       [--bundle <path>] [--force]

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/keycloak.sh
source "$SCRIPT_DIR/lib/keycloak.sh"
# shellcheck source=lib/fhir.sh
source "$SCRIPT_DIR/lib/fhir.sh"

SEEDER_CLIENT_ID="fhir-bootstrap"
# Per-env bundle: assets/fhir/bundle.<env>.json (resolved once $ENV is known).

FORCE=0

show_help() {
  cat <<'EOF' >&2
seed-fhir-bundle.sh — POST the platform FHIR bundle to <base>/fhir/DEFAULT.

Required:
  --env {staging|production}

Optional:
  --base-url <host>  override $STAGING_BASE_URL / $PRODUCTION_BASE_URL
  --bundle <path>    override default bundle (scripts/assets/fhir/bundle.<env>.json)
  --force            seed even if Composition(identifier=app) is already present
EOF
}

EXTRA_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    *)       EXTRA_ARGS+=("$1"); shift ;;
  esac
done
parse_common_args "${EXTRA_ARGS[@]}"
require_cmd jq gcloud curl

if [ -z "$ENV" ]; then
  show_help
  exit 2
fi
validate_env "$ENV"

base=$(resolve_base_url "$ENV" "$BASE_URL")
short=$(env_short "$ENV")
kc_base="${base}"
# URL-based partitioning rejects requests without a partition segment; DEFAULT
# is the literal name HAPI uses for the global/default partition.
fhir_default_base="https://${base}/fhir/DEFAULT"
bundle_path="${BUNDLE_PATH:-$SCRIPT_DIR/assets/fhir/bundle.${ENV}.json}"
secret_name="aa-${short}-fhir-bootstrap-secret"

[ -f "$bundle_path" ] || { log_err "bundle file not found: $bundle_path"; exit 1; }

log_info "env=$ENV base=$base bundle=$bundle_path"

# Master-realm `fhir-bootstrap` service account: provisioned on first run.
admin_token=$(kc_admin_token "$ENV" "$kc_base")
log_info "ensuring service-account client '$SEEDER_CLIENT_ID' in realm 'master'"
seeder_uuid=$(kc_get_or_create_sa_client "$admin_token" "$kc_base" "master" "$SEEDER_CLIENT_ID")
[ -n "$seeder_uuid" ] || { log_err "could not create or fetch master-realm $SEEDER_CLIENT_ID client"; exit 1; }

# HAPI inbound authz (introduced in 27bec84) gates FHIR ops on JWT
# realm_access.roles. fhir-bootstrap needs:
#   FHIR_EXTENDED_OPERATION_ON_SERVER + FHIR_EXTENDED_OPERATION_SUPERUSER
#     — server-level extended ops ($partition-management-*, etc.); without
#       these tenant onboarding fails 403 on partition create.
#   FHIR_ALL_READ + FHIR_ALL_WRITE
#     — bulk read/write on every resource type; required by migrate-tenant.sh
#       to PUT exported NDJSON into a tenant partition. Paired with a per-
#       migration partition_id claim mapper that migrate-tenant.sh prepare-auth
#       points at the tenant being migrated.
#   FHIR_OP_EVALUATE_MEASURE
#     — the fork gates named CR operations by FHIR_OP_<NAME>; without this,
#       $evaluate-measure returns HAPI-0334 even for a superuser. Used by
#       Dashboard metrics no longer live here — they are computed from FHIR
#       searches by the measure-evaluator Job (see docs/operations.md).
# Roles are created (idempotent) and assigned to the SA user below.
SEEDER_ROLES='["FHIR_EXTENDED_OPERATION_ON_SERVER","FHIR_EXTENDED_OPERATION_SUPERUSER","FHIR_ALL_READ","FHIR_ALL_WRITE","FHIR_OP_EVALUATE_MEASURE"]'
existing_master_roles=$(kc_get_realm_roles "$admin_token" "$kc_base" "master" | jq -r '[.[].name]')
for role in $(jq -r '.[]' <<<"$SEEDER_ROLES"); do
  if ! jq -e --arg r "$role" 'index($r)' <<<"$existing_master_roles" >/dev/null; then
    log_info "creating master-realm role '$role' for $SEEDER_CLIENT_ID"
    kc_create_role "$admin_token" "$kc_base" "master" "$role" "Granted to $SEEDER_CLIENT_ID for HAPI server-level extended operations" "false"
  fi
done
seeder_sa_uid=$(kc_get_sa_user_id "$admin_token" "$kc_base" "master" "$seeder_uuid")
[ -n "$seeder_sa_uid" ] || { log_err "could not resolve service-account user for $SEEDER_CLIENT_ID"; exit 1; }
log_info "assigning realm roles $SEEDER_ROLES to $SEEDER_CLIENT_ID SA user"
kc_assign_realm_roles_to_user "$admin_token" "$kc_base" "master" "$seeder_sa_uid" "$SEEDER_ROLES"

# Long-running migrations (migrate-tenant.sh import: ~30+ min for a single
# tenant) hold a single fhir-bootstrap token throughout. Override the
# master-realm default access-token lifespan on just this client to 60min;
# kc_fhir_bootstrap_token's cache TTL (_KC_FHIR_BOOTSTRAP_CACHE_TTL) is set
# 50min so a cached token can never present-as-expired to HAPI.
log_info "setting access.token.lifespan=3600 on $SEEDER_CLIENT_ID"
kc_set_client_attribute "$admin_token" "$kc_base" "master" "$seeder_uuid" "access.token.lifespan" "3600"

seeder_secret_value=$(kc_get_client_secret "$admin_token" "$kc_base" "master" "$seeder_uuid")
if [ -z "$seeder_secret_value" ] || [ "$seeder_secret_value" = "null" ]; then
  log_err "could not read client secret for $SEEDER_CLIENT_ID"
  exit 1
fi

log_info "pushing seeder client secret to Secret Manager entry '$secret_name'"
project=$(resolve_project_id)
printf '%s' "$seeder_secret_value" \
  | gcloud secrets versions add "$secret_name" --data-file=- --project="$project" >/dev/null

sa_token=$(kc_sa_token "$kc_base" "master" "$SEEDER_CLIENT_ID" "$seeder_secret_value")
[ -n "$sa_token" ] || { log_err "could not mint $SEEDER_CLIENT_ID client_credentials token"; exit 1; }

if [ "$FORCE" -eq 0 ]; then
  existing=$(_curl -fsS \
    -H "Authorization: Bearer $sa_token" \
    -H "Accept: application/fhir+json" \
    "${fhir_default_base}/Composition?identifier=app&_summary=count" \
    | jq -r '.total // 0')
  if [ "${existing:-0}" -ge 1 ]; then
    log_info "DEFAULT partition already has Composition(identifier=app); skipping (use --force to override)"
    jq -n --arg env "$ENV" --arg secret_resource "$secret_name" \
      '{env:$env, bootstrap_secret_resource:$secret_resource, bundle_status:"skipped"}'
    exit 0
  fi
fi

log_info "POSTing config bundle to ${fhir_default_base} ($(wc -c <"$bundle_path") bytes)"
if ! fhir_post_bundle "$sa_token" "$fhir_default_base" "$bundle_path"; then
  log_err "bundle POST failed"
  exit 1
fi

jq -n --arg env "$ENV" --arg secret_resource "$secret_name" \
  '{env:$env, bootstrap_secret_resource:$secret_resource, bundle_status:"seeded"}'
