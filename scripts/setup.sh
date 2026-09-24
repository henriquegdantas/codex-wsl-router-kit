#!/usr/bin/env bash
# One-time install of codex-router inside WSL, pointed at the Windows Codex home.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/env.sh"

c_step "Preflight"
grep -qi microsoft /proc/version || { c_err "Run this inside WSL, not Windows."; exit 1; }
[ "$(id -u)" -ne 0 ] || { c_err "Don't run as root/sudo; run as your normal WSL user."; exit 1; }
[ -f "$CONFIG_TOML" ] || { c_err "Codex config not found at $CONFIG_TOML"; exit 1; }

missing=0
if [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; then c_ok "systemd is running (needed for the background service)."
else
  c_err "systemd is not enabled in this WSL distro. Fix, then re-run:"
  echo "    printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf"
  echo "    (then in PowerShell:)  wsl --shutdown"
  missing=1
fi
for cmd in git curl; do
  if command -v $cmd >/dev/null; then c_ok "$cmd found"; else c_err "$cmd missing:  sudo apt update && sudo apt install -y $cmd"; missing=1; fi
done
if command -v node >/dev/null; then
  nv=$(node -p 'process.versions.node'); IFS=. read -r nmaj nmin _ <<<"$nv"
  if [ "$nmaj" -gt 22 ] || { [ "$nmaj" -eq 22 ] && [ "$nmin" -ge 19 ]; }; then c_ok "node $nv"
  else c_err "node $nv is too old (need 22.19+, 24 LTS recommended). With nvm:  nvm install 24 && nvm alias default 24"; missing=1; fi
else c_err "node missing. Install Node 24 LTS (e.g. via nvm: https://github.com/nvm-sh/nvm)"; missing=1; fi
if command -v uv >/dev/null; then c_ok "uv found"
elif python3 -c 'import venv, ensurepip' >/dev/null 2>&1; then c_ok "python3 with venv found"
else
  c_warn "uv isn't installed inside WSL (a Windows uv.exe doesn't count: the router runs in Linux)."
  if confirm "Install uv inside WSL now with the official installer (no sudo, goes to ~/.local/bin)?" \
     && curl -LsSf https://astral.sh/uv/install.sh | sh \
     && export PATH="$HOME/.local/bin:$PATH" && command -v uv >/dev/null; then
    c_ok "uv installed: $(uv --version)"
  else
    c_err "Need uv or python3-venv in WSL:  curl -LsSf https://astral.sh/uv/install.sh | sh   (or: sudo apt install -y python3-venv)"; missing=1
  fi
fi
if [ -n "${CODEX_BIN:-}" ]; then c_ok "Codex CLI for WSL: $CODEX_BIN"
else c_err "No Linux Codex binary found under $CODEX_HOME/bin/wsl. Open the desktop app once (WSL mode) so it installs it."; missing=1; fi
[ "$missing" -eq 0 ] || { c_err "Fix the items above and run this script again. Nothing was changed."; exit 1; }

if grep -qE '^\s*(openai_base_url|model_catalog_json)\s*=' "$CONFIG_TOML"; then
  c_warn "config.toml already has openai_base_url/model_catalog_json:"; show_router_keys
  confirm "Continue anyway? (the router refuses to overwrite user-owned values)" || exit 1
fi

c_step "Close the desktop app"
ensure_app_closed

c_step "Back up config.toml"
backup="${CONFIG_TOML}.$(date +%Y-%m-%dT%H-%M-%S).pre-codex-router.bak"
cp -p "$CONFIG_TOML" "$backup"
c_ok "Saved $backup"

c_step "Install codex-router (official installer, guided)"
echo "When asked for providers, pick DeepSeek and paste your API key (input is hidden)."
echo "You can add more providers later with:  bash $TOOLS_DIR/scripts/router.sh provider-key <provider> set"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL https://raw.githubusercontent.com/duolahypercho/codex-router/main/install.sh -o "$tmp/install.sh"
if ! sh "$tmp/install.sh" --target codex --guided --no-tray; then
  c_err "Installer failed. Your config backup is at: $backup"
  echo "To undo:  bash $TOOLS_DIR/scripts/uninstall.sh"
  exit 1
fi

c_step "Keep the router running when WSL starts"
if loginctl enable-linger "$USER" 2>/dev/null || sudo loginctl enable-linger "$USER"; then c_ok "linger enabled"; else c_warn "Could not enable linger; the service still starts when you open a WSL session."; fi

c_step "Enable routed models while signed in to ChatGPT"
if "$ROUTER_DIR/bin/control" signed-routing on; then c_ok "Signed routing on (GPT models stay on your subscription)."
else c_warn "Could not turn on signed routing. Check 'bash $TOOLS_DIR/scripts/router.sh doctor'."; fi

c_step "Verify"
show_router_keys
cat_path=$(grep -E '^\s*model_catalog_json\s*=' "$CONFIG_TOML" | sed -E 's/^[^=]*=\s*"?([^"]*)"?.*/\1/' | tail -n1 || true)
if [ -n "$cat_path" ] && [ -f "$cat_path" ]; then c_ok "Catalog readable from WSL: $cat_path"
else c_err "model_catalog_json is missing or not readable from WSL ($cat_path). Run the refresh script, or undo with uninstall.sh."; fi
"$ROUTER_DIR/bin/doctor" || c_warn "doctor reported problems (see above)."

c_step "Done"
echo "Next: open the app, start a NEW task, pick 'DeepSeek V4.1 Flash (API)' in the model picker."
echo "After app updates, or if models go missing: double-click 'Refresh Codex Router.cmd'."
confirm "Open the desktop app now?" && launch_app || true
