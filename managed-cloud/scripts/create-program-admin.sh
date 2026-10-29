#!/usr/bin/env bash
# create-program-admin.sh — provision a human "program-admin" that can log into
# the arogyam dashboard for a tenant.
#
# The dashboard resolves a user's userType by looking up
#   PractitionerRole?identifier=<keycloak-sub>
# and reading the role coding (code `program-admin` in CodeSystem
# practitioner-role-type). A missing PractitionerRole falls back to `flw`.
# Standard onboarding does NOT create any of this for a human admin, so this
# script does three things:
#   1. creates an enabled Keycloak user in the tenant realm and puts it in a
#      permission group (default "Site Coordinator" — FHIR read/write + realm-admin);
#   2. mirrors an existing program-admin PractitionerRole from a reference tenant
#      (default `state-a`) to get the exact FHIR shape the dashboard expects;
#   3. PUTs a fresh Practitioner + PractitionerRole into the tenant partition,
#      re-pointed at the new user's Keycloak sub.
#
# MUST run from the bastion (prod KC + HAPI are on private endpoints).
#
# Usage:
#   scripts/create-program-admin.sh --env production --tenant state-b --inspect
#   scripts/create-program-admin.sh --env production --tenant state-b \
#       [--user programadmin] [--password password] [--name "Program Admin"] \
#       [--group "Site Coordinator"] [--mirror-tenant state-a]
#
# --inspect only fetches and prints the reference tenant's program-admin
# Practitioner/PractitionerRole and exits — run it first and eyeball the shape
# before letting the apply path write to production.

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
USER_NAME="programadmin"
PASSWORD="password"
DISPLAY_NAME="Program Admin"
GROUP="Site Coordinator"
MIRROR_TENANT="state-a"
INSPECT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env)           ENV="$2"; shift 2 ;;
    --tenant)        TENANT="$2"; shift 2 ;;
    --base-url)      BASE_URL="$2"; shift 2 ;;
    --user)          USER_NAME="$2"; shift 2 ;;
    --password)      PASSWORD="$2"; shift 2 ;;
    --name)          DISPLAY_NAME="$2"; shift 2 ;;
    --group)         GROUP="$2"; shift 2 ;;
    --mirror-tenant) MIRROR_TENANT="$2"; shift 2 ;;
    --inspect)       INSPECT=1; shift ;;
    -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) log_err "unknown arg: $1"; exit 2 ;;
  esac
done

[ -n "$ENV" ] && [ -n "$TENANT" ] || { log_err "--env and --tenant are required"; exit 2; }
require_cmd jq gcloud curl uuidgen
validate_env "$ENV"

BASE="$(resolve_base_url "$ENV" "$BASE_URL")"
FHIR_BASE="https://${BASE}/fhir"
SHORT="$(env_short "$ENV")"

# Both reads and writes use per-tenant api-client SA tokens: they carry the
# partition_id claim the gateway's JwtPartitionValidationInterceptor demands and
# the FHIR_ALL_READ/WRITE roles HAPI authz requires. (The fhir-bootstrap system
# token is deliberately avoided here — it is partition-scoped in this realm and
# cannot address an arbitrary tenant partition.)
sa_token_for() {
  local realm="$1" secret
  secret="$(get_secret "aa-${SHORT}-${realm}-api-client-secret")" \
    || { log_err "missing Secret Manager entry aa-${SHORT}-${realm}-api-client-secret"; return 1; }
  kc_sa_token "$BASE" "$realm" "api-client" "$secret"
}

MTOKEN="$(sa_token_for "$MIRROR_TENANT")"

# Pull one program-admin PractitionerRole (and its Practitioner) from the
# reference tenant, so the created resources match whatever shape the dashboard
# actually reads. Filtered client-side on the coding to avoid guessing SP names.
fetch_mirror_role() {
  _curl -fsS -H "Authorization: Bearer $MTOKEN" \
    -H 'Accept: application/fhir+json' \
    "${FHIR_BASE}/${MIRROR_TENANT}/PractitionerRole?_count=200" \
  | jq -c '[.entry[]?.resource
            | select(.code[]?.coding[]?.code == "program-admin")][0] // empty'
}

fetch_practitioner() {
  local ref="$1"   # e.g. Practitioner/abc
  [ -n "$ref" ] || return 0
  _curl -fsS -H "Authorization: Bearer $MTOKEN" \
    -H 'Accept: application/fhir+json' \
    "${FHIR_BASE}/${MIRROR_TENANT}/${ref}" | jq -c '.'
}

MIRROR_ROLE="$(fetch_mirror_role)"
if [ -z "$MIRROR_ROLE" ]; then
  log_err "no program-admin PractitionerRole found in reference tenant '$MIRROR_TENANT' — pick another with --mirror-tenant"
  exit 1
fi
MIRROR_PRACT_REF="$(jq -r '.practitioner.reference // empty' <<<"$MIRROR_ROLE")"
MIRROR_PRACT="$(fetch_practitioner "$MIRROR_PRACT_REF")"

if [ "$INSPECT" -eq 1 ]; then
  echo "===== reference PractitionerRole (${MIRROR_TENANT}) ====="
  jq . <<<"$MIRROR_ROLE"
  echo "===== reference Practitioner (${MIRROR_TENANT}) ====="
  jq . <<<"${MIRROR_PRACT:-null}"
  exit 0
fi

# ---- 1. Keycloak user in the tenant realm --------------------------------
ATOKEN="$(kc_admin_token "$ENV" "$BASE")"

SUB="$(kc_get_user_id_by_username "$ATOKEN" "$BASE" "$TENANT" "$USER_NAME")"
if [ -n "$SUB" ]; then
  log_info "user '$USER_NAME' already exists in realm '$TENANT' (id=$SUB); leaving password untouched"
