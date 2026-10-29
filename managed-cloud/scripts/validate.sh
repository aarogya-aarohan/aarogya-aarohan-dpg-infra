#!/usr/bin/env bash
# validate.sh — post-migration sanity check. Compares per-type counts between
# the OLD and NEW systems, samples 100 random resources for content equality
# (HAPI-managed metadata ignored, budget spread evenly across types), verifies
# that intra-partition references resolve in the new partition, and fetches a
# sample of Attachment.urls to prove the images are actually reachable.
# Writes a report; exits 0 only if all pass.
# Usage: --env --tenant --partition-id --source-url <https://old/fhir> [--base-url <host>]

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/keycloak.sh
source "$SCRIPT_DIR/lib/keycloak.sh"
# shellcheck source=lib/fhir.sh
source "$SCRIPT_DIR/lib/fhir.sh"

CHECK_TYPES=(
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
SAMPLE_SIZE=100
# Strip HAPI-managed fields before content comparison.
JQ_NORMALISE='del(.meta.versionId, .meta.lastUpdated, .meta.source, .text, .id)'

show_help() {
  cat <<'EOF' >&2
validate.sh — post-migration validation (counts + sample + integrity + attachments).

Required:
  --env {staging|production}
  --tenant <slug>
  --partition-id <int>
  --source-url <url>     base URL of OLD HAPI (e.g. https://state-a-old.example.com/fhir)

Optional:
  --base-url <host>      override $STAGING_BASE_URL / $PRODUCTION_BASE_URL
  --token <jwt>          bearer token for the OLD source server (--source-url).
                         May also be supplied via the EXPORT_BEARER env var.
                         Needed when the source enforces auth (HAPI-0334).
  --output <dir>         report dir (default ./exports/<tenant>/)
  --since <instant>      lower bound on meta.lastUpdated for source+target counts
  --until <instant>      upper bound (exclusive). When either is set the
                         intra-partition integrity probe is skipped (a partial
                         window will legitimately leave dangling references).
                         The attachment probe still runs — an Attachment.url
                         that does not resolve is broken in any window.
EOF
}

_window_query() {
  local since="$1" until="$2"
  local q=""
  [ -n "$since" ] && q="${q}&_lastUpdated=ge${since}"
  [ -n "$until" ] && q="${q}&_lastUpdated=lt${until}"
  echo "$q"
}

_target_curl() {
  local token="$1"; shift
  _curl -fsS -H "Authorization: Bearer $token" -H "Accept: application/fhir+json" "$@"
}

# id-map.json emitted by migrate-tenant.sh's rewrite step, when the migration
# rescoped collision-prone ids (e.g. Practitioner/flw1 → site-d-flw1). Sampling
# fetches by source id, so it has to be translated before hitting the target or
# every remapped resource reports a spurious "missing on new".
ID_MAP='{}'

# Types the migration deliberately did not import (DROP_TYPES in
# migrate-tenant.sh, recorded in dropped-types.txt). Their target count is
# meant to differ from the source, so comparing them would fail every run.
DROPPED_TYPES=""

_is_dropped() {
  case " $DROPPED_TYPES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# _mapped_id <resourceType> <source-id> → target id (unchanged if not remapped)
_mapped_id() {
  jq -r --arg rt "$1" --arg id "$2" '(.[$rt][$id] // $id)' <<<"$ID_MAP"
}

# Normalise a source-side resource for comparison: apply the same reference
# rescoping the rewrite step applied, so we compare against what the target is
# actually expected to hold rather than against the pre-migration text.
# Both sides also drop their own server prefix from .url, so an Attachment.url
# compares on the part that carries meaning — "DocumentReference/<id>/$binary-access-read?path=…".
# Without this, rewrite re-homing .url onto the target base (migrate-tenant.sh
# cmd_rewrite phase 1) would read as "content differs" on every Media and QR.
_strip_url_prefix() {
  printf 'walk(if type == "object" and (.url | type) == "string" and (.url | startswith("%s")) then .url |= ltrimstr("%s") else . end)' "$1" "$1"
}

_normalise_old() {
  local source="$1"
  jq --argjson m "$ID_MAP" "
    walk(
      if type == \"object\" and (.reference | type == \"string\") then
        (.reference | split(\"/\")) as \$p
        | if (\$p | length) >= 2 and ((\$m[\$p[0]][\$p[1]] // null) != null)
          then .reference = ([\$p[0], \$m[\$p[0]][\$p[1]]] + \$p[2:] | join(\"/\"))
          else . end
      else . end
    ) | $(_strip_url_prefix "${source%/}/") | $JQ_NORMALISE
  "
}

# Normalise a target-side resource: drop the legacy-id identifier the rewrite
# step added for traceability, which has no counterpart on the source.
_normalise_new() {
  local source="$1" rt="$2" target="$3"
  jq --arg sys "${source%/}/${rt}" "
    ( if (.identifier | type) == \"array\"
      then .identifier |= map(select(.system != \$sys))
           | (if (.identifier | length) == 0 then del(.identifier) else . end)
      else . end
    ) | $(_strip_url_prefix "${target%/}/") | $JQ_NORMALISE
  "
}

# Optional bearer auth for the OLD source server. Populated in main() from
# --token / EXPORT_BEARER; empty by default (source requests sent unauthenticated).
SOURCE_AUTH=()

_source_curl() {
  _curl -fsS "${SOURCE_AUTH[@]}" -H "Accept: application/fhir+json" "$@"
}

check_counts() {
  local source="$1" target="$2" token="$3" since="$4" until="$5" report="$6"
  local fail=0
  local window
  window=$(_window_query "$since" "$until")
  printf '\n## counts%s\n' "${window:+ (window: ${since:-*}..${until:-*})}" >>"$report"
  for rt in "${CHECK_TYPES[@]}"; do
    if _is_dropped "$rt"; then
      printf '  SKIP  %-22s not migrated (dropped type)\n' "$rt" | tee -a "$report"
      continue
    fi
    local old_n new_n
    old_n=$(_source_curl "${source}/${rt}?_summary=count${window}" \
      | jq -r '.total // 0' 2>/dev/null || echo "ERR")
    new_n=$(_target_curl "$token" "${target}/${rt}?_summary=count${window}" \
      | jq -r '.total // 0' 2>/dev/null || echo "ERR")
    if [ "$old_n" = "$new_n" ]; then
      printf '  PASS  %-22s old=%s new=%s\n' "$rt" "$old_n" "$new_n" | tee -a "$report"
    else
      printf '  FAIL  %-22s old=%s new=%s\n' "$rt" "$old_n" "$new_n" | tee -a "$report"
      fail=$((fail + 1))
    fi
  done
  return "$fail"
}

check_sample() {
  local source="$1" target="$2" token="$3" since="$4" until="$5" report="$6"
  local window
  window=$(_window_query "$since" "$until")
  printf '\n## sample (%d random resources)\n' "$SAMPLE_SIZE" >>"$report"
  # Budget split evenly across the types we actually check, rather than 10-at-a-time
  # until the budget runs out. The old shape never reached the tail of CHECK_TYPES:
  # 10 per type exhausted SAMPLE_SIZE=100 by the tenth populated type, so
  # QuestionnaireResponse (16th) and Media (18th) were sampled on no run that had
  # ten other populated types — which is how the mangled Attachment.url in
  # internal design notes passed validation on every migrated tenant.
  local checkable=0
  for rt in "${CHECK_TYPES[@]}"; do
    _is_dropped "$rt" || checkable=$((checkable + 1))
  done
  local per_type=$(( checkable > 0 ? SAMPLE_SIZE / checkable : SAMPLE_SIZE ))
  [ "$per_type" -lt 1 ] && per_type=1
  local picked=0 fail=0
  for rt in "${CHECK_TYPES[@]}"; do
    # Sampling a dropped type would report every resource as missing on new.
    _is_dropped "$rt" && continue
    local ids
    ids=$(_source_curl "${source}/${rt}?_count=${per_type}&_elements=id${window}" \
      | jq -r '.entry[]?.resource.id // empty')
    [ -z "$ids" ] && continue
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      picked=$((picked + 1))
      local old_body new_body new_id
      new_id=$(_mapped_id "$rt" "$id")
      old_body=$(_source_curl "${source}/${rt}/${id}" 2>/dev/null || true)
      new_body=$(_target_curl "$token" "${target}/${rt}/${new_id}" 2>/dev/null || true)
      if [ -z "$new_body" ]; then
        printf '  FAIL  %s/%s missing on new%s\n' "$rt" "$id" \
          "$([ "$new_id" != "$id" ] && printf ' (as %s)' "$new_id")" | tee -a "$report"
        fail=$((fail + 1))
        continue
      fi
      local diff
      diff=$(jq -n --argjson a "$(echo "$old_body" | _normalise_old "$source")" \
                    --argjson b "$(echo "$new_body" | _normalise_new "$source" "$rt" "$target")" \
                    '$a == $b')
      if [ "$diff" != "true" ]; then
        printf '  FAIL  %s/%s content differs\n' "$rt" "$id" | tee -a "$report"
        fail=$((fail + 1))
      fi
    done <<<"$ids"
  done
  printf '  sampled=%d failed=%d\n' "$picked" "$fail" >>"$report"
  return "$fail"
}

# The Encounter → image path on migrated data is Attachment.url and nothing else:
# the legacy DocumentReference.context is null, so Media.content.url (and the
# QuestionnaireResponse valueAttachment.url twins) is the only pointer. It is not
# a reference field, so check_integrity never walks it, and every Media row
# existing is enough to make check_counts pass — which is exactly how a migration
# that mangled it shipped unnoticed. Fetch the URLs and insist they resolve.
check_attachments() {
  local target="$1" token="$2" report="$3"
  printf '\n## attachments (Attachment.url resolves on the target)\n' >>"$report"
  local fail=0 checked=0 urls
  urls=$(
    {
      _target_curl "$token" "${target}/Media?_count=25&_elements=content" 2>/dev/null \
        | jq -r '.entry[]?.resource.content.url // empty'
      _target_curl "$token" "${target}/QuestionnaireResponse?_count=10" 2>/dev/null \
        | jq -r '[.. | objects | select(has("valueAttachment")) | .valueAttachment.url? // empty] | .[]'
    } | sort -u | head -25
  )
  if [ -z "$urls" ]; then
    printf '  SKIP  no Media / QuestionnaireResponse attachments found\n' | tee -a "$report"
    printf '  checked=0 failed=0\n' >>"$report"
    return 0
  fi
  local url code
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    checked=$((checked + 1))
    # A relative value is the failure this probe exists for: it names no tenant,
    # so no consumer can re-base it. Report it without issuing a doomed request.
    case "$url" in
      http://*|https://*) ;;
      *) printf '  FAIL  relative attachment url (no tenant): %s\n' "$url" | tee -a "$report"
         fail=$((fail + 1)); continue ;;
    esac
    code=$(_curl -sS -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $token" "$url" 2>/dev/null || echo ERR)
    if [ "$code" != "200" ]; then
      printf '  FAIL  attachment url HTTP %s: %s\n' "$code" "$url" | tee -a "$report"
      fail=$((fail + 1))
    fi
  done <<<"$urls"
  printf '  checked=%d failed=%d\n' "$checked" "$fail" >>"$report"
  return "$fail"
}

check_integrity() {
  local target="$1" token="$2" report="$3"
  printf '\n## integrity (intra-partition reference resolution)\n' >>"$report"
  local fail=0
  local probe_types=(Encounter Observation Condition MedicationRequest Procedure DiagnosticReport ServiceRequest)
  for rt in "${probe_types[@]}"; do
    local refs
    refs=$(_target_curl "$token" "${target}/${rt}?_count=20" \
      | jq -r '.entry[]?.resource | (.subject.reference, .patient.reference, .encounter.reference) | select(.!=null and .!="")' \
      | sort -u)
    [ -z "$refs" ] && continue
    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      local rrt rid
      rrt="${ref%%/*}"
      rid="${ref#*/}"
      if [ -z "$rrt" ] || [ -z "$rid" ] || [ "$rrt" = "$ref" ]; then continue; fi
      local code
      code=$(_curl -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $token" \
        -H "Accept: application/fhir+json" "${target}/${rrt}/${rid}")
      if [ "$code" != "200" ]; then
        printf '  FAIL  unresolved %s referenced from %s (HTTP %s)\n' "$ref" "$rt" "$code" | tee -a "$report"
        fail=$((fail + 1))
      fi
    done <<<"$refs"
  done
  printf '  integrity-failures=%d\n' "$fail" >>"$report"
  return "$fail"
}

main() {
  parse_common_args "$@"
  require_cmd jq curl

  if [ -z "$ENV" ] || [ -z "$TENANT" ] || [ -z "$PARTITION_ID" ] || [ -z "$SOURCE_URL" ]; then
    show_help
    exit 2
  fi
  validate_env "$ENV"
  validate_tenant "$TENANT"

  # Bearer auth for the OLD source server: --token wins, else EXPORT_BEARER env.
  local bearer="${TOKEN_ARG:-${EXPORT_BEARER:-}}"
  if [ -n "$bearer" ]; then
    SOURCE_AUTH=(-H "Authorization: Bearer ${bearer}")
    log_info "using bearer auth for source ($SOURCE_URL)"
  fi

  local base
  base=$(resolve_base_url "$ENV" "$BASE_URL")
  local target_base="https://${base}/fhir/${TENANT}"

  local token
  token=$(kc_fhir_bootstrap_token "$ENV" "$base")

  local out_dir="${OUTPUT_DIR:-./exports/${TENANT}}"
  mkdir -p "$out_dir"
  local report="${out_dir}/validation-report.txt"

  if [ -f "${out_dir}/id-map.json" ]; then
    ID_MAP=$(jq -c . "${out_dir}/id-map.json")
    log_info "loaded id map: $(jq -r '[.[] | length] | add // 0' <<<"$ID_MAP") remapped id(s)"
  fi

  if [ -f "${out_dir}/dropped-types.txt" ]; then
    DROPPED_TYPES=$(tr '\n' ' ' <"${out_dir}/dropped-types.txt")
    [ -n "${DROPPED_TYPES// /}" ] && log_info "not migrated (reported as SKIP): ${DROPPED_TYPES}"
  fi

  {
    echo "validation-report"
    echo "tenant=$TENANT env=$ENV partition_id=$PARTITION_ID"
    echo "source=$SOURCE_URL"
    echo "target=$target_base"
    [ -n "$SINCE$UNTIL" ] && echo "window=since:${SINCE:-*} until:${UNTIL:-*}"
    echo "generated=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  } >"$report"

  local total_fail=0 c_fail=0 s_fail=0 i_fail=0 a_fail=0
  check_counts "$SOURCE_URL" "$target_base" "$token" "$SINCE" "$UNTIL" "$report" || c_fail=$?
  total_fail=$((total_fail + c_fail))
  check_sample "$SOURCE_URL" "$target_base" "$token" "$SINCE" "$UNTIL" "$report" || s_fail=$?
  total_fail=$((total_fail + s_fail))
  if [ -n "$SINCE$UNTIL" ]; then
    printf '\n## integrity (skipped — partial window)\n' >>"$report"
    log_info "integrity check skipped: partial window in effect"
  else
    check_integrity "$target_base" "$token" "$report" || i_fail=$?
    total_fail=$((total_fail + i_fail))
  fi
  # Runs on windowed migrations too, unlike integrity: a dangling *reference* is
  # expected mid-backfill, but an Attachment.url that does not resolve is broken
  # in any window — and skipping it on --since runs is what let state-c through.
  check_attachments "$target_base" "$token" "$report" || a_fail=$?
  total_fail=$((total_fail + a_fail))

  {
    echo
    echo "## summary"
    echo "  count-failures=$c_fail"
    echo "  sample-failures=$s_fail"
    echo "  integrity-failures=$i_fail"
    echo "  attachment-failures=$a_fail"
    echo "  total-failures=$total_fail"
  } >>"$report"

  log_info "report written to $report"
  if [ "$total_fail" -gt 0 ]; then
    log_err "validation failed: $total_fail issues"
    exit 1
  fi
  log_info "validation passed"
}

main "$@"
