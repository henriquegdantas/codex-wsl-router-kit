#!/usr/bin/env bash
# Make the Codex VS Code extension use the same Codex home (config, login, threads,
# router) as the desktop app: C:\Users\<you>\.codex
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/env.sh"

c_step "VS Code: 'Run Codex in WSL' setting"
if [ ! -f "$VSCODE_SETTINGS" ]; then c_warn "VS Code settings not found at $VSCODE_SETTINGS (skipping)."
elif grep -qE '"chatgpt\.runCodexInWindowsSubsystemForLinux"\s*:\s*true' "$VSCODE_SETTINGS"; then c_ok "already on"
else
  cp -p "$VSCODE_SETTINGS" "${VSCODE_SETTINGS}.$(date +%Y-%m-%dT%H-%M-%S).bak"
  if grep -qE '"chatgpt\.runCodexInWindowsSubsystemForLinux"' "$VSCODE_SETTINGS"; then
    sed -i -E 's/("chatgpt\.runCodexInWindowsSubsystemForLinux"\s*:\s*)false/\1true/' "$VSCODE_SETTINGS"
  else
    sed -i -E '0,/\{/s//{\n  "chatgpt.runCodexInWindowsSubsystemForLinux": true,/' "$VSCODE_SETTINGS"
  fi
  grep -qE '"chatgpt\.runCodexInWindowsSubsystemForLinux"\s*:\s*true' "$VSCODE_SETTINGS" \
    && c_ok "turned on (backup saved next to settings.json)" || { c_err "couldn't set it; turn on 'Run Codex in WSL' in the extension settings"; exit 1; }
fi

c_step "Point WSL login shells at the Windows Codex home"
pf=$(login_profile_file)
[ -f "$pf" ] && ! grep -qF "$PROFILE_MARK_BEGIN" "$pf" && cp -p "$pf" "${pf}.$(date +%Y-%m-%dT%H-%M-%S).bak"
mkdir -p "$LINUX_SQLITE_HOME" && chmod 700 "$LINUX_SQLITE_HOME"
write_env_block "$pf"
got=$(login_shell_codex_home)
[ "$(login_shell_var CODEX_SQLITE_HOME)" = "$LINUX_SQLITE_HOME" ] && c_ok "login shell CODEX_SQLITE_HOME = $LINUX_SQLITE_HOME" || c_err "CODEX_SQLITE_HOME not set by $pf"
if [ "$got" = "$CODEX_HOME" ]; then c_ok "login shell CODEX_HOME = $got  (in $pf)"
else c_err "login shell still resolves CODEX_HOME to '$got'. Check $pf and ~/.bashrc for another CODEX_HOME."; exit 1; fi

c_step "Unix socket folder for the extension (\$CODEX_HOME/ipc)"
# /mnt/c can't hold Unix sockets, so a Linux folder is bind-mounted over $CODEX_HOME/ipc.
# Done by a small systemd service (WSL's own /etc/fstab pass runs too early for /mnt/c paths
# and prints "Processing /etc/fstab with mount -a failed").
UNIT=/etc/systemd/system/codex-ipc-bind.service
if grep -qF "$IPC_DST none bind" /etc/fstab 2>/dev/null; then
  sudo cp -p /etc/fstab "/etc/fstab.$(date +%Y-%m-%dT%H-%M-%S).bak"
  sudo sed -i "\\#codex-router: Unix sockets for Codex IPC#d; \\#$IPC_DST none bind#d" /etc/fstab && c_ok "removed the old /etc/fstab entry"
fi
mkdir -p "$IPC_SRC" && chmod 700 "$IPC_SRC"; mkdir -p "$IPC_DST"
if [ ! -f "$UNIT" ] || ! grep -qF "$IPC_DST" "$UNIT"; then
  sudo tee "$UNIT" >/dev/null <<UNITEOF
