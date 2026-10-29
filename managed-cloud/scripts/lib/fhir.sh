# shellcheck shell=bash
# fhir.sh — HAPI FHIR REST helpers (partition management + resource I/O).
# Auth: HAPI partition-management endpoints work without auth in the default config;
# we still send a master-realm bearer token defensively. If a deployment rejects it,
# callers can pass an empty token and curl will simply omit the header.
# Source after lib/common.sh.

set -euo pipefail

_auth_header() {
  local token="${1:-}"
  if [ -n "$token" ]; then
    echo "Authorization: Bearer $token"
  else
    echo ""
  fi
}

# fhir_list_partitions <token> <fhir-base-url> → JSON array of {id,name}.
fhir_list_partitions() {
  local token="$1" base="$2"
  local hdr
  hdr=$(_auth_header "$token")
  _curl -fsS \
    ${hdr:+-H "$hdr"} \
    -H "Accept: application/fhir+json" \
    "${base}/\$partition-management-list-partitions" \
    | jq '[.parameter // [] | .[] | {
        id:   ((.part // []) | map(select(.name=="id"))   | .[0].valueInteger),
        name: ((.part // []) | map(select(.name=="name")) | .[0].valueCode)
      }]'
}

# fhir_get_partition_id_by_name <token> <base> <name>  → echoes integer id, or empty.
fhir_get_partition_id_by_name() {
  local token="$1" base="$2" name="$3"
  fhir_list_partitions "$token" "$base" \
    | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' \
    | head -n1
}

# fhir_next_partition_id <token> <base> → echoes next free integer id starting at 1.
fhir_next_partition_id() {
  local token="$1" base="$2"
  fhir_list_partitions "$token" "$base" \
    | jq -r '([.[].id // 0] | max // 0) + 1'
}

# fhir_create_partition <token> <base> <name>  → echoes assigned integer id.
fhir_create_partition() {
  local token="$1" base="$2" name="$3"
  local existing
  existing=$(fhir_get_partition_id_by_name "$token" "$base" "$name")
  if [ -n "$existing" ]; then
    echo "$existing"
    return 0
  fi
  local next
  next=$(fhir_next_partition_id "$token" "$base")
  local body
  body=$(jq -n --argjson id "$next" --arg n "$name" '{
    resourceType: "Parameters",
    parameter: [
      { name:"id",   valueInteger:$id },
      { name:"name", valueCode:$n }
    ]
  }')
  local hdr
  hdr=$(_auth_header "$token")
  _curl -fsS -X POST \
    ${hdr:+-H "$hdr"} \
    -H "Content-Type: application/fhir+json" \
    -H "Accept: application/fhir+json" \
    -d "$body" \
    "${base}/\$partition-management-create-partition" >/dev/null
  fhir_get_partition_id_by_name "$token" "$base" "$name"
}

# fhir_count <token> <base> <resourceType>  → echoes integer count.
fhir_count() {
  local token="$1" base="$2" rt="$3"
  local hdr
  hdr=$(_auth_header "$token")
  _curl -fsS \
    ${hdr:+-H "$hdr"} \
    -H "Accept: application/fhir+json" \
    "${base}/${rt}?_summary=count" \
    | jq -r '.total // 0'
}

# fhir_get_resource <token> <base> <resourceType> <id>
# Reads one resource by id and echoes its JSON on stdout. Returns 1 (quietly —
# a 404 is a normal answer for callers checking existence) on any non-2xx.
fhir_get_resource() {
  local token="$1" base="$2" rt="$3" id="$4"
  local hdr
  hdr=$(_auth_header "$token")
  _curl -fsS \
    ${hdr:+-H "$hdr"} \
    -H "Accept: application/fhir+json" \
    "${base}/${rt}/${id}"
}

# fhir_post_resource <token> <base> <resourceType> <resource-json>
# Treats 200/201 as success. 409 / "already exists" → success (idempotent).
# On failure echoes the response body to stderr and returns 1.
fhir_post_resource() {
  local token="$1" base="$2" rt="$3" body="$4"
  local hdr
  hdr=$(_auth_header "$token")
  local tmp
  tmp=$(mktemp)
  local code
  code=$(_curl -sS -o "$tmp" -w '%{http_code}' -X POST \
    ${hdr:+-H "$hdr"} \
    -H "Content-Type: application/fhir+json" \
    -H "Accept: application/fhir+json" \
    -d "$body" \
    "${base}/${rt}")
  case "$code" in
    200|201)
      rm -f "$tmp"
      return 0
      ;;
    409)
      log_warn "duplicate ${rt} (HTTP 409); treating as success"
      rm -f "$tmp"
      return 0
      ;;
    *)
      if grep -qi 'already exists' "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 0
      fi
      cat "$tmp" >&2
      rm -f "$tmp"
      return 1
      ;;
  esac
}

