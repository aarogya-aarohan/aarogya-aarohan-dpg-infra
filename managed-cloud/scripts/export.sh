#!/usr/bin/env bash
# export.sh — extracts per-type NDJSON from the OLD single-tenant cluster.
# Tries HAPI's $export first (async polling, downloads manifest outputs);
# automatically falls back to per-type search pagination when the source
# doesn't implement bulk export. Used during a tenant migration window.
# Usage: --tenant <slug> --source-url <https://old/fhir> --output <dir>
#        [--since <instant>]

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Covers all clinically-meaningful resource types observed on the legacy single-
# tenant cluster. Definitional types (Composition, StructureMap, PlanDefinition,
# Library, Questionnaire, SearchParameter, CodeSystem) and Binary are excluded —
# they live in DEFAULT (seeded by scripts/seed-fhir-bundle.sh) or need a separate
# bytes migration (Binary).
DEFAULT_TYPES="Organization,Practitioner,PractitionerRole,Location,Patient,Group,Encounter,Condition,Observation,MedicationRequest,Procedure,DiagnosticReport,ServiceRequest,ClinicalImpression,RiskAssessment,QuestionnaireResponse,DocumentReference,Media,Task,Basic"
MAX_POLL_SECONDS=$((6 * 60 * 60))
# Page size for the search-pagination fallback, and a runaway guard on the page
# loop (500 * 20000 = 10M resources of any one type).
PAGE_SIZE=500
MAX_PAGES=20000

# Source-server auth. Set in main(); one of:
#   minted  EXPORT_TOKEN_URL + EXPORT_CLIENT_ID + EXPORT_CLIENT_SECRET — a
#           client_credentials token re-minted on a TTL for the life of the run
#   static  --token / EXPORT_BEARER — one bearer, never refreshed
#   none    no auth (fine for a source reachable internally via port-forward)
AUTH_MODE=none
AUTH_HEADER=()

# A full export runs far longer than an access token lives. The legacy realms
# set accessTokenLifespan=300, and a 750-page export takes ~50 minutes, so a
# single bearer starts 401ing around page 30 and then burns every curl retry on
# a failure that retrying cannot fix. Re-mint on a TTL well under the lifespan
# instead; client_credentials is cheap. Same reasoning as the sweep in
# scripts/repair-attachment-urls.sh.
TOKEN=""
TOKEN_TS=0
TOKEN_TTL="${TOKEN_TTL:-120}"

_mint_token() {
  local resp tok
  resp=$(_curl -sS --max-time 30 -X POST \
    -d grant_type=client_credentials \
    -d "client_id=${EXPORT_CLIENT_ID}" \
    --data-urlencode "client_secret=${EXPORT_CLIENT_SECRET}" \
    "$EXPORT_TOKEN_URL") || { log_err "token request to $EXPORT_TOKEN_URL failed"; return 1; }
  tok=$(printf '%s' "$resp" | jq -r '.access_token // empty' 2>/dev/null)
  if [ -z "$tok" ]; then
    log_err "no access_token from $EXPORT_TOKEN_URL: $(printf '%s' "$resp" | jq -c '{error,error_description}' 2>/dev/null || printf '%s' "$resp" | head -c 200)"
    return 1
  fi
  printf '%s' "$tok"
}

# Refresh AUTH_HEADER if the current token is older than TOKEN_TTL. A no-op in
# static and none mode, so callers can invoke it before every request.
ensure_token() {
  [ "$AUTH_MODE" = "minted" ] || return 0
  local now
  now=$(date +%s)
  if [ -z "$TOKEN" ] || [ $((now - TOKEN_TS)) -ge "$TOKEN_TTL" ]; then
    TOKEN=$(_mint_token) || return 1
    TOKEN_TS=$now
    AUTH_HEADER=(-H "Authorization: Bearer ${TOKEN}")
  fi
}

# Force a re-mint on the next ensure_token, for the 401-retry path.
expire_token() { TOKEN_TS=0; }

# Types that failed after retries, recorded by whichever path ran. Non-empty at
# the end of main() means the export is incomplete and the run exits non-zero.
FAILURES=()

# Rows the source could not serialize at all (HAPI-1330 and friends): recorded
# one per line in <output>/unreadable.tsv rather than silently dropped. These are
# a fact about the source, not a retryable failure — no amount of re-running
# brings back a binary whose blob is gone.
SKIP_FILE=""
SKIPPED=0
FETCH_STATUS=""
FETCH_DIAG=""

