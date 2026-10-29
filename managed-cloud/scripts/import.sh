#!/usr/bin/env bash
# import.sh — imports a directory of NDJSON exports into a HAPI partition on the
# new system. Tries HAPI's bulk $import first; falls back to per-resource POSTs
# in dependency order if $import is unavailable. Failed resources are bucketed
# under <input>/failed/<type>.ndjson.
# Usage: --env --partition-id <int> --input <dir> [--base-url <host>]

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/keycloak.sh
source "$SCRIPT_DIR/lib/keycloak.sh"
# shellcheck source=lib/fhir.sh
source "$SCRIPT_DIR/lib/fhir.sh"

# Set by import_one_type to the per-type failure count (read by main).
LAST_IMPORT_FAILED=0

ORDERED_TYPES=(
  Organization
  Practitioner
  PractitionerRole
  Location
  Patient
  Group
  Encounter
  Condition
  Observation
  MedicationRequest
  Procedure
  DiagnosticReport
  ServiceRequest
  ClinicalImpression
  RiskAssessment
  QuestionnaireResponse
  DocumentReference
  Media
  Task
  Basic
)

show_help() {
  cat <<'EOF' >&2
import.sh — import NDJSON exports into a HAPI partition.

Required:
  --env {staging|production}
  --partition-id <int>      target partition id on the new system
  --input <dir>             directory containing <ResourceType>.ndjson files

Optional:
  --base-url <host>         override $STAGING_BASE_URL / $PRODUCTION_BASE_URL
  --parallelism <int>       concurrent POSTs per resource type (default 8;
                            also via $IMPORT_PARALLELISM)

Environment:
  CURL_CONNECT_TO           tunnel all requests for the public host through a
                            local port-forward while keeping URLs, TLS SNI and
                            Host intact (skips the NAT/LB hairpin). Covers both
                            HAPI and Keycloak since ingress-nginx routes both:
                              kubectl -n ingress-nginx port-forward \
                                svc/ingress-nginx-controller 8443:443 &
                              CURL_CONNECT_TO=<public-host>:443:127.0.0.1:8443
  CURL_INSECURE=1           with CURL_CONNECT_TO only: skip TLS verification.
                            Required with the port-forward above — the real
                            cert terminates at the platform LB, so nginx
                            presents a self-signed one inside the tunnel.

Behaviour:
  Tries HAPI $import; on 404/unsupported falls back to per-type POST loops in
  dependency order, then any remaining types pessimistically. Failed resources
  are written to <input>/failed/<ResourceType>.ndjson; exits non-zero on any
  failure.
EOF
}

# tenant_for_partition <token> <fhir-base> <id>  → echoes name or empty.
tenant_for_partition() {
  local token="$1" base="$2" id="$3"
  fhir_list_partitions "$token" "$base" \
    | jq -r --argjson id "$id" '.[] | select(.id==$id) | .name' | head -n1
}