# fhir_delete_resource <token> <base> <resourceType> <id>
# 200/204 → deleted. 404 → already gone (idempotent success). Anything else
# streams the body to stderr and returns 1 (HAPI 409 when other resources still
# reference this id).
fhir_delete_resource() {
  local token="$1" base="$2" rt="$3" id="$4"
  local hdr
  hdr=$(_auth_header "$token")
  local tmp
  tmp=$(mktemp)
  local code
  code=$(_curl -sS -o "$tmp" -w '%{http_code}' -X DELETE \
    ${hdr:+-H "$hdr"} \
    -H "Accept: application/fhir+json" \
    "${base}/${rt}/${id}")
  case "$code" in
    200|204|404)
      rm -f "$tmp"
      return 0
      ;;
    *)
      cat "$tmp" >&2
      rm -f "$tmp"
      return 1
      ;;
  esac
}

# fhir_put_resource <token> <base> <resourceType> <id> <body>  — same idempotence semantics.
fhir_put_resource() {
  local token="$1" base="$2" rt="$3" id="$4" body="$5"
  local hdr
  hdr=$(_auth_header "$token")
  local tmp
  tmp=$(mktemp)
  local code
  code=$(_curl -sS -o "$tmp" -w '%{http_code}' -X PUT \
    ${hdr:+-H "$hdr"} \
    -H "Content-Type: application/fhir+json" \
    -H "Accept: application/fhir+json" \
    -d "$body" \
    "${base}/${rt}/${id}")
  case "$code" in
    200|201)
      rm -f "$tmp"
      return 0
      ;;
    *)
      cat "$tmp" >&2
      rm -f "$tmp"
      return 1
      ;;
  esac
}

# fhir_patch_resource <token> <base> <resourceType> <id> <json-patch-array>
# Applies an RFC 6902 JSON Patch to one resource. Used instead of PUT wherever
# only a field or two changes: a PUT would have to carry the whole resource, and
# a body fetched with _elements comes back SUBSETTED — PUTting that back deletes
# every field the search did not ask for. On non-2xx, streams the
# OperationOutcome to stderr and returns 1.
fhir_patch_resource() {
  local token="$1" base="$2" rt="$3" id="$4" patch="$5"
  local hdr
  hdr=$(_auth_header "$token")
  local tmp
  tmp=$(mktemp)
  local code
  code=$(_curl -sS -o "$tmp" -w '%{http_code}' -X PATCH \
    ${hdr:+-H "$hdr"} \
    -H "Content-Type: application/json-patch+json" \
    -H "Accept: application/fhir+json" \
    -d "$patch" \
    "${base}/${rt}/${id}")
  case "$code" in
    200|201)
      rm -f "$tmp"
      return 0
      ;;
    *)
      cat "$tmp" >&2
      rm -f "$tmp"
      return 1
      ;;
  esac
}

# fhir_evaluate_measure <token> <tenant-base> <measure-id> <period-start> <period-end> [report-type]
# GETs Measure/<id>/$evaluate-measure and echoes the MeasureReport JSON on stdout.
# <tenant-base> is the tenant-scoped FHIR URL (https://host/fhir/<tenant>); the
# operation evaluates the measure against that partition's data. report-type
# defaults to "summary". Requires the caller's JWT to carry the FHIR_OP_EVALUATE_MEASURE
# realm role. On non-2xx, streams the OperationOutcome to stderr and returns 1.
fhir_evaluate_measure() {
  local token="$1" base="$2" id="$3" period_start="$4" period_end="$5" report_type="${6:-summary}"
  local hdr
  hdr=$(_auth_header "$token")
  local tmp
  tmp=$(mktemp)
  local code
  code=$(_curl -sS -o "$tmp" -w '%{http_code}' -G \
    ${hdr:+-H "$hdr"} \
    -H "Accept: application/fhir+json" \
    --data-urlencode "periodStart=${period_start}" \
    --data-urlencode "periodEnd=${period_end}" \
    --data-urlencode "reportType=${report_type}" \
    "${base}/Measure/${id}/\$evaluate-measure")
  if [ "$code" = "200" ]; then
    cat "$tmp"
    rm -f "$tmp"
    return 0
  fi
  cat "$tmp" >&2
  rm -f "$tmp"
  return 1
}

# fhir_post_bundle <token> <partition-base> <bundle-path>
# POSTs a FHIR transaction Bundle to the partition root. <partition-base> is the
# tenant-scoped FHIR URL (e.g. https://host/fhir/<tenant>); inner relative URLs
# resolve against it. 200/201 → ok; anything else streams the response to stderr.
fhir_post_bundle() {
  local token="$1" base="$2" bundle="$3"
  [ -f "$bundle" ] || { log_err "fhir_post_bundle: missing bundle $bundle"; return 1; }
  local hdr
  hdr=$(_auth_header "$token")
  local tmp
  tmp=$(mktemp)
  local code
  code=$(_curl -sS -o "$tmp" -w '%{http_code}' -X POST \
    ${hdr:+-H "$hdr"} \
    -H "Content-Type: application/fhir+json" \
    -H "Accept: application/fhir+json" \
    --data-binary @"$bundle" \
    "${base}")
  case "$code" in
    200|201)
      rm -f "$tmp"
      return 0
      ;;
    *)
      cat "$tmp" >&2
      rm -f "$tmp"
      return 1
      ;;
  esac
}
