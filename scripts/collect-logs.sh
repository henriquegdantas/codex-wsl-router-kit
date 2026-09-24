#!/usr/bin/env bash
# Copy the latest Codex VS Code extension logs (Remote-WSL server) + environment facts to
# <repo>/logs (git-ignored) so they can be read from Windows. Tokens/keys are redacted.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/env.sh"
out="$TOOLS_DIR/logs/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$out"
redact() { sed -E 's/(sk-|GOCSPX-|1\/\/)[A-Za-z0-9_\-]{8,}/\1<redacted>/g; s#(127\.0\.0\.1:[0-9]+)/[A-Za-z0-9_\-]{16,}#\1/<cap>#g; s/("?(access|refresh|id)_token"?\s*[:=]\s*"?)[^",} ]+/\1<redacted>/g'; }
latest=$(ls -1dt "$HOME"/.vscode-server/data/logs/*/ 2>/dev/null | head -n1)
if [ -n "$latest" ]; then
  echo "server log dir: $latest" > "$out/INFO.txt"
  for f in $(find "$latest" -path '*openai.chatgpt*' -type f) "$latest"/exthost*/exthost.log "$latest"/remoteagent.log; do
    [ -f "$f" ] || continue; rel=${f#"$latest"}; mkdir -p "$out/$(dirname "$rel")"; redact < "$f" > "$out/$rel"
  done
fi
{
  echo "== extension installs (WSL server)"; ls -1d "$HOME"/.vscode-server/extensions/openai.chatgpt-* 2>/dev/null
  echo "== override"; ls -la "$HOME/.local/share/codex-override/" 2>/dev/null; "$HOME/.local/share/codex-override/current/codex" --version 2>&1
  echo "== server-env-setup"; cat "$VSCODE_SERVER_ENV" 2>/dev/null
  echo "== /etc/fstab"; cat /etc/fstab 2>/dev/null
  echo "== codex-ipc-bind"; systemctl status codex-ipc-bind.service --no-pager 2>&1 | head -8
  echo "== vscode server processes"; ps -eo pid,etimes,args | grep -E "vscode-server|codex" | grep -v grep | cut -c1-250
  echo "== server process CODEX_HOME"; for p in $(pgrep -f "\.vscode-server/.*node" 2>/dev/null); do tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -E '^(CODEX_HOME|PATH)=' | sed "s/^/pid $p: /"; done
} > "$out/env.txt" 2>&1
c_ok "Logs saved to: $(wslpath -w "$out" 2>/dev/null || echo "$out")"