try_dollar_import() {
  local token="$1" base="$2" tenant="$3" input="$4"
  local found=0
  for f in "$input"/*.ndjson; do
    [ -f "$f" ] && { found=1; break; }
  done
  if [ "$found" -eq 0 ]; then
    log_warn "no NDJSON files found under $input"
    return 1
  fi
  local body
  body=$(jq -n '{
      resourceType: "Parameters",
      parameter: [
        { name:"inputFormat", valueCode:"application/fhir+ndjson" },
        { name:"inputSource", valueUri:"local" }
      ]
    }')
  local hdr
  if [ -n "$token" ]; then hdr="Authorization: Bearer $token"; else hdr=""; fi
  local code
  code=$(_curl -sS -o /dev/null -w '%{http_code}' -X POST \
    ${hdr:+-H "$hdr"} \
    -H "Content-Type: application/fhir+json" \
    -H "Prefer: respond-async" \
    -d "$body" \
    "${base}/${tenant}/\$import")
  case "$code" in
    202|200) return 0 ;;
    404|400|405|501) return 1 ;;
    *) log_warn "\$import returned HTTP $code; falling back to per-resource POST"; return 1 ;;
  esac
}

# progress_tick <rt> <done> <total>
# In-place single-line progress on a TTY; periodic milestone lines otherwise so
# piped/redirected logs stay readable (every 50 resources or on the last one).
# ok/fail are tallied at end-of-type (cheap live counts aren't available once the
# per-resource POSTs run concurrently), so progress shows completion only.
progress_tick() {
  local rt="$1" done="$2" total="$3"
  if [ -t 2 ]; then
    printf '\r[INFO]  %s %-22s %d/%d' "$(_ts)" "$rt" "$done" "$total" >&2
  elif [ $((done % 50)) -eq 0 ] || [ "$done" -eq "$total" ]; then
    log_info "$rt progress: $done/$total"
  fi
}

# import_one_resource <token> <tenant_base> <rt> <line> <slot>
# Worker run as a background job. On failure writes the resource line to
# <slot>.fail and a one-line error note to <slot>.err; success leaves no files.
# Always exits 0 so a failing PUT/POST can't trip the parent's `wait -n` under set -e.
import_one_resource() {
  local token="$1" tenant_base="$2" rt="$3" line="$4" slot="$5"
  local id err
  id=$(printf '%s' "$line" | jq -r '.id // empty')
  err=$(mktemp)
  if [ -n "$id" ]; then
    if fhir_put_resource "$token" "$tenant_base" "$rt" "$id" "$line" 2>"$err"; then
      rm -f "$err"; return 0
    fi
    printf '%s/%s failed: %s\n' "$rt" "$id" "$(cat "$err")" >"$slot.err"
  else
    if fhir_post_resource "$token" "$tenant_base" "$rt" "$line" 2>"$err"; then
      rm -f "$err"; return 0
    fi
    printf '%s (no id) failed: %s\n' "$rt" "$(cat "$err")" >"$slot.err"
  fi
  printf '%s\n' "$line" >"$slot.fail"
  rm -f "$err"
  return 0
}

import_one_type() {
  local base="$1" tenant_base="$2" failed_dir="$3" rt="$4" file="$5"
  local total ok fail done=0 idx=0 running=0 line token
  total=$(wc -l <"$file" | tr -d ' ')
  log_info "importing $rt ($total resources, parallelism=$PARALLELISM) from $(basename "$file")"
  local workdir
  workdir=$(mktemp -d)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    idx=$((idx + 1))
    # Mint only in the parent (kc_fhir_bootstrap_token is a cached file read most
    # of the time, a fresh mint every ~50min) and hand the token to the worker —
    # keeps token-cache writes single-threaded across the concurrent POSTs.
    token=$(kc_fhir_bootstrap_token "$ENV" "$base")
    import_one_resource "$token" "$tenant_base" "$rt" "$line" "$workdir/$idx" &
    running=$((running + 1))
    if [ "$running" -ge "$PARALLELISM" ]; then
      wait -n 2>/dev/null || true
      running=$((running - 1)); done=$((done + 1))
      progress_tick "$rt" "$done" "$total"
    fi
  done <"$file"
  # Drain the remaining in-flight workers.
  while [ "$running" -gt 0 ]; do
    wait -n 2>/dev/null || true
    running=$((running - 1)); done=$((done + 1))
    progress_tick "$rt" "$done" "$total"
  done
  # Terminate the in-place progress line so the summary lands on its own row.
  [ -t 2 ] && printf '\n' >&2

  fail=$(find "$workdir" -name '*.fail' -type f | wc -l | tr -d ' ')
  ok=$((idx - fail))
  if [ "$fail" -gt 0 ]; then
    cat "$workdir"/*.err >&2 2>/dev/null || true
    cat "$workdir"/*.fail >"$failed_dir/${rt}.ndjson" 2>/dev/null || true
  fi
  rm -rf "$workdir"
  log_info "$rt: ok=$ok failed=$fail"
  # Publish via a global rather than the exit code: an 8-bit return wraps mod 256,
  # so a type with e.g. exactly 256 failures would otherwise report as success.
  LAST_IMPORT_FAILED="$fail"
}

main() {
  parse_common_args "$@"
  require_cmd jq curl

  if [ -z "$ENV" ] || [ -z "$PARTITION_ID" ] || [ -z "$INPUT_DIR" ]; then
    show_help
    exit 2
  fi
  validate_env "$ENV"
  if ! [[ "$PARTITION_ID" =~ ^[0-9]+$ ]]; then
    log_err "--partition-id must be an integer"
    exit 2
  fi
  if ! [[ "$PARALLELISM" =~ ^[0-9]+$ ]] || [ "$PARALLELISM" -lt 1 ]; then
    log_err "--parallelism must be a positive integer"
    exit 2
  fi
  if [ ! -d "$INPUT_DIR" ]; then
    log_err "--input dir not found: $INPUT_DIR"
    exit 2
  fi

  local base fhir_base
  base=$(resolve_base_url "$ENV" "$BASE_URL")
  fhir_base="https://${base}/fhir"

  local token tenant tenant_base failed_dir
  token=$(kc_fhir_bootstrap_token "$ENV" "$base")
  tenant=$(tenant_for_partition "$token" "$fhir_base" "$PARTITION_ID")
  if [ -z "$tenant" ]; then
    log_err "no partition found with id=$PARTITION_ID on $fhir_base"
    exit 1
  fi
  tenant_base="${fhir_base}/${tenant}"
  failed_dir="${INPUT_DIR%/}/failed"
  mkdir -p "$failed_dir"

  log_info "target partition: id=$PARTITION_ID name=$tenant base=$tenant_base"

  if try_dollar_import "$token" "$fhir_base" "$tenant" "$INPUT_DIR"; then
    log_info "\$import accepted; HAPI will process asynchronously"
    return 0
  fi

  log_info "falling back to per-type POST loops"
  local total_failed=0 rt file
  declare -A done_types=()

  for rt in "${ORDERED_TYPES[@]}"; do
    file="${INPUT_DIR%/}/${rt}.ndjson"
    if [ -f "$file" ]; then
      import_one_type "$base" "$tenant_base" "$failed_dir" "$rt" "$file"
      total_failed=$((total_failed + LAST_IMPORT_FAILED))
      done_types["$rt"]=1
    fi
  done

  for file in "${INPUT_DIR%/}"/*.ndjson; do
    [ -f "$file" ] || continue
    rt=$(basename "$file" .ndjson)
    if [ -n "${done_types[$rt]:-}" ]; then continue; fi
    log_warn "$rt is not in the dependency-ordered list; importing last (may fail on unresolved references)"
    import_one_type "$base" "$tenant_base" "$failed_dir" "$rt" "$file"
    total_failed=$((total_failed + LAST_IMPORT_FAILED))
  done

  if [ "$total_failed" -gt 0 ]; then
    log_err "$total_failed resources failed; see $failed_dir/*.ndjson"
    exit 1
  fi
  log_info "import complete; no failed resources"
}

main "$@"
