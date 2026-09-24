#!/usr/bin/env bash
# Refresh codex-router's merged model catalog (run after Codex app updates, or
# when routed/native models are missing from the picker).
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/env.sh"

[ -x "$ROUTER_DIR/bin/refresh-catalog" ] || { c_err "codex-router isn't installed at $ROUTER_DIR. Run setup.sh first."; exit 1; }
cd "$ROUTER_DIR"

c_step "Close the desktop app"
ensure_app_closed

c_step "Codex binary"
if [ -n "${CODEX_BIN:-}" ]; then c_ok "$CODEX_BIN"; else c_warn "No Linux Codex binary found; open the app once so it installs one, then retry."; fi

c_step "Router service"
if systemctl --user is-active --quiet codex-router.service; then c_ok "running"
else
  c_warn "not running, starting it"
  "$ROUTER_DIR/bin/start" || true
  sleep 3
  systemctl --user is-active --quiet codex-router.service && c_ok "running" || c_err "service didn't start. See: journalctl --user -u codex-router -n 50"
fi

c_step "Refresh catalog"
"$ROUTER_DIR/bin/refresh-catalog"
c_ok "Catalog republished."

c_step "Check config.toml"
show_router_keys
cat_path=$(grep -E '^\s*model_catalog_json\s*=' "$CONFIG_TOML" | sed -E 's/^[^=]*=\s*"?([^"]*)"?.*/\1/' | tail -n1 || true)
if [ -z "$cat_path" ]; then c_err "model_catalog_json is missing from config.toml. Run: bash $TOOLS_DIR/scripts/router.sh doctor --fix"
elif [[ "$cat_path" =~ ^[A-Za-z]:[\\/] ]]; then c_err "Catalog path is a Windows path ($cat_path); the WSL runtime can't read it. Run: bash $TOOLS_DIR/scripts/router.sh doctor --fix"
elif [ -f "$cat_path" ]; then c_ok "Catalog OK: $cat_path ($(grep -o '"slug"' "$cat_path" | wc -l) models)"
else c_err "Catalog file not found: $cat_path"; fi

c_step "Health check"
if "$ROUTER_DIR/bin/doctor" >"/tmp/codex-router-doctor.txt" 2>&1; then c_ok "doctor: all checks passed"
else
  c_warn "doctor found problems:"; grep -E 'FAIL|WARN' /tmp/codex-router-doctor.txt || tail -n 20 /tmp/codex-router-doctor.txt
  echo "Try: bash $TOOLS_DIR/scripts/router.sh doctor --fix"
fi

c_step "VS Code"
echo "If VS Code is open: Ctrl+Shift+P -> 'Developer: Reload Window' to pick up the new model list."
[ -n "$(bash "$TOOLS_DIR/scripts/codex-override.sh" get 2>/dev/null)" ] && bash "$TOOLS_DIR/scripts/codex-override.sh" status

c_step "Reopen app"
launch_app
