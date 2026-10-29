#!/usr/bin/env bash
# migrate-tenant.sh — end-to-end FHIR data migration from the legacy
# single-tenant HAPI into a multi-tenant partition on the new cluster.
# Subcommand-based, resumable (per-step markers under .state/), and supports
# an optional --since/--until window applied via $export _since plus a local
# jq post-filter on meta.lastUpdated.
#
# Subcommands:
#   inventory     per-type counts on source (windowed if --since/--until set)
#   export        $export from source → ./exports/<tenant>/raw/<Type>.ndjson
#   filter        apply --since/--until against meta.lastUpdated → filtered/
#   rewrite       re-home <source-url>/ prefixes in filtered/: .reference becomes
#                 relative, .url (Attachment retrieval endpoints) is re-based onto
#                 the target's /fhir/<tenant>/ — see phase 1 for why they differ;
#                 drop DEFAULT-partition types (DEFAULT_PARTITION_TYPES) and not-migrated
#                 types (DROP_TYPES); rescope collision-prone
#                 ids (REMAP_TYPES) to <tenant>-<legacy-id> and repoint every
#                 reference to them. Emits id-map.json + id-audit.txt.
#   relink-kc-subs  repoint the FHIR↔Keycloak linkage at the user ids the realm
#                 import minted (--realm-export). Without it every migrated login
#                 resolves as "flw". Emits kc-sub-map.json.
#   prepare-auth  point fhir-bootstrap's partition_id claim mapper at <tenant>
#                 so its JWT clears HAPI's per-tenant authorization. MUTATES
#                 the master-realm SA — only one migration can run at a time.
#   import        wrap scripts/import.sh against filtered/
#   validate      wrap scripts/validate.sh (window-aware)
#   all           run the above in order; skip steps whose .state/<step>.done
#                 marker already exists unless --force is set.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/keycloak.sh
source "$SCRIPT_DIR/lib/keycloak.sh"
# shellcheck source=lib/fhir.sh
source "$SCRIPT_DIR/lib/fhir.sh"

DEFAULT_TYPES="Organization,Practitioner,Location,Patient,Encounter,Condition,Observation,MedicationRequest,Procedure,DiagnosticReport,ServiceRequest"

# Types whose legacy ids are not globally unique across sites. HAPI enforces a
# unique (resource_type, resource_id) DB constraint that is NOT scoped by
# partition, so importing these verbatim either collides with a row another
# tenant already owns or, worse, silently resolves this tenant's references to
# that tenant's resource. The rewrite step rescopes them to
# "<tenant>-<legacy-id>" and repoints every reference.
#
# Two distinct ways a legacy id turns out not to be unique:
#   - human-readable slugs: Practitioner/siteadmin, Practitioner/flw1,
#     Practitioner/57, Basic/feature-flags
#   - *version 5* (name-based) UUIDs: derived by hashing a namespace plus a
#     stable name, so two sites that seed them identically produce byte-identical
#     ids. Observed on site-d's PractitionerRole and Group. Only v4 (random)
#     UUIDs are safe to import verbatim — check the version nibble, not the shape.
#
# The collision surfaces as HAPI-0825 ("client-assigned ID constraint failure"),
# whose "multiple client threads" wording is misleading: the upsert existence
# check is partition-scoped, finds nothing locally, and the subsequent INSERT
# trips the global constraint.
REMAP_TYPES=(Practitioner PractitionerRole Group Basic)

# Types that identify their Keycloak user by sub — Practitioner via
# identifier[type=KUID], PractitionerRole and Group via identifier[use=secondary].
# The relink-kc-subs step rewrites those values to the ids the realm import minted.
KC_SUB_TYPES=(Practitioner PractitionerRole Group)

# Types served out of the shared DEFAULT partition (see the HAPI configmap's
# merge_default_resource_types). The legacy copies are dropped rather than
# imported; references to them resolve against the DEFAULT seeds.
DEFAULT_PARTITION_TYPES=(Location)

# Types deliberately not migrated: device-local or deployment-local state that
# the new platform owns, rather than clinical history. Moved to
# filtered/dropped/ and recorded in dropped-types.txt so validate.sh reports
# them as SKIP instead of a permanent count mismatch.
#
# Basic on the legacy sites holds exactly two things:
#   - sync-metadata: one record per device (last-sync-date, device-id, flw-id,
#     pending-images). Bookkeeping for a sync that has already happened against
#     a server the devices no longer talk to. Migrating it would carry over a
#     flw-id that points at a pre-remap Practitioner id and a last-sync-date
#     that misdescribes the new partition; the devices re-establish this on
#     their next sync.
#   - feature-flags: deployment config, which onboard-tenant-runtime.sh already
#     creates as <tenant>-feature-flags. Importing the legacy copy overwrites
#     the tenant's live flags with the old site's values.
DROP_TYPES=(Basic)

