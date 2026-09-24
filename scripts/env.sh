#!/usr/bin/env bash
# Shared settings for the codex-wsl-router-kit scripts (sourced, not run).
# The router runs INSIDE WSL and targets the Windows Codex home (C:\Users\<you>\.codex),
# because the ChatGPT/Codex desktop app is set to "Run Codex in WSL".

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root

# Optional overrides: copy config.example.env to config.env (git-ignored) and edit.
# shellcheck disable=SC1091
[ -f "$TOOLS_DIR/config.env" ] && . "$TOOLS_DIR/config.env"

# Windows user profile folder, as a WSL path (e.g. /mnt/c/Users/alice)
if [ -z "${WIN_HOME:-}" ]; then
  _wp=$( (cd /mnt/c 2>/dev/null || cd /; cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r' | tail -n1) )
  [ -n "$_wp" ] && WIN_HOME=$(wslpath -u "$_wp" 2>/dev/null)
  # fallback: the only real user folder under /mnt/c/Users
  if [ -z "${WIN_HOME:-}" ]; then
    _c=$(find /mnt/c/Users -mindepth 1 -maxdepth 1 -type d ! -iname public ! -iname default ! -iname 'default user' ! -iname 'all users' ! -iname defaultapppool 2>/dev/null)
    [ "$(printf '%s\n' "$_c" | grep -c .)" = 1 ] && WIN_HOME=$_c
    unset _c
  fi
  unset _wp
fi
if [ -z "${WIN_HOME:-}" ] || [ ! -d "$WIN_HOME" ]; then
  echo "codex-wsl-router-kit: couldn't detect your Windows user folder. Set WIN_HOME in $TOOLS_DIR/config.env" >&2
  exit 1
fi
WIN_USER="${WIN_USER:-$(basename "$WIN_HOME")}"
WSL_DISTRO="${WSL_DISTRO:-${WSL_DISTRO_NAME:-Ubuntu}}"

# Codex desktop config lives on Windows; the WSL runtime reads it through /mnt/c.
export CODEX_HOME="${CODEX_HOME_OVERRIDE:-$WIN_HOME/.codex}"
# Router state (API keys, merged catalog) stays on the Linux filesystem so the
# router's 0600 file permissions actually work (they can't on /mnt/c).
export CODEX_ROUTER_STATE_DIR="${HOME}/.local/state/codex-router"
export MODEL_ROUTER_STATE_DIR="${CODEX_ROUTER_STATE_DIR}"
export MODEL_ROUTER_TARGET="codex"

# Scripts launched from Windows (.cmd -> wsl.exe) get a non-interactive shell, so
# ~/.bashrc never runs and nvm/uv aren't on PATH. Find them explicitly.
_add_path() { [ -d "$1" ] && case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac; return 0; }
for _d in "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.volta/bin" "$HOME/.bun/bin"; do _add_path "$_d"; done
_node_ok() { command -v node >/dev/null 2>&1 && [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -ge 22 ]; }
if ! _node_ok; then
  # nvm / fnm installs: newest Node version directory
  _nbin=$(ls -1d "${NVM_DIR:-$HOME/.nvm}"/versions/node/v*/bin "$HOME"/.local/share/fnm/node-versions/v*/installation/bin 2>/dev/null | sort -V | tail -n1 || true)
  [ -n "$_nbin" ] && _add_path "$_nbin"
fi
if ! _node_ok || ! command -v uv >/dev/null 2>&1; then
  # Last resort: ask an interactive shell (runs ~/.bashrc) where node/uv are.
  for _tool in node uv; do
    if ! command -v "$_tool" >/dev/null 2>&1 || { [ "$_tool" = node ] && ! _node_ok; }; then
      _p=$(bash -ic "command -v $_tool" 2>/dev/null </dev/null | tail -n1 || true)
      [ -n "$_p" ] && [ -x "$_p" ] && _add_path "$(dirname "$_p")"
    fi
  done
fi
export PATH
unset _d _nbin _tool _p

ROUTER_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/codex-router"
CONFIG_TOML="${CODEX_HOME}/config.toml"

# The desktop app ships its own Linux Codex binary under .codex/bin/wsl/<hash>/codex
# and the hash changes on every app update, so always pick the newest one.
resolve_codex_bin() {
  local newest
  newest=$(ls -1t "${CODEX_HOME}"/bin/wsl/*/codex 2>/dev/null | head -n1 || true)
  if [ -n "$newest" ] && [ -x "$newest" ]; then
    export CODEX_BIN="$newest"
  elif command -v codex >/dev/null 2>&1; then
    export CODEX_BIN="$(command -v codex)"
  else
    unset CODEX_BIN
  fi
}
resolve_codex_bin

c_ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m[!!]\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m[xx]\033[0m %s\n' "$*"; }
c_step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

confirm() { # confirm "question" -> returns 0 on yes
  local reply; read -r -p "$1 [y/N] " reply; [[ "$reply" =~ ^[YySs]$ ]]
}

app_running() {
  tasklist.exe /FI "IMAGENAME eq ChatGPT.exe" /NH 2>/dev/null | grep -qi "ChatGPT.exe"
}

ensure_app_closed() {
  if app_running; then
    c_warn "The ChatGPT/Codex desktop app is running. It must be fully closed (Codex only reads the model list at startup)."
    if confirm "Close it now?"; then
      taskkill.exe /IM ChatGPT.exe >/dev/null 2>&1 || true
      sleep 3
      app_running && taskkill.exe /F /IM ChatGPT.exe >/dev/null 2>&1 || true
      sleep 2
    fi
    if app_running; then c_err "App is still running. Quit it from the tray icon (Exit) and run again."; exit 1; fi
  fi
  c_ok "Desktop app is closed."
}

launch_app() {
  local appid
  appid=$(powershell.exe -NoProfile -Command "(Get-StartApps | Where-Object { \$_.AppID -like 'OpenAI.Codex*' } | Select-Object -First 1).AppID" 2>/dev/null | tr -d '\r' || true)
  if [ -n "$appid" ]; then
    explorer.exe "shell:AppsFolder\\${appid}" >/dev/null 2>&1 || true
    c_ok "Launching the desktop app."
  else
    c_warn "Couldn't find the app automatically; open ChatGPT from the Start menu."
  fi
}

# Show the two router-managed root keys from config.toml.
show_router_keys() {
  grep -E '^\s*(openai_base_url|model_catalog_json|model_provider)\s*=' "$CONFIG_TOML" \
    | sed -E 's#(https?://127\.0\.0\.1:[0-9]+)/[^"]*#\1/<capability>#' || true
}

# VS Code (Windows) settings + the Codex extension, which runs Codex in WSL and asks
# a login shell for ${CODEX_HOME:-$HOME/.codex} to decide which config to use.
VSCODE_SETTINGS="$WIN_HOME/AppData/Roaming/Code/User/settings.json"
VSCODE_EXT_DIR="$WIN_HOME/.vscode/extensions"
PROFILE_MARK_BEGIN="# >>> codex-router: shared Codex home >>>"
PROFILE_MARK_END="# <<< codex-router: shared Codex home <<<"

# The file bash -l actually reads (first one that exists wins, like bash itself).
login_profile_file() {
  local f; for f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    [ -f "$f" ] && { echo "$f"; return; }; done
  echo "$HOME/.profile"
}
login_shell_codex_home() { env -u CODEX_HOME -u CODEX_ROUTER_STATE_DIR -u MODEL_ROUTER_STATE_DIR bash -lc 'printf %s "${CODEX_HOME:-$HOME/.codex}"' 2>/dev/null </dev/null; }

# Newest Codex Linux binary bundled with the VS Code extension.
vscode_codex_bin() {
  # Windows-side install (local windows) or the WSL server install (Remote-WSL windows)
  ls -1dt "$VSCODE_EXT_DIR"/openai.chatgpt-*/bin/linux-x86_64/codex \
          "$HOME"/.vscode-server/extensions/openai.chatgpt-*/bin/linux-x86_64/codex 2>/dev/null | head -n1 || true
}

# Remote-WSL windows: the VS Code server (and the Codex extension inside it) takes its env
# from ~/.vscode-server/server-env-setup, not from a login shell.
VSCODE_SERVER_ENV="$HOME/.vscode-server/server-env-setup"
vscode_server_codex_home() { # what the server would see
  env -u CODEX_HOME -u CODEX_ROUTER_STATE_DIR -u MODEL_ROUTER_STATE_DIR sh -c '[ -f "$1" ] && . "$1"; printf %s "${CODEX_HOME:-$HOME/.codex}"' _ "$VSCODE_SERVER_ENV" 2>/dev/null
}
# Newest Codex extension log inside the WSL VS Code server
vscode_remote_codex_log() {
  ls -1t "$HOME"/.vscode-server/data/logs/*/exthost*/openai.chatgpt/*.log 2>/dev/null | head -n1 || true
}

# The Linux Codex extension creates a Unix socket at $CODEX_HOME/ipc/ipc.sock. /mnt/c (drvfs)
# can't hold Unix sockets (ENOTSUP), so we bind-mount a Linux directory over that folder.
IPC_SRC="$HOME/.local/state/codex-ipc"
IPC_DST="$CODEX_HOME/ipc"
ipc_socket_ok() { python3 - "$IPC_DST" <<'PY' 2>/dev/null
import socket,os,sys
p=os.path.join(sys.argv[1],".codex-router-socktest")
try:
    os.unlink(p)
except OSError: pass
s=socket.socket(socket.AF_UNIX)
try:
    s.bind(p); s.close(); os.unlink(p); print("ok")
except Exception as e: print("no:",e)
PY
}

# Linux Codex (VS Code extension / WSL CLI) cannot open the SQLite state that the Windows
# runtime left in the shared home ("failed to initialize sqlite state runtime"), and SQLite on
# /mnt/c is unreliable anyway. So those clients keep SQLite state on the Linux filesystem.
# Kept separate from the desktop app's own state so different Codex versions never migrate
# the same database. (Thread files in $CODEX_HOME/sessions are still shared.)
LINUX_SQLITE_HOME="$HOME/.local/state/codex-sqlite"

# Write/replace the managed env block in a shell file (~/.profile, server-env-setup).
write_env_block() {
  local f=$1; mkdir -p "$(dirname "$f")"; touch "$f"
  python3 - "$f" "$PROFILE_MARK_BEGIN" "$PROFILE_MARK_END" "$CODEX_HOME" "$LINUX_SQLITE_HOME" <<'PY'
import sys,re
p,b,e,h,sq=sys.argv[1:]
s=open(p).read()
# ":-" keeps any value a parent process already set (e.g. the desktop app's own runtime)
block=f'{b}\nexport CODEX_HOME="${{CODEX_HOME:-{h}}}"\nexport CODEX_SQLITE_HOME="${{CODEX_SQLITE_HOME:-{sq}}}"\n{e}'
if b in s: s=re.sub(re.escape(b)+r'.*?'+re.escape(e), lambda m: block, s, flags=re.S)
else: s=s.rstrip('\n')+'\n\n'+block+'\n'
open(p,'w').write(s)
PY
}
login_shell_var() { env -u CODEX_HOME -u CODEX_SQLITE_HOME -u CODEX_ROUTER_STATE_DIR -u MODEL_ROUTER_STATE_DIR bash -lc "printf %s \"\${$1:-}\"" 2>/dev/null </dev/null; }
vscode_server_var() { env -u CODEX_HOME -u CODEX_SQLITE_HOME sh -c "[ -f \"\$1\" ] && . \"\$1\"; printf %s \"\${$1:-}\"" _ "$VSCODE_SERVER_ENV" 2>/dev/null; }

# Start an app-server exactly like the extension does and ask for auth status.
# Prints "ok" or the error. Uses the real shared home, like VS Code would.
appserver_smoke() { # bin codex_home sqlite_home
  local bin=$1 home=$2 sq=$3 out
  local msgs='{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-router-check","version":"0"}}}
{"method":"initialized"}
{"id":2,"method":"getAuthStatus","params":{"includeToken":false,"refreshToken":false}}'
  out=$( (printf '%s\n' "$msgs"; sleep 8) | (cd /tmp && env CODEX_HOME="$home" ${sq:+CODEX_SQLITE_HOME="$sq"} RUST_LOG=error timeout 12 "$bin" -c features.code_mode_host=true app-server --analytics-default-enabled) 2>&1 )
  if grep -q '"id":2,"result"' <<<"$out"; then echo ok
  else echo "$(grep -a -m1 -E '^Error|error' <<<"$out" | sed -E 's/\x1b\[[0-9;]*m//g' | cut -c1-200)"; fi
}