else
  log_info "creating user '$USER_NAME' in realm '$TENANT'"
  SUB="$(kc_create_user "$ATOKEN" "$BASE" "$TENANT" "$USER_NAME" "$PASSWORD")"
  [ -n "$SUB" ] || { log_err "failed to create user"; exit 1; }
fi

GID="$(kc_get_group_id_by_name "$ATOKEN" "$BASE" "$TENANT" "$GROUP")"
[ -n "$GID" ] || { log_err "group '$GROUP' not found in realm '$TENANT'"; exit 1; }
kc_add_user_to_group "$ATOKEN" "$BASE" "$TENANT" "$SUB" "$GID"
log_info "user '$USER_NAME' (sub=$SUB) added to group '$GROUP'"

# ---- 2. FHIR resources in the tenant partition ---------------------------
PRACT_ID="$(uuidgen | tr 'A-Z' 'a-z')"
ROLE_ID="$(uuidgen | tr 'A-Z' 'a-z')"

# The dashboard links FHIR→Keycloak through a *secondary* identifier of type
# KUID (http://hl7.org/fhir/identifier-type, code "KUID") whose value is the
# Keycloak sub; the primary `official` identifier just mirrors the resource id.
# So clone the state-a exemplars verbatim and only re-map: the two ids, the KUID
# identifier value (→ new sub), the official identifier value (→ new id), and
# name/practitioner-ref. A KUID identifier is appended if the exemplar lacked one.
KUID_TYPE='{"coding":[{"system":"http://hl7.org/fhir/identifier-type","code":"KUID","display":"Keycloak user ID"}],"text":"Keycloak user ID"}'

# Practitioner: mirror structure, swap id/identifiers/name, drop the exemplar's
# personal telecom (belongs to the state-a admin).
PRACT_BODY="$(jq -c \
  --arg id "$PRACT_ID" --arg sub "$SUB" --arg name "$DISPLAY_NAME" \
  --argjson kuidtype "$KUID_TYPE" '
  (. // {resourceType:"Practitioner", identifier:[]})
  | del(.meta,.text,.telecom)
  | .resourceType = "Practitioner"
  | .id = $id
  | .active = true
  | .identifier = ((.identifier // []) | map(
      if (.type.coding[]?.code == "KUID") then .value = $sub
      elif (.use == "official") then .value = $id
      else . end))
  | (if any(.identifier[]?; .type.coding[]?.code == "KUID") then .
     else .identifier += [{use:"secondary", type:$kuidtype, value:$sub}] end)
  | .name = [{use:"official", text:$name}]
' <<<"${MIRROR_PRACT:-null}")"

# PractitionerRole: clone the exemplar (keeps the exact program-admin coding the
# dashboard matches on), re-map ids + identifiers + practitioner ref, and drop the
# reference tenant's org/location/healthcareService (those ids don't exist in this
# partition and would dangle).
ROLE_BODY="$(jq -c \
  --arg id "$ROLE_ID" --arg sub "$SUB" --arg practid "$PRACT_ID" --arg name "$DISPLAY_NAME" \
  --argjson kuidtype "$KUID_TYPE" '
  del(.meta,.text,.organization,.location,.healthcareService)
  | .resourceType = "PractitionerRole"
  | .id = $id
  | .active = true
  | .identifier = ((.identifier // []) | map(
      if (.type.coding[]?.code == "KUID") then .value = $sub
      elif (.use == "official") then .value = $id
      else . end))
  | (if any(.identifier[]?; .type.coding[]?.code == "KUID") then .
     else .identifier += [{use:"secondary", type:$kuidtype, value:$sub}] end)
  | .practitioner = {reference: ("Practitioner/" + $practid), display: $name}
' <<<"$MIRROR_ROLE")"

TTOKEN="$(sa_token_for "$TENANT")"
log_info "PUT Practitioner/$PRACT_ID into partition '$TENANT'"
fhir_put_resource "$TTOKEN" "${FHIR_BASE}/${TENANT}" "Practitioner" "$PRACT_ID" "$PRACT_BODY"

log_info "PUT PractitionerRole/$ROLE_ID into partition '$TENANT'"
fhir_put_resource "$TTOKEN" "${FHIR_BASE}/${TENANT}" "PractitionerRole" "$ROLE_ID" "$ROLE_BODY"

# ---- 3. Acceptance check: the exact lookup the dashboard performs ---------
log_info "verifying PractitionerRole?identifier=$SUB resolves in partition '$TENANT'"
FOUND="$(_curl -fsS -H "Authorization: Bearer $TTOKEN" -H 'Accept: application/fhir+json' \
  "${FHIR_BASE}/${TENANT}/PractitionerRole?identifier=${SUB}" \
  | jq -r '[.entry[]?.resource | select(.code[]?.coding[]?.code=="program-admin")] | length')"
if [ "${FOUND:-0}" -ge 1 ]; then
  log_info "verify: dashboard lookup returns a program-admin PractitionerRole for this user"
else
  log_err "verify: no program-admin PractitionerRole found for identifier=$SUB — dashboard would fall back to flw"
fi

cat >&2 <<EOF

[DONE] program-admin provisioned in '$TENANT' ($ENV)
  keycloak user   : $USER_NAME  (sub=$SUB, group='$GROUP')
  password        : $PASSWORD   <-- TEMPORARY; rotate via admin console
  Practitioner    : Practitioner/$PRACT_ID
  PractitionerRole: PractitionerRole/$ROLE_ID  (identifier=$SUB, code=program-admin)
EOF