show_help() {
  cat <<'EOF' >&2
migrate-tenant.sh — orchestrate FHIR data migration into a tenant partition.

Usage:
  migrate-tenant.sh <subcommand> --env <env> --tenant <slug> \
                    --source-url <url> [--token <jwt>] [--since <ts>] [--until <ts>] \
                    [--output <dir>] [--base-url <host>] [--force]

Source-server auth (needed whenever the legacy HAPI is secured — it answers
/metadata unauthenticated but returns "HAPI-0334: Access denied by default
policy" for every resource read, so inventory/export/validate come back empty
without it; the credentials need the FHIR_* realm roles on the source realm):

  EXPORT_TOKEN_URL      preferred. With EXPORT_CLIENT_ID and EXPORT_CLIENT_SECRET,
  EXPORT_CLIENT_ID      a client_credentials token is minted per subcommand, and
  EXPORT_CLIENT_SECRET  export.sh re-mints on a TTL for the life of its run. Read
                        the secret in without touching shell history:
                          read -rs EXPORT_CLIENT_SECRET
                        Example token url:
                          https://<site>/auth/realms/arogyam/protocol/openid-connect/token

  --token <jwt>  a static bearer (also EXPORT_BEARER; --token wins), used only
                 when the three vars above are unset. It is never refreshed, so
                 on a realm with a short accessTokenLifespan — the legacy sites
                 use 300s — a full export 401s partway through and the retries
                 cannot recover it. Fine for inventory or a smoke test.

Subcommands:
  inventory | export | filter | rewrite | relink-kc-subs | prepare-auth |
  import | validate | all

prepare-auth points fhir-bootstrap's master-realm partition_id claim mapper at
--tenant so its JWT clears HAPI's per-tenant authorization on writes. This
mutates a shared SA — only one migration can run at a time.

relink-kc-subs (requires --realm-export <path|gs://…>):
  The realm import strips nested ids so Keycloak mints fresh ones — it must, or
  cloned per-site realms collide on identical UUIDs. But the migrated FHIR data
  identifies its Keycloak user by sub (Practitioner identifier[type=KUID];
  PractitionerRole and Group identifier[use=secondary]), so after the import
  every one of those is dangling. The dashboard resolves a login's role via
  PractitionerRole?identifier=<sub> and falls back to "flw" on a miss, which
  means a stale sub does not error — it silently demotes every user to field
  worker. This step rebuilds the linkage, joining on username (stable across the
  import) rather than sub (not). Run it after import-keycloak-realm.sh and
  before `import`.

Time window (FHIR instants, e.g. 2025-01-01T00:00:00Z):
  --since <ts>   lower bound (used as _since on $export; also applied locally)
  --until <ts>   upper bound (local jq post-filter only; HAPI has no native flag)

Id rescoping (rewrite step):
  HAPI's unique (resource_type, resource_id) constraint is not partition-scoped,
  so legacy slug ids (Practitioner/flw1, Practitioner/siteadmin) collide across
  tenants. rewrite rescopes them to <tenant>-<legacy-id>, preserves the legacy id
  as an identifier, and repoints every reference. The mapping is a pure function
  of (tenant, legacy id), so backfill and delta runs agree without shared state.

Outputs (default --output ./exports/<tenant>):
  inventory.txt
  raw/<Type>.ndjson         (export step)
  filtered/<Type>.ndjson    (filter + rewrite write here)
  filtered/default-partition/<Type>.ndjson  (rewrite: served from DEFAULT, not imported)
  filtered/dropped/<Type>.ndjson  (rewrite: types deliberately not migrated)
  dropped-types.txt         (rewrite: consumed by validate.sh, reported as SKIP)
  id-map.json               (rewrite: legacy id → tenant-scoped id)
  id-audit.txt              (rewrite: legacy ids seen outside reference position)
  kc-sub-map.json           (relink-kc-subs: legacy KC sub → username → live sub)
  failed/<Type>.ndjson      (import step, on failures)
  validation-report.txt
  .state/<step>.done        (resume markers — delete or pass --force to rerun)
EOF
}

SUB=""
case "${1:-}" in
  inventory|export|filter|rewrite|relink-kc-subs|prepare-auth|import|validate|all) SUB=$1; shift ;;
  -h|--help|"") show_help; exit 0 ;;
  *) printf '[ERROR] unknown subcommand: %s\n' "$1" >&2; show_help; exit 2 ;;
esac

parse_common_args "$@"
require_cmd curl jq

if [ -z "$ENV" ] || [ -z "$TENANT" ]; then
  log_err "--env and --tenant are required"
  exit 2
fi
validate_env "$ENV"
validate_tenant "$TENANT"

OUTPUT_DIR="${OUTPUT_DIR:-./exports/${TENANT}}"
STATE_DIR="${OUTPUT_DIR%/}/.state"
RAW_DIR="${OUTPUT_DIR%/}/raw"
FILTERED_DIR="${OUTPUT_DIR%/}/filtered"

mkdir -p "$STATE_DIR"

