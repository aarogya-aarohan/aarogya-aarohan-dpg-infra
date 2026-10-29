#!/usr/bin/env bash
# delete-user.sh — remove a dashboard/test user from a tenant realm + FHIR partition.
#
# Inverse of create-program-admin.sh / the dashboard Users "Add user" flow.
# Deletes:
#   1. PractitionerRole(s) linked by KUID (Keycloak sub) or Practitioner ref
#   2. Group(s) that wrap that Practitioner (dashboard create-user Group)
#   3. Practitioner
#   4. Keycloak user in the tenant realm
#
# Does NOT delete Patients, Tasks, Encounters, or Locations. HAPI may refuse to
# delete a Practitioner that is still referenced (e.g. Task.owner); the script
# then leaves that Practitioner and continues with Keycloak.
#
# MUST run from the bastion (prod KC + HAPI are on private endpoints).
#
# Dry-run by default. Pass --apply to write.
#
# Usage:
#   scripts/delete-user.sh --env production --tenant site-e --user testtsd
#   scripts/delete-user.sh --env production --tenant site-e --user testtsd --apply

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/keycloak.sh
source "$SCRIPT_DIR/lib/keycloak.sh"
# shellcheck source=lib/fhir.sh
source "$SCRIPT_DIR/lib/fhir.sh"

ENV=""
TENANT=""
BASE_URL=""
USER_NAME=""
APPLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env)     ENV="$2"; shift 2 ;;
    --tenant)  TENANT="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --user)    USER_NAME="$2"; shift 2 ;;
    --apply)   APPLY=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) log_err "unknown arg: $1"; exit 2 ;;
  esac
done

[ -n "$ENV" ] && [ -n "$TENANT" ] && [ -n "$USER_NAME" ] \
  || { log_err "--env, --tenant, and --user are required"; exit 2; }
require_cmd jq gcloud curl
validate_env "$ENV"
validate_tenant "$TENANT"

BASE="$(resolve_base_url "$ENV" "$BASE_URL")"
FHIR_BASE="https://${BASE}/fhir"
PARTITION="${FHIR_BASE}/${TENANT}"
SHORT="$(env_short "$ENV")"

sa_token_for() {
  local realm="$1" secret
  secret="$(get_secret "aa-${SHORT}-${realm}-api-client-secret")" \
    || { log_err "missing Secret Manager entry aa-${SHORT}-${realm}-api-client-secret"; return 1; }
  kc_sa_token "$BASE" "$realm" "api-client" "$secret"
}

fhir_search() {
  local token="$1" path="$2"
  _curl -fsS -H "Authorization: Bearer $token" \
    -H 'Accept: application/fhir+json' \
    "${PARTITION}/${path}"
}

collect_ids() {
  jq -r '.entry[]?.resource | select(.id != null) | .id' 2>/dev/null | awk 'NF && !seen[$0]++'
}

ATOKEN="$(kc_admin_token "$ENV" "$BASE")"
SUB="$(kc_get_user_id_by_username "$ATOKEN" "$BASE" "$TENANT" "$USER_NAME")"

TTOKEN="$(sa_token_for "$TENANT")"

ROLE_IDS=()
GROUP_IDS=()
PRACT_IDS=()

add_unique() {
  local -n arr=$1
  local val="$2"
  [ -n "$val" ] || return 0
  local x
  for x in "${arr[@]+"${arr[@]}"}"; do
    [ "$x" = "$val" ] && return 0
  done
  arr+=("$val")
}

if [ -n "$SUB" ]; then
  log_info "Keycloak user '$USER_NAME' in realm '$TENANT' id=$SUB"
  while IFS= read -r id; do add_unique ROLE_IDS "$id"; done < <(
    fhir_search "$TTOKEN" "PractitionerRole?identifier=${SUB}&_count=200" | collect_ids
  )
  while IFS= read -r id; do add_unique PRACT_IDS "$id"; done < <(
    fhir_search "$TTOKEN" "Practitioner?identifier=${SUB}&_count=50" | collect_ids
  )
  while IFS= read -r id; do add_unique GROUP_IDS "$id"; done < <(
    fhir_search "$TTOKEN" "Group?identifier=${SUB}&_count=50" | collect_ids
  )
else
  log_warn "no Keycloak user named '$USER_NAME' in realm '$TENANT'"
fi

# Official identifier on Practitioner is often the username (dashboard create).
ENC_USER="$(jq -nr --arg u "$USER_NAME" '$u|@uri')"
while IFS= read -r id; do add_unique PRACT_IDS "$id"; done < <(
  fhir_search "$TTOKEN" "Practitioner?identifier=${ENC_USER}&_count=50" | collect_ids
)
while IFS= read -r id; do add_unique ROLE_IDS "$id"; done < <(
  fhir_search "$TTOKEN" "PractitionerRole?identifier=${ENC_USER}&_count=200" | collect_ids
)

for pid in "${PRACT_IDS[@]+"${PRACT_IDS[@]}"}"; do
  while IFS= read -r id; do add_unique ROLE_IDS "$id"; done < <(
    fhir_search "$TTOKEN" "PractitionerRole?practitioner=${pid}&_count=200" | collect_ids
  )
  while IFS= read -r id; do add_unique GROUP_IDS "$id"; done < <(
    fhir_search "$TTOKEN" "Group?member=Practitioner/${pid}&_count=50" | collect_ids
  )
done

cat >&2 <<EOF
[PLAN] delete user '$USER_NAME' from tenant '$TENANT' ($ENV)
  keycloak        : ${SUB:-"(none)"}
  Practitioner    : ${PRACT_IDS[*]:-(none)}
  PractitionerRole: ${ROLE_IDS[*]:-(none)}
  Group           : ${GROUP_IDS[*]:-(none)}
EOF

if [ "$APPLY" -ne 1 ]; then
  log_info "dry-run only; re-run with --apply to delete"
  exit 0
fi

if [ -z "${ROLE_IDS[*]:-}" ] && [ -z "${GROUP_IDS[*]:-}" ] && [ -z "${PRACT_IDS[*]:-}" ] && [ -z "$SUB" ]; then
  log_err "nothing to delete"
  exit 1
fi

for id in "${ROLE_IDS[@]+"${ROLE_IDS[@]}"}"; do
  log_info "DELETE PractitionerRole/$id"
  if ! fhir_delete_resource "$TTOKEN" "$PARTITION" "PractitionerRole" "$id"; then
    log_warn "PractitionerRole/$id still referenced. Left in FHIR; remaining deletes will still run."
  fi
done

for id in "${GROUP_IDS[@]+"${GROUP_IDS[@]}"}"; do
  log_info "DELETE Group/$id"
  if ! fhir_delete_resource "$TTOKEN" "$PARTITION" "Group" "$id"; then
    log_warn "Group/$id still referenced. Left in FHIR; remaining deletes will still run."
  fi
done

for id in "${PRACT_IDS[@]+"${PRACT_IDS[@]}"}"; do
  log_info "DELETE Practitioner/$id"
  if ! fhir_delete_resource "$TTOKEN" "$PARTITION" "Practitioner" "$id"; then
    log_warn "Practitioner/$id still referenced (Tasks/Encounters?). Left in FHIR; Keycloak delete will still run."
  fi
done

if [ -n "$SUB" ]; then
  log_info "DELETE Keycloak user $SUB ($USER_NAME) in realm '$TENANT'"
  kc_delete_user "$ATOKEN" "$BASE" "$TENANT" "$SUB"
fi

log_info "done"
