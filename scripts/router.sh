#!/usr/bin/env bash
# Run any codex-router command against the Windows Codex home, e.g.:
#   bash router.sh status | doctor | doctor --fix | providers | provider-key deepseek set | update
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/env.sh"
[ -d "$ROUTER_DIR/bin" ] || { c_err "codex-router is not installed ($ROUTER_DIR). Run 'Install Codex Router.cmd' first."; exit 1; }
cmd="${1:-status}"; shift || true
case "$cmd" in
  control|refresh-catalog|test-model|discover-models|curate-models)
           exec "$ROUTER_DIR/bin/$cmd" "$@" ;;
  *)       exec "$ROUTER_DIR/bin/model-router" codex "$cmd" "$@" ;;
esac