# --- source-server auth --------------------------------------------------

# Bearer token for the OLD source server, from --token or the EXPORT_BEARER env
# var (--token wins). The legacy HAPI leaves /metadata open but answers every
# resource read with "HAPI-0334: Access denied by default policy", so without a
# token the inventory silently counts 0 for every type. Empty by default —
# source requests are then sent unauthenticated, which is fine for the older
# unsecured single-tenant deployments.
SOURCE_BEARER="${TOKEN_ARG:-${EXPORT_BEARER:-}}"
SOURCE_MINTED=0

# When the source client credentials are in the environment, mint our own bearer
# from them rather than making the operator hold a token across phases. export.sh
# reads the same three vars and re-mints for the life of its run; the subcommands
# here (inventory, validate) are each short enough for one token, and every
# subcommand is a fresh process, so a fresh mint per invocation is sufficient.
if [ -n "${EXPORT_TOKEN_URL:-}" ] && [ -n "${EXPORT_CLIENT_ID:-}" ] && [ -n "${EXPORT_CLIENT_SECRET:-}" ]; then
  _minted=$(_curl -sS --max-time 30 -X POST \
    -d grant_type=client_credentials \
    -d "client_id=${EXPORT_CLIENT_ID}" \
    --data-urlencode "client_secret=${EXPORT_CLIENT_SECRET}" \
    "$EXPORT_TOKEN_URL" 2>/dev/null | jq -r '.access_token // empty' 2>/dev/null || true)
  if [ -z "$_minted" ]; then
    log_err "could not mint a source token from $EXPORT_TOKEN_URL (client=$EXPORT_CLIENT_ID)"
    exit 1
  fi
  SOURCE_BEARER="$_minted"
  SOURCE_MINTED=1
  unset _minted
  log_info "minted a source bearer from $EXPORT_TOKEN_URL for ($SOURCE_URL)"
elif [ -n "$SOURCE_BEARER" ]; then
  log_info "using bearer auth for source ($SOURCE_URL)"
fi

# _source_curl — _curl against the source server with auth when we have it.
# Explicit if/else rather than "${ARR[@]}": an empty array expansion is an
# unbound-variable error under `set -u` on macOS bash 3.2.
_source_curl() {
  if [ -n "$SOURCE_BEARER" ]; then
    _curl -H "Authorization: Bearer $SOURCE_BEARER" "$@"
  else
    _curl "$@"
  fi
}

# --- step-state helpers --------------------------------------------------

is_done()      { [ -f "$STATE_DIR/$1.done" ]; }
mark_done()    { touch "$STATE_DIR/$1.done"; }
clear_step()   { rm -f "$STATE_DIR/$1.done"; }

# --- partition id resolution --------------------------------------------

resolve_partition_id() {
  local base fhir_base token id
  base=$(resolve_base_url "$ENV" "$BASE_URL")
  fhir_base="https://${base}/fhir"
  token=$(kc_fhir_bootstrap_token "$ENV" "$base")
  id=$(fhir_get_partition_id_by_name "$token" "$fhir_base" "$TENANT")
  if [ -z "$id" ]; then
    log_err "no partition found with name=$TENANT on $fhir_base — run onboard-tenant-runtime.sh first"
    return 1
  fi
  echo "$id"
}

# --- subcommands ---------------------------------------------------------