show_help() {
  cat <<'EOF' >&2
export.sh — bulk export FHIR data from a single-tenant HAPI deployment.

Required:
  --tenant <slug>
  --source-url <url>     base URL of old HAPI (e.g. https://state-a-old.example.com/fhir)
  --output <dir>         destination directory (NDJSON files written here)

Optional:
  --since <instant>      FHIR instant (e.g. 2025-01-01T00:00:00Z); passed as _since
                         on the $export kickoff, or as _lastUpdated=ge<instant>
                         on the search fallback. Lower-bound only — upper bounds
                         require a post-export jq filter (see migrate-tenant.sh).
  --start-offset <n>     Resume a paged run at this offset instead of 0, appending
                         to the existing <Type>.ndjson. Use with a single --types
                         after an interrupted run. Only valid while the source's
                         _lastUpdated ordering below <n> is unchanged — new writes
                         sort after it, but a delete would shift every offset.
  --types <csv>          Restrict to these resource types instead of the full
                         default list. Useful for redoing a single type after a
                         failure — other types' files are left as they are.
  --token <jwt>          Static bearer sent on every request to the source server.
                         May also be supplied via the EXPORT_BEARER env var.
                         Not refreshed — see the auth note below.

Source auth (env):
  EXPORT_TOKEN_URL       the realm's token endpoint, e.g.
                         https://<site>/auth/realms/arogyam/protocol/openid-connect/token
  EXPORT_CLIENT_ID       service-account client, e.g. api-client
  EXPORT_CLIENT_SECRET   its secret
  TOKEN_TTL              seconds between re-mints (default 120)

  All three of the first are required together, and they take precedence over
  --token / EXPORT_BEARER.

Notes:
  * Prefer the minted credentials over --token for anything but a smoke test.
    A full export runs ~50 minutes against a realm whose accessTokenLifespan is
    300s, so a static bearer 401s partway and no amount of retrying recovers it;
    minted mode re-mints on a TTL and retries once on a 401. Read the secret
    into the environment without putting it in shell history:
      read -rs EXPORT_CLIENT_SECRET
  * If the source enforces auth (e.g. HAPI's authorization interceptor), the
    credentials need the FHIR_* realm roles. With neither mode configured,
    requests are sent unauthenticated (fine for old single-tenant clusters
    reachable internally, e.g. via kubectl port-forward).
  * Sources without hapi.fhir.bulk_export_enabled reject the $export kickoff with
    a not-supported 400; the run then pages each type through the ordinary search
    API instead. Same <Type>.ndjson output either way, just slower and chattier.
    Bulk export authorizes separately from reads — a source that answers the
    kickoff with 403 has the operation but is denying the token (it needs
    ROLE_SUPER_ADMIN). That is a hard failure, not a fallback: an auth problem
    should be fixed rather than papered over with a slower code path.
EOF
}

# Intersect a comma-separated type list with the source HAPI's CapabilityStatement.
# HAPI rejects the entire $export kickoff with 400 if any _type entry isn't in
# the server's rest.resource list, so we have to filter pessimistically.
filter_supported_types() {
  local source_url="$1" types_csv="$2"
  local supported
  ensure_token || return 1
  supported=$(_curl -fsS --max-time 30 "${AUTH_HEADER[@]}" -H "Accept: application/fhir+json" \
    "${source_url}/metadata" | jq -r '.rest[].resource[].type' | sort -u)
  local kept=() dropped=() t
  for t in ${types_csv//,/ }; do
    if grep -qx "$t" <<<"$supported"; then kept+=("$t"); else dropped+=("$t"); fi
  done
  if [ "${#dropped[@]}" -gt 0 ]; then
    log_warn "dropping unsupported types from _type (not in source CapabilityStatement): ${dropped[*]}"
  fi
  ( IFS=','; echo "${kept[*]}" )
}

# Replace the scheme+host+port of a URL with the canonical origin we know is
# correct. HAPI behind a reverse-proxy that doesn't forward X-Forwarded-Proto
# emits Content-Location / manifest URLs like "https://host:80/..." — https to
# port 80 fails TLS. We trust the source_url the operator passed and rewrite.
_canonicalize_url() {
  local url="$1" source_url="$2"
  local origin path
  origin=$(printf '%s' "$source_url" | sed -E 's|^(https?://[^/]+).*|\1|')
  path=$(printf '%s' "$url" | sed -E 's|^https?://[^/]+||')
  printf '%s%s\n' "$origin" "$path"
}

# Kick off a bulk $export. Prints the polling status URL on stdout.
# Exit: 0 accepted, 3 source doesn't implement $export, 1 anything else.
kick_export() {
  local source_url="$1" types="$2" since="${3:-}"
  local since_param=""
  if [ -n "$since" ]; then
    local encoded
    encoded=$(printf '%s' "$since" | jq -sRr @uri)
    since_param="&_since=${encoded}"
  fi
  ensure_token || return 1
  local headers body code
  headers=$(mktemp)
  body=$(mktemp)
  code=$(_curl -sS -X GET \
    "${AUTH_HEADER[@]}" \
    -H "Accept: application/fhir+json" \
    -H "Prefer: respond-async" \
    -D "$headers" \
    -o "$body" \
    -w '%{http_code}' \
    "${source_url}/\$export?_outputFormat=application/fhir+ndjson&_type=${types}${since_param}")

  # A HAPI started without hapi.fhir.bulk_export_enabled never registers the
  # provider, so the kickoff dies in request routing rather than in the export
  # itself: 400 with a not-supported OperationOutcome. Only that specific shape
  # falls back — a 403 (operation present, token denied) or a 5xx has to stay a
  # hard failure, or a fixable auth problem turns into a silent slow path.
  if [ "$code" = "400" ] || [ "$code" = "404" ] || [ "$code" = "501" ]; then
    if jq -e '[.issue[]?.code] | index("not-supported")' "$body" >/dev/null 2>&1 ||
       grep -qi 'does not know how to handle' "$body"; then
      rm -f "$headers" "$body"
      return 3
    fi
  fi
  if [ "$code" != "202" ] && [ "$code" != "200" ]; then
    log_err "\$export kickoff failed: HTTP $code"
    cat "$body" >&2
    rm -f "$headers" "$body"
    return 1
  fi

  local loc
  loc=$(grep -i '^content-location:' "$headers" | tail -n1 | awk '{print $2}' | tr -d '\r')
  rm -f "$headers" "$body"
  if [ -z "$loc" ]; then
    log_err "no Content-Location header from \$export kickoff"
    return 1
  fi
  _canonicalize_url "$loc" "$source_url"
}

# Fallback for sources without bulk export: page every type through the ordinary
# search API, writing the same <Type>.ndjson layout the manifest path produces so
# filter/import/validate downstream can't tell which path ran. A type maps to
# exactly one file here (unlike a manifest, where one type can span several
# outputs), so each file is written once at the end rather than appended to.
# Fetch one window of a type into $2 (an ndjson temp file). Sets FETCH_N to the
# number of resources appended. Returns 0 on success, 1 on a 400 the server
# cannot serialize, 2 on anything else.
FETCH_N=0
_fetch_window() {
  local url="$1" tmp="$2"
  local body code retried=0
  body=$(mktemp)
  # -f is deliberately absent: we read the status ourselves so a 401 can be
  # answered with a fresh token, and a 400 can be narrowed rather than counted
  # as a lost page. curl still retries the transient 5xx / connection classes.
  while :; do
    if ! ensure_token; then
      rm -f "$body"
      return 2
    fi
    code=$(_curl -sS --retry 8 --retry-delay 0 --retry-max-time 240 --retry-all-errors \
             --connect-timeout 30 --max-time 300 \
             "${AUTH_HEADER[@]}" -H "Accept: application/fhir+json" \
             -o "$body" -w '%{http_code}' "$url") || code=000
    if [ "$code" = "401" ] && [ "$AUTH_MODE" = "minted" ] && [ "$retried" -eq 0 ]; then
      expire_token
      retried=1
      continue
    fi
    break
  done

  if [ "$code" = "200" ]; then
    FETCH_N=$(jq '[.entry[]?.resource] | length' "$body")
    jq -c '.entry[]?.resource' "$body" >>"$tmp"
    rm -f "$body"
    return 0
  fi

  FETCH_STATUS="$code"
  FETCH_DIAG=$(jq -r '[.issue[]?.diagnostics] | join("; ")' "$body" 2>/dev/null | head -c 300)
  rm -f "$body"
  [ "$code" = "400" ] && return 1
  return 2
}

# Walk [start, start+span) in windows of $sub, one level of descent at a time.
# A window that still 400s at size 1 is a single resource the source cannot
# serialize — recorded and skipped, so one bad row costs one row rather than the
# whole page. Sets DESCEND_GOT to the number of resources recovered.
DESCEND_GOT=0
_descend() {
  local base_url="$1" start="$2" span="$3" sub="$4" tmp="$5" t="$6"
  local o=$((start)) end=$((start + span)) got=0 rc
  while [ "$o" -lt "$end" ]; do
    rc=0
    _fetch_window "${base_url}&_count=${sub}&_offset=${o}" "$tmp" || rc=$?
    if [ "$rc" -eq 0 ]; then
      got=$((got + FETCH_N))
      [ "$FETCH_N" -eq 0 ] && break        # ran off the end of the result set
    elif [ "$rc" -eq 1 ] && [ "$sub" -gt 1 ]; then
      _descend "$base_url" "$o" "$sub" 1 "$tmp" "$t" || true
      got=$((got + DESCEND_GOT))
    elif [ "$rc" -eq 1 ]; then
      printf '%s\t%s\t%s\n' "$t" "$o" "${FETCH_DIAG:-unreadable}" >>"$SKIP_FILE"
      SKIPPED=$((SKIPPED + 1))
    else
      log_err "$t: unrecoverable HTTP ${FETCH_STATUS:-000} at offset $o"
      FAILURES+=("${t}[offset ${o}]")
      DESCEND_GOT=$got
      return 1
    fi
    o=$((o + sub))
  done
  DESCEND_GOT=$got
  return 0
}

# Fallback for sources without bulk export: page every type through the ordinary
# search API, writing the same <Type>.ndjson layout the manifest path produces so
# filter/import/validate downstream can't tell which path ran. A type maps to
# exactly one file here (unlike a manifest, where one type can span several
# outputs), so each file is written once at the end rather than appended to.
export_via_search() {
  local source_url="$1" types_csv="$2" since="${3:-}" output_dir="$4"
  local since_param=""
  if [ -n "$since" ]; then
    local encoded
    encoded=$(printf '%s' "ge${since}" | jq -sRr @uri)
    since_param="&_lastUpdated=${encoded}"
  fi

  SKIP_FILE="${output_dir%/}/unreadable.tsv"
  : >"$SKIP_FILE"
  SKIPPED=0

  local t
  for t in ${types_csv//,/ }; do
    local out tmp offset page total finished base rc got covered skipped_before
    out="${output_dir%/}/${t}.ndjson"
    tmp=$(mktemp)
    offset=${START_OFFSET:-0}
    page=0
    # Reset per type BEFORE the resume branch can add to it. `local` inside this
    # loop is the same function scope, not a fresh one, so a value assigned on
    # the previous iteration survives — leaving this to `${total:-0}` made every
    # type report the running sum of all the types before it, and created an
    # empty file for types that had no resources at all.
    total=0
    finished=0
    # Resuming: keep what the interrupted run already wrote, and append. Sound
    # because _sort=_lastUpdated puts new rows at the END of the ordering, so
    # offsets below the resume point do not shift under a source still taking
    # writes. A DELETE on the source would shift them; re-run from 0 if that is
    # a possibility.
    if [ "$offset" -gt 0 ] && [ -f "$out" ]; then
      cat "$out" >>"$tmp"
      total=$(wc -l <"$tmp" | tr -d ' ')
      log_warn "$t: resuming at offset $offset, keeping the $total row(s) already in $(basename "$out")"
    fi
    # _offset (rather than following Bundle.link[next]) puts HAPI in offset mode:
    # each page is its own LIMIT/OFFSET query, so the source never materializes
    # the whole result set into its HFJ_SEARCH_RESULT cache. That cache build is
    # what makes cursor paging crawl — and write-storm the source — on the big
    # types. _offset=0 is explicit on the first page so page 1 skips it too.
    # _sort=_lastUpdated pins the order; without it each page's ORDER BY is
    # unspecified and offset windows can overlap or skip rows outright.
    base="${source_url}/${t}?_sort=_lastUpdated${since_param}"

    while [ "$finished" -eq 0 ]; do
      rc=0
      skipped_before=$SKIPPED
      _fetch_window "${base}&_count=${PAGE_SIZE}&_offset=${offset}" "$tmp" || rc=$?
      if [ "$rc" -eq 0 ]; then
        got=$FETCH_N
      elif [ "$rc" -eq 1 ]; then
        # The page holds at least one resource the source cannot serialize —
        # typically HAPI-1330, an externalized binary whose blob is gone. Narrow
        # it so the readable rows in this page are still exported.
        log_warn "$t: HTTP 400 on the whole page at offset $offset (${FETCH_DIAG:-no diagnostics})"
        log_warn "  narrowing to recover the readable rows; see $SKIP_FILE"
        if ! _descend "$base" "$offset" "$PAGE_SIZE" 50 "$tmp" "$t"; then
          break
        fi
        got=$DESCEND_GOT
      else
        log_err "search failed for $t at offset $offset (HTTP ${FETCH_STATUS:-000})"
        [ "${FETCH_STATUS:-}" = "401" ] && [ "$AUTH_MODE" = "static" ] \
          && log_err "  a static bearer expires mid-run — use EXPORT_TOKEN_URL/EXPORT_CLIENT_ID/EXPORT_CLIENT_SECRET"
        FAILURES+=("${t}[offset ${offset}]")
        break
      fi

      total=$((total + got))
      offset=$((offset + PAGE_SIZE))
      page=$((page + 1))

      # How much of this window the source actually accounted for: rows we kept
      # plus rows it refused. A window shortened by skips is NOT the end of the
      # result set, so the short-page test has to count the skipped ones too or
      # the export stops at the first unreadable band.
      covered=$((got + SKIPPED - skipped_before))

      # A short page is the last one. Guard the page count as well so a source
      # that ignores _offset can't spin here forever.
      if [ "$covered" -lt "$PAGE_SIZE" ]; then
        finished=1
      elif [ "$page" -ge "$MAX_PAGES" ]; then
        log_err "$t: hit the ${MAX_PAGES}-page ceiling at offset ${offset} — export truncated"
        FAILURES+=("${t}[page ceiling]")
        finished=1
      fi
    done

    if [ "$total" -gt 0 ]; then
      mv "$tmp" "$out"
      chmod 644 "$out"
      log_info "$t: $total resources over $page page(s) -> $out"
    else
      rm -f "$tmp"
      log_info "$t: 0 resources"
    fi
  done
}

poll_export() {
  local status_url="$1"
  local elapsed=0
  local headers body
  headers=$(mktemp)
  body=$(mktemp)
  while [ "$elapsed" -lt "$MAX_POLL_SECONDS" ]; do
    : >"$headers"
    : >"$body"
    ensure_token || return 1
    local code
    code=$(_curl -sS -o "$body" -D "$headers" -w '%{http_code}' \
      "${AUTH_HEADER[@]}" -H "Accept: application/json" "$status_url")
    case "$code" in
      200)
        cat "$body"
        rm -f "$headers" "$body"
        return 0
        ;;
      202)
        local retry
        retry=$(grep -i '^retry-after:' "$headers" | tail -n1 | awk '{print $2}' | tr -d '\r')
        if ! [[ "$retry" =~ ^[0-9]+$ ]]; then
          retry=15
        fi
        log_info "export still running; sleeping ${retry}s (elapsed=${elapsed}s)"
        sleep "$retry"
        elapsed=$((elapsed + retry))
        ;;
      *)
        log_err "export poll failed: HTTP $code"
        cat "$body" >&2
        rm -f "$headers" "$body"
        return 1
        ;;
    esac
  done
  rm -f "$headers" "$body"
  log_err "export polling timed out after ${MAX_POLL_SECONDS}s"
  return 1
}

main() {
  parse_common_args "$@"
  require_cmd curl jq

  if [ -z "$TENANT" ] || [ -z "$SOURCE_URL" ] || [ -z "$OUTPUT_DIR" ]; then
    show_help
    exit 2
  fi
  validate_tenant "$TENANT"

  # Source auth. Minted mode wins when the client credentials are present: it is
  # the only mode that survives a run longer than one token lifespan.
  local bearer="${TOKEN_ARG:-${EXPORT_BEARER:-}}"
  if [ -n "${EXPORT_TOKEN_URL:-}${EXPORT_CLIENT_ID:-}${EXPORT_CLIENT_SECRET:-}" ]; then
    local v
    for v in EXPORT_TOKEN_URL EXPORT_CLIENT_ID EXPORT_CLIENT_SECRET; do
      if [ -z "${!v:-}" ]; then
        log_err "$v is empty: minted auth needs all three of EXPORT_TOKEN_URL, EXPORT_CLIENT_ID, EXPORT_CLIENT_SECRET"
        exit 2
      fi
    done
    AUTH_MODE=minted
    ensure_token || exit 1
    log_info "minting source tokens from $EXPORT_TOKEN_URL (client=$EXPORT_CLIENT_ID, refresh every ${TOKEN_TTL}s)"
    [ -n "$bearer" ] && log_warn "ignoring --token / EXPORT_BEARER: the minted credentials take precedence"
  elif [ -n "$bearer" ]; then
    AUTH_MODE=static
    AUTH_HEADER=(-H "Authorization: Bearer ${bearer}")
    log_info "using a static bearer for source requests"
    log_warn "a static bearer is not refreshed — on a realm with a short accessTokenLifespan"
    log_warn "  (the legacy sites use 300s) a full export will 401 partway through."
    log_warn "  Prefer EXPORT_TOKEN_URL + EXPORT_CLIENT_ID + EXPORT_CLIENT_SECRET."
  fi

  mkdir -p "$OUTPUT_DIR"
  log_info "tenant=$TENANT source=$SOURCE_URL output=$OUTPUT_DIR"

  # --types narrows the run to a subset, e.g. to redo one type after a failure
  # without re-pulling the ones that already landed. Each type is written to its
  # own file, so a narrowed run leaves the others untouched.
  local requested="${TYPES_ARG:-$DEFAULT_TYPES}"
  [ -n "${TYPES_ARG:-}" ] && log_info "restricted to --types $TYPES_ARG"
  local effective_types
  effective_types=$(filter_supported_types "$SOURCE_URL" "$requested")
  if [ -z "$effective_types" ]; then
    log_err "no supported types remain after filtering against source CapabilityStatement"
    exit 1
  fi
  log_info "export _type: $effective_types"

  local status_url="" rc=0
  status_url=$(kick_export "$SOURCE_URL" "$effective_types" "$SINCE") || rc=$?

  if [ "$rc" -eq 3 ]; then
    log_warn "source does not implement bulk \$export — falling back to per-type search pagination"
    export_via_search "$SOURCE_URL" "$effective_types" "$SINCE" "$OUTPUT_DIR"
  elif [ "$rc" -ne 0 ]; then
    exit 1
  else
    log_info "export job status URL: $status_url${SINCE:+ (since=$SINCE)}"

    local manifest
    manifest=$(poll_export "$status_url")
    log_info "export complete; downloading outputs"

    local n
    n=$(echo "$manifest" | jq '.output | length')
    if [ -z "$n" ] || [ "$n" -eq 0 ]; then
      log_warn "export manifest had no output entries"
      return 0
    fi

    # Download each manifest output. curl retries transient failures (connect
    # timeouts, dropped transfers, 5xx) with backoff; we stream to a temp file so
    # a mid-transfer retry can never append a partial body to the real output. A
    # type that still fails after retries is recorded and skipped rather than
    # aborting the whole export — the run exits non-zero so it isn't silent.
    local i=0
    while [ "$i" -lt "$n" ]; do
      local rt url out tmp
      rt=$(echo "$manifest"  | jq -r ".output[$i].type")
      url=$(echo "$manifest" | jq -r ".output[$i].url")
      url=$(_canonicalize_url "$url" "$SOURCE_URL")
      out="${OUTPUT_DIR%/}/${rt}.ndjson"
      log_info "downloading $rt -> $out"
      ensure_token || { log_err "could not mint a source token"; exit 1; }
      tmp=$(mktemp)
      if _curl -fsS --retry 5 --retry-delay 5 --retry-all-errors \
           --connect-timeout 30 --max-time 1800 \
           "${AUTH_HEADER[@]}" -H "Accept: application/fhir+ndjson" -o "$tmp" "$url"; then
        cat "$tmp" >>"$out"
      else
        log_err "download failed for $rt (output[$i]) after retries: $url"
        FAILURES+=("${rt}[${i}]")
      fi
      rm -f "$tmp"
      i=$((i + 1))
    done
  fi

  log_info "counts per type:"
  for f in "${OUTPUT_DIR%/}"/*.ndjson; do
    [ -f "$f" ] || continue
    local rt count
    rt=$(basename "$f" .ndjson)
    count=$(wc -l <"$f" | tr -d ' ')
    printf '  %s: %s\n' "$rt" "$count" >&2
  done

  if [ "$SKIPPED" -gt 0 ]; then
    log_warn "$SKIPPED resource(s) could not be read from the source and were skipped."
    log_warn "  Recorded in $SKIP_FILE (type, offset, diagnostics)."
    log_warn "  HAPI-1330 means the externalized binary is gone: the resource still exists"
    log_warn "  on the source but its bytes do not, so there is nothing to migrate. This is"
    log_warn "  a source data question, not a retryable export failure."
  fi

  if [ "${#FAILURES[@]}" -gt 0 ]; then
    log_err "export INCOMPLETE — ${#FAILURES[@]} output(s) failed after retries: ${FAILURES[*]}"
    exit 1
  fi
}

main "$@"
