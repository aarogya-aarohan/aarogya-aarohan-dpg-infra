# shellcheck shell=bash
# common.sh — shared helpers for all aa-onboard scripts.
# Provides logging, arg parsing, env→cluster mapping, gcloud + secret helpers.
# Source via: SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) && source "$SCRIPT_DIR/lib/common.sh"

set -euo pipefail

ENV=""
TENANT=""
BASE_URL=""
SOURCE_URL=""
OUTPUT_DIR=""
PARTITION_ID=""
NO_VERIFY=0
SKIP_REALM_CREATE=0
BUNDLE_PATH=""
REALM_EXPORT=""
USER_ARG=""
PASSWORD_ARG=""
CLIENT_ARG=""
TOKEN_ARG=""
# Comma-separated resource types, overriding a script's default list.
TYPES_ARG=""
# Offset to resume a paged run from (export.sh).
START_OFFSET=""
INPUT_DIR=""
SOURCE_CONTEXT=""
SOURCE_NAMESPACE=""
SINCE=""
UNTIL=""
FORCE=0
PARALLELISM="${IMPORT_PARALLELISM:-8}"

_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# _curl — curl with an optional TCP-level redirect, used by every HTTP call in
# these scripts. When CURL_CONNECT_TO is set (curl --connect-to syntax,
# "<host>:<port>:<target-host>:<target-port>"), requests to <host>:<port> are
# connected to <target-host>:<target-port> instead, while the URL — and thus
# TLS SNI, cert validation, and the Host header — keeps the original hostname.
# Lets scripts reach the in-cluster ingress-nginx through a kubectl
# port-forward and skip the NAT/LB hairpin:
#   kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8443:443 &
#   CURL_CONNECT_TO=<public-host>:443:127.0.0.1:8443 scripts/import.sh ...
# Requests to other hosts (e.g. a --source-url) are unaffected.
#
# CURL_INSECURE=1 (honored only together with CURL_CONNECT_TO) additionally
# skips TLS verification. Needed with the port-forward above: the real cert
# terminates at the platform LB, so in-cluster nginx presents its default
# self-signed cert. The TLS hop this skips runs entirely inside the
# authenticated kubectl tunnel.
_curl() {
  if [ -n "${CURL_CONNECT_TO:-}" ]; then
    if [ "${CURL_INSECURE:-0}" = "1" ]; then
      curl --connect-to "$CURL_CONNECT_TO" --insecure "$@"
    else
      curl --connect-to "$CURL_CONNECT_TO" "$@"
    fi
  else
    curl "$@"
  fi
}

log_info() { printf '[INFO]  %s %s\n' "$(_ts)" "$*" >&2; }
log_warn() { printf '[WARN]  %s %s\n' "$(_ts)" "$*" >&2; }
log_err()  { printf '[ERROR] %s %s\n' "$(_ts)" "$*" >&2; }

require_cmd() {
  local missing=0 c
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      log_err "required command not found: $c"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || exit 1
}

env_short() {
  case "$1" in
    staging)    echo "stg" ;;
    production) echo "prod" ;;
    *) log_err "env_short: unknown env '$1'"; return 1 ;;
  esac
}

kubectl_context_for_env() {
  case "$1" in
    staging)    echo "aa-stg" ;;
    production) echo "aa-prod" ;;
    argocd)     echo "aa-argocd" ;;
    *) log_err "kubectl_context_for_env: unknown env '$1'"; return 1 ;;
  esac
}

# Resolve base URL: --base-url > <ENV>_BASE_URL env var > error.
resolve_base_url() {
  local env="$1" flag_value="${2:-}"
  if [ -n "$flag_value" ]; then
    echo "$flag_value"
    return 0
  fi
  local var_name
  case "$env" in
    staging)    var_name="STAGING_BASE_URL" ;;
    production) var_name="PRODUCTION_BASE_URL" ;;
    *) log_err "resolve_base_url: unknown env '$env'"; return 1 ;;
  esac
  local val="${!var_name:-}"
  if [ -z "$val" ]; then
    log_err "base URL not set: pass --base-url or export $var_name (e.g. staging.arogyam.example.com)"
    return 1
  fi
  echo "$val"
}

resolve_project_id() {
  if [ -n "${GCP_PROJECT_ID:-}" ]; then
    echo "$GCP_PROJECT_ID"
    return 0
  fi
  local p
  p=$(gcloud config get-value project 2>/dev/null || true)
  if [ -z "$p" ] || [ "$p" = "(unset)" ]; then
    log_err "GCP project id not resolvable: export GCP_PROJECT_ID or run 'gcloud config set project <id>'"
    return 1
  fi
  echo "$p"
}

gcloud_token() { gcloud auth print-access-token; }

get_secret() {
  local name="$1"
  local project
  project=$(resolve_project_id)
  gcloud secrets versions access latest --secret="$name" --project="$project"
}

validate_env() {
  case "$1" in
    staging|production) return 0 ;;
    *) log_err "invalid --env '$1' (must be staging|production)"; return 1 ;;
  esac
}

validate_tenant() {
  if [[ ! "$1" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]]; then
    log_err "invalid --tenant '$1' (lowercase alnum + dashes, 2-63 chars)"
    return 1
  fi
}

# parse_common_args expects "$@" from the script. Recognised flags:
#   --env --tenant --base-url --source-url --output --partition-id
#   --user --password --client --token --input --source-context --source-namespace
#   --no-verify
parse_common_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --env)              ENV="$2"; shift 2 ;;
      --tenant)           TENANT="$2"; shift 2 ;;
      --base-url)         BASE_URL="$2"; shift 2 ;;
      --source-url)       SOURCE_URL="$2"; shift 2 ;;
      --output)           OUTPUT_DIR="$2"; shift 2 ;;
      --input)            INPUT_DIR="$2"; shift 2 ;;
      --partition-id)     PARTITION_ID="$2"; shift 2 ;;
      --user)             USER_ARG="$2"; shift 2 ;;
      --password)         PASSWORD_ARG="$2"; shift 2 ;;
      --client)           CLIENT_ARG="$2"; shift 2 ;;
      --token)            TOKEN_ARG="$2"; shift 2 ;;
      --types)            TYPES_ARG="$2"; shift 2 ;;
      --start-offset)     START_OFFSET="$2"; shift 2 ;;
      --source-context)   SOURCE_CONTEXT="$2"; shift 2 ;;
      --source-namespace) SOURCE_NAMESPACE="$2"; shift 2 ;;
      --no-verify)        NO_VERIFY=1; shift ;;
      --skip-realm-create) SKIP_REALM_CREATE=1; shift ;;
      --since)            SINCE="$2"; shift 2 ;;
      --until)            UNTIL="$2"; shift 2 ;;
      --force)            FORCE=1; shift ;;
      --parallelism)      PARALLELISM="$2"; shift 2 ;;
      --bundle)           BUNDLE_PATH="$2"; shift 2 ;;
      --realm-export)     REALM_EXPORT="$2"; shift 2 ;;
      --admin-password)   ADMIN_PASSWORD_ARG="$2"; shift 2 ;;
      -h|--help)          _show_help_if_set; exit 0 ;;
      *) log_err "unknown arg: $1"; return 1 ;;
    esac
  done
}

_show_help_if_set() {
  if declare -F show_help >/dev/null 2>&1; then
    show_help
  else
    echo "no --help defined for this script" >&2
  fi
}
