#!/usr/bin/env bash
# export-keycloak.sh — exports a Keycloak realm from the OLD cluster using
# kc.sh (so users + hashed credentials come along) and copies it locally.
# Usage:
#   --tenant <slug>
#   --source-context <kubectl-ctx>     context for the OLD cluster
#   --source-namespace <ns>            namespace where Keycloak is deployed (e.g. keycloak)
#   --output <dir>                     destination directory (realm.json written here)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

KC_DEPLOYMENT="${KC_DEPLOYMENT:-deploy/keycloak}"
KC_BIN="${KC_BIN:-/opt/bitnami/keycloak/bin/kc.sh}"
KC_TMP_PATH="${KC_TMP_PATH:-/tmp/realm.json}"

show_help() {
  cat <<'EOF' >&2
export-keycloak.sh — export a Keycloak realm via kc.sh inside the source pod.

Required:
  --tenant <slug>
  --source-context <ctx>      kubectl context for the OLD cluster
  --source-namespace <ns>     namespace where Keycloak runs (e.g. keycloak)
  --output <dir>              destination directory

Optional env:
  KC_DEPLOYMENT   default: deploy/keycloak
  KC_BIN          default: /opt/bitnami/keycloak/bin/kc.sh
EOF
}

main() {
  parse_common_args "$@"
  require_cmd kubectl

  if [ -z "$TENANT" ] || [ -z "$SOURCE_CONTEXT" ] || [ -z "$SOURCE_NAMESPACE" ] || [ -z "$OUTPUT_DIR" ]; then
    show_help
    exit 2
  fi
  validate_tenant "$TENANT"

  mkdir -p "$OUTPUT_DIR"
  local out_path="${OUTPUT_DIR%/}/realm.json"

  log_info "exec kc.sh export in context=$SOURCE_CONTEXT ns=$SOURCE_NAMESPACE deploy=$KC_DEPLOYMENT realm=$TENANT"
  kubectl --context="$SOURCE_CONTEXT" -n "$SOURCE_NAMESPACE" \
    exec "$KC_DEPLOYMENT" -- \
    "$KC_BIN" export --realm "$TENANT" --file "$KC_TMP_PATH" --users realm_file >&2

  local pod
  pod=$(kubectl --context="$SOURCE_CONTEXT" -n "$SOURCE_NAMESPACE" \
    get pod -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}')
  if [ -z "$pod" ]; then
    log_err "could not find a keycloak pod in $SOURCE_NAMESPACE"
    exit 1
  fi

  log_info "kubectl cp $pod:$KC_TMP_PATH -> $out_path"
  kubectl --context="$SOURCE_CONTEXT" -n "$SOURCE_NAMESPACE" \
    cp "$pod:$KC_TMP_PATH" "$out_path"

  if [ ! -s "$out_path" ]; then
    log_err "exported realm file is empty: $out_path"
    exit 1
  fi
  log_info "wrote $out_path ($(wc -c <"$out_path" | tr -d ' ') bytes)"
}

main "$@"