cmd_inventory() {
  if [ -z "$SOURCE_URL" ]; then log_err "--source-url required for inventory"; return 2; fi
  local out="${OUTPUT_DIR%/}/inventory.txt"
  local window=""
  [ -n "$SINCE" ] && window="${window}&_lastUpdated=ge${SINCE}"
  [ -n "$UNTIL" ] && window="${window}&_lastUpdated=lt${UNTIL}"
  log_info "inventorying source types${window:+ (window: ${SINCE:-*}..${UNTIL:-*})}"
  : >"$out"
  local types
  types=$(_source_curl -fsS --max-time 30 -H "Accept: application/fhir+json" "${SOURCE_URL}/metadata" \
    | jq -r '.rest[].resource[].type' | sort -u)
  local rt n line body code errors=0
  while IFS= read -r rt; do
    [ -z "$rt" ] && continue
    # No -f: we want the OperationOutcome body on a 4xx rather than an empty
    # string, so an auth failure is reported instead of counted as 0.
    body=$(_source_curl -sS --max-time 30 -w '\n%{http_code}' \
      -H "Accept: application/fhir+json" \
      "${SOURCE_URL}/${rt}?_summary=count${window}" 2>/dev/null || true)
    code=${body##*$'\n'}
    if [ "$code" != "200" ]; then
      errors=$((errors + 1))
      # A secured source rejects every one of ~145 types identically; log the
      # first few in full and keep the rest to the summary below.
      if [ "$errors" -le 3 ]; then
        log_warn "$rt: HTTP ${code:-?} — $(printf '%s' "${body%$'\n'*}" \
          | jq -r '.issue[0].diagnostics // empty' 2>/dev/null | head -1)"
      elif [ "$errors" -eq 4 ]; then
        log_warn "(further per-type failures suppressed)"
      fi
      continue
    fi
    n=$(printf '%s' "${body%$'\n'*}" | jq -r '.total // 0' 2>/dev/null || echo 0)
    [ "$n" = "0" ] && continue
    line=$(printf '%-22s %s' "$rt" "$n")
    printf '%s\n' "$line" >>"$out"
    printf '  %s\n' "$line" >&2
  done <<<"$types"
  if [ "$errors" -gt 0 ]; then
    log_err "$errors type(s) failed to count on the source server."
    if [ -z "$SOURCE_BEARER" ]; then
      log_err "no source token set — pass --token <jwt> (or export EXPORT_BEARER)."
      log_err "HAPI-0334 means the source needs a bearer with the FHIR_* realm roles."
    fi
    return 1
  fi
  mark_done inventory
  log_info "inventory: $(wc -l <"$out" | tr -d ' ') populated types written to $out"
}

cmd_export() {
  if [ -z "$SOURCE_URL" ]; then log_err "--source-url required for export"; return 2; fi
  mkdir -p "$RAW_DIR"
  local args=(--tenant "$TENANT" --source-url "$SOURCE_URL" --output "$RAW_DIR")
  [ -n "${TYPES_ARG:-}" ] && args+=(--types "$TYPES_ARG")
  [ -n "${START_OFFSET:-}" ] && args+=(--start-offset "$START_OFFSET")
  [ -n "$SOURCE_BEARER" ] && [ "$SOURCE_MINTED" -eq 0 ] && args+=(--token "$SOURCE_BEARER")
  [ -n "$SINCE" ] && args+=(--since "$SINCE")
  "$SCRIPT_DIR/export.sh" "${args[@]}"
  mark_done export
}

cmd_filter() {
  if [ ! -d "$RAW_DIR" ]; then log_err "missing $RAW_DIR — run export first"; return 1; fi
  mkdir -p "$FILTERED_DIR"
  local f out total kept
  for f in "$RAW_DIR"/*.ndjson; do
    [ -f "$f" ] || continue
    out="$FILTERED_DIR/$(basename "$f")"
    if [ -z "$SINCE$UNTIL" ]; then
      cp "$f" "$out"
    else
      jq -c --arg since "${SINCE:-}" --arg until "${UNTIL:-}" '
        select(
          (($since == "") or ((.meta.lastUpdated // "") >= $since))
          and
          (($until == "") or ((.meta.lastUpdated // "9999") < $until))
        )
      ' "$f" >"$out"
    fi
    total=$(wc -l <"$f" | tr -d ' ')
    kept=$(wc -l <"$out" | tr -d ' ')
    log_info "filter $(basename "$f"): kept ${kept}/${total}"
  done
  mark_done filter
}

# Build the legacy-id → tenant-scoped-id map for one resource type. Echoes a
# JSON object (possibly empty).
#
# Two sources, unioned: the ids of the resources present in
# filtered/<Type>.ndjson, and every id appearing in *reference* position
# ("<Type>/<id>") across every filtered file.
#
# The reference scan is what makes a delta run agree with the backfill. A
# window that contains no Practitioner of its own still carries references to
# practitioners an earlier run already rescoped; building the map only from ids
# we can see leaves those references pointing at the raw legacy id. That fails
# two different ways, neither of them obvious: if the legacy id is a
# soft-deleted row in this partition the write is rejected with HAPI-1096, and
# if it is simply absent the write *succeeds* — enforce_referential_integrity_on_write
# is false — leaving the resource silently detached from its practitioner.
# Rescoping is a pure function of (tenant, legacy id), so deriving it from the
# reference alone lands on the same id the backfill minted.
#
# Ids already carrying the tenant prefix are excluded, which is what makes a
# second rewrite pass a no-op.
_remap_build_map() {
  local rt="$1" f="$FILTERED_DIR/$1.ndjson"
  local own='[]' refs='[]' ref_file g

  if [ -f "$f" ]; then
    own=$(jq -sc '[ .[] | .id | select(type == "string") ]' "$f")
  fi

  # Streamed per file rather than slurped: the filtered set runs to tens of MB
  # on a full-site window and `jq -s` over all of it at once is needlessly large.
  #
  # Deduplicated on the way through, not afterwards inside jq. Every resource
  # that names a practitioner contributes a line, so on a 372k-resource tenant
  # this list reaches hundreds of thousands of entries — all pointing at the
  # same few dozen ids. Building the array first and passing it as --argjson
  # overflows ARG_MAX and jq dies with "Argument list too long"; sort -u brings
  # it back to the number of DISTINCT ids, which is what `unique` produced
  # anyway. Held in a file rather than a shell variable for the same reason.
  ref_file=$(mktemp)
  for g in "$FILTERED_DIR"/*.ndjson; do
    [ -f "$g" ] || continue
    jq -r --arg rt "$rt" '
      .. | objects | .reference? // empty
      | select(type == "string")
      | select(startswith($rt + "/"))
      | split("/")[1] // empty
    ' "$g"
  done | sort -u >"$ref_file"
  refs=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$ref_file")
  rm -f "$ref_file"

  jq -nc --arg t "$TENANT" --argjson own "$own" --argjson refs "$refs" '
    ($own + $refs)
    | map(select(startswith($t + "-") | not))
    | unique
    | map({ key: ., value: ($t + "-" + .) })
    | from_entries
  '
}

cmd_rewrite() {
  if [ -z "$SOURCE_URL" ]; then log_err "--source-url required for rewrite"; return 2; fi
  if [ ! -d "$FILTERED_DIR" ]; then log_err "missing $FILTERED_DIR — run filter first"; return 1; fi
  local prefix="${SOURCE_URL%/}/"
  local f rt

  # --- phase 1: re-home absolute source URLs -----------------------------
  # .reference and .url are NOT symmetric here, however alike they look.
  #
  # .reference is resolved by HAPI against whatever base serves the request, so
  # stripping the source prefix down to "<Type>/<id>" is correct and is what
  # makes the row portable between servers.
  #
  # .url is not a reference field. The one that matters is Attachment.url — a
  # *retrieval endpoint*, on Media.content.url and on QuestionnaireResponse
  # item[].answer[].valueAttachment.url — and since the legacy
  # DocumentReference.context is null, that URL is the only path from an
  # Encounter to its images. Nothing re-bases it: the dashboard puts it in an
  # <img src> (the browser then resolves it against the *page*) and
  # arogyam-backend's upload-status cron matches it against the absolute FHIR
  # base. Strip it and both consumers lose the tenant, because this server is
  # URL_BASED-partitioned and its base is /fhir/<tenant>/, not /fhir/.
  #
  # So: rewrite .url onto the target base instead of relativising it. Skipping
  # this in the original hunk left ~9,000 of state-c's 12,362 Media pointing at
  # nowhere — images 404, every migrated encounter pinned at uploadStatus=partial,
  # and therefore no screening or tele-review Task ever created for them. See
  # internal design notes.
  # Split from `local` deliberately: `local x=$(f)` swallows f's exit status, so
  # a missing --base-url / $*_BASE_URL would sail past set -e and write "https:///fhir/<tenant>/".
  local target_base
  target_base="https://$(resolve_base_url "$ENV" "$BASE_URL")/fhir/${TENANT}"
  for f in "$FILTERED_DIR"/*.ndjson; do
    [ -f "$f" ] || continue
    jq -c --arg p "$prefix" --arg t "${target_base}/" '
      walk(
        if type == "object" then
          ( if has("reference") and (.reference | type == "string") and (.reference | startswith($p))
            then .reference |= ltrimstr($p) else . end )
          |
          # Idempotent: a value already on the target base is left alone, so
          # re-running rewrite (or running it over a partially-rewritten delta)
          # is a no-op rather than a double prefix.
          ( if has("url") and (.url | type == "string")
               and (.url | startswith($p)) and (.url | startswith($t) | not)
            then .url |= ($t + ltrimstr($p)) else . end )
        else . end
      )
    ' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  done
  log_info "rewrote absolute $prefix prefixes in $FILTERED_DIR (.reference → relative, .url → $target_base)"

  # --- phase 2: drop shared-DEFAULT types --------------------------------
  # These are listed in the HAPI configmap's merge_default_resource_types /
  # default_only_resource_types: a tenant read is served from DEFAULT, so the
  # legacy copies must not be written into the tenant partition (they'd collide
  # on the same global id constraint and shadow the shared seeds). References to
  # them are deliberately left alone — the merge read resolves them.
  local default_partition_dir="${FILTERED_DIR%/}/default-partition"
  for rt in "${DEFAULT_PARTITION_TYPES[@]}"; do
    f="$FILTERED_DIR/${rt}.ndjson"
    [ -f "$f" ] || continue
    mkdir -p "$default_partition_dir"
    mv "$f" "$default_partition_dir/${rt}.ndjson"
    log_warn "$rt is served from the shared DEFAULT partition — moved $(wc -l <"$default_partition_dir/${rt}.ndjson" | tr -d ' ') resource(s) to $default_partition_dir/ (NOT imported)"
    log_warn "  confirm the DEFAULT copies exist before importing, e.g.:"
    log_warn "    curl -H \"Authorization: Bearer \$TOK\" https://<base>/fhir/DEFAULT/${rt}/<id>"
  done

  # --- phase 2b: drop types we deliberately do not migrate ----------------
  # Unlike DEFAULT_PARTITION_TYPES these have no counterpart anywhere — they are simply not
  # part of the migration. Recorded so validate.sh reports them as SKIP rather
  # than failing forever on a count the target is never meant to match.
  local dropped_dir="${FILTERED_DIR%/}/dropped"
  local dropped_file="${OUTPUT_DIR%/}/dropped-types.txt"
  : >"$dropped_file"
  for rt in "${DROP_TYPES[@]}"; do
    printf '%s\n' "$rt" >>"$dropped_file"
    f="$FILTERED_DIR/${rt}.ndjson"
    [ -f "$f" ] || continue
    mkdir -p "$dropped_dir"
    mv "$f" "$dropped_dir/${rt}.ndjson"
    log_warn "$rt is not migrated (device/deployment-local state) — moved $(wc -l <"$dropped_dir/${rt}.ndjson" | tr -d ' ') resource(s) to $dropped_dir/ (NOT imported)"
  done

  # --- phase 3: tenant-scope collision-prone ids -------------------------
  local map_file="${OUTPUT_DIR%/}/id-map.json"
  local combined='{}'
  [ -f "$map_file" ] && combined=$(cat "$map_file")

  for rt in "${REMAP_TYPES[@]}"; do
    # No [ -f "$f" ] guard: a delta window can carry references to a remapped
    # type without carrying any of its resources, and those still need 3b.
    f="$FILTERED_DIR/${rt}.ndjson"
    local map n
    map=$(_remap_build_map "$rt")
    n=$(jq -r 'length' <<<"$map")
    if [ "$n" -eq 0 ]; then
      log_info "remap $rt: nothing to do (all ids already tenant-scoped)"
      continue
    fi

    # FHIR ids are [A-Za-z0-9.-]{1,64}; the tenant prefix can only push us over
    # the length bound. Fail loudly rather than let HAPI reject mid-import.
    local bad
    bad=$(jq -r 'to_entries[] | select(.value | test("^[A-Za-z0-9.-]{1,64}$") | not) | .value' <<<"$map")
    if [ -n "$bad" ]; then
      log_err "remap $rt produced ids that violate the FHIR id grammar:"
      printf '  %s\n' $bad >&2
      return 1
    fi

    # 3a: rewrite the resources' own ids, preserving the legacy id as an
    # identifier so the row stays traceable back to the source system. Skipped
    # when the window carried no resources of this type — only references.
    if [ -f "$f" ]; then
      jq -c --argjson m "$map" --arg sys "${prefix}${rt}" '
        if ($m[.id] // null) != null then
          .id as $old
          | .id = $m[$old]
          # Appended, never sorted: validate.sh strips this entry to compare the
          # migrated resource against the source, so the surviving identifiers
          # must keep their original order.
          | .identifier = (
              (.identifier // []) as $ids
              | if ($ids | any(.system == $sys and .value == $old))
                then $ids
                else $ids + [{ system: $sys, value: $old }] end
            )
        else . end
      ' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    fi

    # 3b: repoint every reference to those ids, across every type. Matching is
    # scoped to reference position and to an exact id match on the segment after
    # "<Type>/" — a blind string replace would be unsafe, since legacy ids like
    # "57" and "73" occur throughout the data as ordinary values.
    for f in "$FILTERED_DIR"/*.ndjson; do
      [ -f "$f" ] || continue
      jq -c --argjson m "$map" --arg rt "$rt" '
        walk(
          if type == "object" and (.reference | type == "string")
             and (.reference | startswith($rt + "/")) then
            (.reference | split("/")) as $parts
            | if ($m[$parts[1]] // null) != null
              then .reference = ([$rt, $m[$parts[1]]] + $parts[2:] | join("/"))
              else . end
          else . end
        )
      ' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    done

    combined=$(jq -c --argjson m "$map" --arg rt "$rt" \
      '.[$rt] = ((.[$rt] // {}) + $m)' <<<"$combined")
    log_info "remap $rt: $n id(s) tenant-scoped; references updated across $FILTERED_DIR"
  done

  if [ "$combined" != '{}' ]; then
    jq -S . <<<"$combined" >"$map_file"
    log_info "id map written to $map_file"
  fi

  # --- phase 4: audit for legacy ids left outside reference position -----
  # Reports (never rewrites) any string field whose entire value is a remapped
  # legacy id — e.g. an id embedded in a Basic sync-metadata payload or an
  # extension valueString. Those need a human decision, not a regex.
  local audit="${OUTPUT_DIR%/}/id-audit.txt"
  local ids
  ids=$(jq -c '[.[] | keys[]] | flatten | unique' <<<"$combined")
  if [ "$ids" != '[]' ]; then
    : >"$audit"
    for f in "$FILTERED_DIR"/*.ndjson; do
      [ -f "$f" ] || continue
      jq -r --argjson ids "$ids" --arg file "$(basename "$f")" '
        . as $r
        | [ paths(type == "string") as $p
            | select(($ids | index($r | getpath($p))) != null)
            | ($p | map(tostring) | join(".")) ]
        | select(length > 0)
        | "\($file)  \($r.resourceType)/\($r.id)  " + join(", ")
      ' "$f" >>"$audit" || true
    done
    local hits
    hits=$(wc -l <"$audit" | tr -d ' ')
    if [ "$hits" -gt 0 ]; then
      log_warn "id-audit: $hits resource(s) carry a legacy id outside reference position — review $audit"
    else
      log_info "id-audit: no legacy ids found outside reference position"
    fi
  fi

  mark_done rewrite
}

# relink-kc-subs — repoint the FHIR↔Keycloak linkage at the *new* user ids.
#
# The migrated resources identify their Keycloak user by sub: Practitioner
# carries it as identifier[type=KUID], PractitionerRole and Group as
# identifier[use=secondary]. The dashboard resolves a login's role by querying
# PractitionerRole?identifier=<sub> and silently falls back to "flw" when that
# misses — so a stale sub does not error, it quietly demotes every user.
#
# import-keycloak-realm.sh strips *nested* ids so Keycloak mints fresh ones,
# which it must: the legacy per-site realms are clones of one template and carry
# byte-identical user/client/role UUIDs, so the second import would 409. That is
# safe inside Keycloak (nothing there references an object by an id that is not
# also resolvable by name) but not outside it — the FHIR data holds those user
# ids, and after import every one of them is dangling.
#
# Username is the join key: it is stable across the import, whereas the sub is
# not. Run after import-keycloak-realm.sh and before `import`.
cmd_relink_kc_subs() {
  if [ ! -d "$FILTERED_DIR" ]; then log_err "missing $FILTERED_DIR — run filter first"; return 1; fi
  if [ -z "$REALM_EXPORT" ]; then
    log_err "--realm-export <path|gs://…> required: the legacy realm JSON, which is the only"
    log_err "  record of the pre-import user ids (the live realm has already replaced them)"
    return 2
  fi

  local base admin_token realm_json
  base=$(resolve_base_url "$ENV" "$BASE_URL")
  admin_token=$(kc_admin_token "$ENV" "$base")

  realm_json=$(mktemp)
  case "$REALM_EXPORT" in
    gs://*) gsutil -q cp "$REALM_EXPORT" "$realm_json" \
              || { log_err "could not read $REALM_EXPORT"; return 1; } ;;
    *)      cp "$REALM_EXPORT" "$realm_json" \
              || { log_err "could not read $REALM_EXPORT"; return 1; } ;;
  esac

  local live_users map_file
  live_users=$(mktemp)
  _kc_curl -fsS -H "Authorization: Bearer $admin_token" \
    "https://${base}/auth/admin/realms/${TENANT}/users?max=1000" >"$live_users" \
    || { log_err "could not list users in realm $TENANT"; return 1; }

  map_file="${OUTPUT_DIR%/}/kc-sub-map.json"
  jq -n --slurpfile old "$realm_json" --slurpfile new "$live_users" '
    ($old[0].users // [] | map({key: .id, value: .username}) | from_entries) as $byid
    | ($new[0] | map({key: .username, value: .id}) | from_entries) as $byname
    | [ $byid | to_entries[]
        | select($byname[.value] != null)
        | {legacy: .key, username: .value, new: $byname[.value]} ]
  ' >"$map_file"

  local n unmatched
  n=$(jq 'length' "$map_file")
  # Users present in the legacy export with no live counterpart. Service
  # accounts are expected here (they are recreated per-realm, not migrated);
  # a real username showing up means the realm import dropped a user.
  unmatched=$(jq -r --slurpfile new "$live_users" '
    ($new[0] | map(.username)) as $live
    | [ .users[]? | select(.username as $u | $live | index($u) | not) | .username ]
    | map(select(startswith("service-account-") | not)) | join(", ")
  ' "$realm_json")
  rm -f "$realm_json" "$live_users"

  log_info "kc-sub map: $n username(s) matched; written to $map_file"
  if [ -n "$unmatched" ]; then
    log_warn "legacy users with no live Keycloak account: $unmatched"
    log_warn "  their PractitionerRoles will keep a dangling sub and those logins will resolve as flw"
  fi
  if [ "$n" -eq 0 ]; then
    log_err "no usernames matched — wrong --realm-export, or the realm was not imported yet"
    return 1
  fi

  # Rewrite by value, not by index: match any identifier whose value is a known
  # legacy sub, wherever it sits in the array. Scoped to .identifier[].value so a
  # sub appearing as an ordinary string elsewhere is left alone.
  local rt f rewritten total=0
  for rt in "${KC_SUB_TYPES[@]}"; do
    f="$FILTERED_DIR/${rt}.ndjson"
    [ -f "$f" ] || continue
    jq -c --slurpfile m "$map_file" '
      ($m[0] | map({key: .legacy, value: .new}) | from_entries) as $sub
      | if (.identifier | type) == "array"
        then .identifier |= map(
               if ($sub[.value] // null) != null then .value = $sub[.value] else . end)
        else . end
    ' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    rewritten=$(jq -r --slurpfile m "$map_file" '
      ([$m[0][].new]) as $new
      | [ .identifier[]? | select(.value as $v | $new | index($v)) ] | length
    ' "$f" | awk '{s+=$1} END {print s+0}')
    total=$((total + rewritten))
    log_info "relink $rt: $rewritten identifier(s) now point at live Keycloak subs"
  done

  if [ "$total" -eq 0 ]; then
    log_warn "no identifiers were relinked — already run, or this tenant's data predates KC-sub linkage"
  fi
  mark_done relink-kc-subs
}

cmd_prepare_auth() {
  local base kc_base admin_token client_uuid sa_token claim_seen roles_seen
  base=$(resolve_base_url "$ENV" "$BASE_URL")
  kc_base="$base"
  log_warn "prepare-auth mutates the master-realm fhir-bootstrap client (partition_id claim → $TENANT). Only one migration can run at a time."
  admin_token=$(kc_admin_token "$ENV" "$kc_base")
  client_uuid=$(kc_get_client_id_by_clientid "$admin_token" "$kc_base" "master" "fhir-bootstrap")
  if [ -z "$client_uuid" ]; then
    log_err "fhir-bootstrap client not found in master realm — run scripts/seed-fhir-bundle.sh --env $ENV first"
    return 1
  fi
  kc_add_hardcoded_claim_mapper "$admin_token" "$kc_base" "master" "$client_uuid" "partition_id" "$TENANT"

  # Verify by minting a fresh token and decoding its payload.
  sa_token=$(kc_fhir_bootstrap_token "$ENV" "$kc_base")
  local payload
  payload=$(printf '%s' "$sa_token" | cut -d. -f2 \
    | tr '_-' '/+' \
    | { read -r p; while [ $(( ${#p} % 4 )) -ne 0 ]; do p="${p}="; done; printf '%s' "$p"; } \
    | base64 -d 2>/dev/null)
  claim_seen=$(jq -r '.partition_id // empty' <<<"$payload")
  roles_seen=$(jq -r '.realm_access.roles // [] | join(",")' <<<"$payload")
  log_info "verification: partition_id='$claim_seen'  realm_access.roles=[$roles_seen]"
  if [ "$claim_seen" != "$TENANT" ]; then
    log_err "fhir-bootstrap token still missing partition_id=$TENANT (got '$claim_seen')"
    return 1
  fi
  if ! grep -q 'FHIR_ALL_WRITE' <<<"$roles_seen"; then
    log_err "fhir-bootstrap token missing FHIR_ALL_WRITE realm-role — re-run seed-fhir-bundle.sh after pulling latest"
    return 1
  fi
  mark_done prepare-auth
  log_info "prepare-auth complete"
}

cmd_import() {
  if [ ! -d "$FILTERED_DIR" ]; then log_err "missing $FILTERED_DIR — run filter first"; return 1; fi
  local pid
  pid=$(resolve_partition_id)
  log_info "import: partition_id=$pid tenant=$TENANT"
  "$SCRIPT_DIR/import.sh" --env "$ENV" --partition-id "$pid" --input "$FILTERED_DIR" \
    ${BASE_URL:+--base-url "$BASE_URL"}
  mark_done import
}

cmd_validate() {
  if [ -z "$SOURCE_URL" ]; then log_err "--source-url required for validate"; return 2; fi
  local pid
  pid=$(resolve_partition_id)
  log_info "validate: partition_id=$pid tenant=$TENANT"
  local args=(--env "$ENV" --tenant "$TENANT" --partition-id "$pid" \
              --source-url "$SOURCE_URL" --output "$OUTPUT_DIR")
  [ -n "$SOURCE_BEARER" ] && args+=(--token "$SOURCE_BEARER")
  [ -n "$SINCE" ]    && args+=(--since "$SINCE")
  [ -n "$UNTIL" ]    && args+=(--until "$UNTIL")
  [ -n "$BASE_URL" ] && args+=(--base-url "$BASE_URL")
  "$SCRIPT_DIR/validate.sh" "${args[@]}"
  mark_done validate
}

cmd_all() {
  local step fn
  for step in inventory export filter rewrite relink-kc-subs prepare-auth import validate; do
    if is_done "$step" && [ "$FORCE" -ne 1 ]; then
      log_info "skip $step (done; pass --force to redo)"
      continue
    fi
    log_info "==> $step"
    fn="cmd_${step//-/_}"
    "$fn"
  done
}

# --- dispatch ------------------------------------------------------------

if [ "$FORCE" -eq 1 ] && [ "$SUB" != "all" ]; then
  clear_step "$SUB"
fi

case "$SUB" in
  inventory)    cmd_inventory ;;
  export)       cmd_export ;;
  filter)       cmd_filter ;;
  rewrite)        cmd_rewrite ;;
  relink-kc-subs) cmd_relink_kc_subs ;;
  prepare-auth) cmd_prepare_auth ;;
  import)       cmd_import ;;
  validate)     cmd_validate ;;
  all)          cmd_all ;;
esac