[Unit]
Description=codex-router: bind-mount a Linux folder over $IPC_DST (Unix sockets for Codex IPC)
After=local-fs.target
RequiresMountsFor=/mnt/c

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'mkdir -p "$IPC_SRC" "$IPC_DST"; mountpoint -q "$IPC_DST" || mount --bind "$IPC_SRC" "$IPC_DST"'
ExecStop=/bin/sh -c 'mountpoint -q "$IPC_DST" && umount "$IPC_DST" || true'

[Install]
WantedBy=multi-user.target
UNITEOF
  sudo systemctl daemon-reload
fi
sudo systemctl enable --now codex-ipc-bind.service >/dev/null 2>&1 || c_err "could not enable codex-ipc-bind.service (see: systemctl status codex-ipc-bind)"
[ "$(ipc_socket_ok)" = ok ] && c_ok "sockets work in $IPC_DST (codex-ipc-bind.service, starts with WSL)" || c_err "still can't create sockets in $IPC_DST: $(ipc_socket_ok)"

c_step "Remote-WSL windows: VS Code server environment"
mkdir -p "$(dirname "$VSCODE_SERVER_ENV")"
[ -f "$VSCODE_SERVER_ENV" ] && ! grep -qF "$PROFILE_MARK_BEGIN" "$VSCODE_SERVER_ENV" && cp -p "$VSCODE_SERVER_ENV" "${VSCODE_SERVER_ENV}.$(date +%Y-%m-%dT%H-%M-%S).bak"
write_env_block "$VSCODE_SERVER_ENV"
got=$(vscode_server_codex_home)
[ "$got" = "$CODEX_HOME" ] && c_ok "server-env-setup CODEX_HOME = $got" || c_err "server-env-setup resolves '$got'"
[ "$(vscode_server_var CODEX_SQLITE_HOME)" = "$LINUX_SQLITE_HOME" ] && c_ok "server-env-setup CODEX_SQLITE_HOME = $LINUX_SQLITE_HOME" || c_err "server-env-setup has no CODEX_SQLITE_HOME"
if pgrep -f "\.vscode-server/.*server-main.js|\.vscode-server/bin/.*/node" >/dev/null 2>&1; then
  c_warn "A VS Code server is running in WSL with the old environment."
  if confirm "Restart it now? (open VS Code windows on WSL will reconnect automatically)"; then
    pkill -f "\.vscode-server/" && sleep 2; c_ok "VS Code server stopped; it restarts when VS Code reconnects."
  else echo "   Close all VS Code WSL windows (the server stops after a few minutes) before testing."; fi
fi

if [ -d "$HOME/.codex" ] && [ ! -L "$HOME/.codex" ]; then
  c_warn "Your old WSL-only Codex home (~/.codex) is left untouched; VS Code will now use the shared one instead."
fi

c_step "Sandbox check for the extension's bundled Codex"
vb=$(vscode_codex_bin)
if [ -n "$vb" ]; then
  d=$(mktemp -d /tmp/codex-check.XXXXXX); chmod 755 "$d"; mkdir -p "$d/h" "$d/w"
  out=$(cd "$d/w" && CODEX_HOME="$d/h" timeout 20 "$vb" sandbox -- sh -c 'echo SANDBOX_OK' 2>&1 || true); rm -rf "$d"
  if grep -q SANDBOX_OK <<<"$out"; then c_ok "sandbox works"
  elif grep -q "mountinfo path is not absolute" <<<"$out"; then
    c_warn "The extension's Codex ($("$vb" --version | awk '{print $NF}')) has the Docker-mount sandbox bug (#46110)."
    if confirm "Point the extension at the newest stable Codex CLI (has the fix; undo any time)?"; then
      bash "$TOOLS_DIR/scripts/codex-override.sh" vscode-on
    fi
  else c_warn "sandbox test failed: $(tail -n1 <<<"$out")"; fi
fi

c_step "Done"
echo "In VS Code: Ctrl+Shift+P -> 'Developer: Reload Window', then pick 'DeepSeek V4.1 Flash (API)' in the Codex model picker."
echo "If it misbehaves later, run 'Check Codex Setup.cmd'."
