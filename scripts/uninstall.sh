#!/usr/bin/env bash
# Remove codex-router and restore normal ChatGPT-only Codex.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/env.sh"
ensure_app_closed
if [ -x "$ROUTER_DIR/bin/uninstall" ]; then
  "$ROUTER_DIR/bin/control" signed-routing off || true
  "$ROUTER_DIR/bin/uninstall" || c_warn "router uninstall reported an error"
fi
if grep -qE '^\s*(openai_base_url|model_catalog_json)\s*=' "$CONFIG_TOML"; then
  c_warn "Router keys are still in config.toml:"; show_router_keys
  latest=$(ls -1t "${CONFIG_TOML}".*.pre-codex-router.bak 2>/dev/null | head -n1 || true)
  if [ -n "$latest" ] && confirm "Restore the pre-router backup $latest?"; then
    cp -p "$CONFIG_TOML" "${CONFIG_TOML}.$(date +%Y-%m-%dT%H-%M-%S).pre-uninstall.bak"
    cp -p "$latest" "$CONFIG_TOML"; c_ok "Restored."
  fi
else c_ok "config.toml is clean."; fi
pf=$(login_profile_file)
if grep -qF "$PROFILE_MARK_BEGIN" "$pf" 2>/dev/null && confirm "Also stop sharing the Codex home with VS Code (remove CODEX_HOME from $pf)?"; then
  python3 - "$pf" "$PROFILE_MARK_BEGIN" "$PROFILE_MARK_END" <<'PY'
import sys,re
p,b,e=sys.argv[1:]; s=open(p).read()
s=re.sub(r'\n?'+re.escape(b)+r'.*?'+re.escape(e)+r'\n?','\n',s,flags=re.S); open(p,'w').write(s)
PY
  c_ok "removed"
fi
if [ -n "$(bash "$TOOLS_DIR/scripts/codex-override.sh" get 2>/dev/null)" ] && confirm "Remove the VS Code Codex override (chatgpt.cliExecutable)?"; then
  bash "$TOOLS_DIR/scripts/codex-override.sh" vscode-off
fi
if [ -f /etc/systemd/system/codex-ipc-bind.service ] && confirm "Remove the Codex IPC bind mount service (sudo)?"; then
  sudo systemctl disable --now codex-ipc-bind.service; sudo rm -f /etc/systemd/system/codex-ipc-bind.service; sudo systemctl daemon-reload; c_ok "removed"
fi
launch_app
