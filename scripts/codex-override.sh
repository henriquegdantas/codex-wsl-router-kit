#!/usr/bin/env bash
# Temporary workaround for Codex bug #46110 ("mountinfo path is not absolute", triggered by
# Docker/snap namespace mounts). The fix shipped in Codex CLI 0.156.0, but the desktop app and
# VS Code extension (26.917.x) still bundle 0.155.0-alpha.16.3.
# This lets the VS Code extension use the newest stable Codex CLI via its official
# "chatgpt.cliExecutable" setting, until OpenAI ships an extension update.
#   bash codex-override.sh status | vscode-on | vscode-off | update
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/env.sh"

# Installed next to the Codex home on the Windows drive (C:\Users\<you>\.codex\codex-override\<version>).
# Works for both Remote-WSL windows and local windows with "Run Codex in WSL", survives WSL resets,
# and is visible from Windows. Official full package layout: bin/codex + bin/codex-code-mode-host
# (needed by GPT-6 "code mode" models) + codex-resources/bwrap + codex-path/rg.
# A bare codex binary is NOT enough.
OVR_DIR="$CODEX_HOME/codex-override"
LEGACY_OVR_DIR="$HOME/.local/share/codex-override"   # used by earlier versions of this kit
installed_bin() { # newest complete install
  local d; d=$(ls -1d "$OVR_DIR"/[0-9]*/ 2>/dev/null | sort -V | tail -n1); d=${d%/}
  [ -n "$d" ] && [ -x "$d/bin/codex" ] && [ -x "$d/bin/codex-code-mode-host" ] && echo "$d/bin/codex"
}
URL="${CODEX_PACKAGE_URL:-https://github.com/openai/codex/releases/latest/download/codex-package-x86_64-unknown-linux-musl.tar.gz}"

ver() { [ -x "$1" ] && "$1" --version 2>/dev/null | awk '{print $NF}'; }
sandbox_test() { # prints ok/bug/fail
  local bin=$1 d; d=$(mktemp -d /tmp/codex-check.XXXXXX); chmod 755 "$d"; mkdir -p "$d/h" "$d/w"
  local out; out=$(cd "$d/w" && CODEX_HOME="$d/h" timeout 20 "$bin" sandbox -- sh -c 'echo SANDBOX_OK' 2>&1); rm -rf "$d"
  if grep -q SANDBOX_OK <<<"$out"; then echo ok; elif grep -q "mountinfo path is not absolute" <<<"$out"; then echo bug; else echo "fail: $(tail -n1 <<<"$out")"; fi
}
settings_json_get() { python3 - "$VSCODE_SETTINGS" <<'PY'
import re,sys,json
s=open(sys.argv[1],encoding='utf-8',newline='').read()
m=re.search(r'"chatgpt\.cliExecutable"\s*:\s*("(?:[^"\\]|\\.)*")',s)
print(json.loads(m.group(1)) if m else "")
PY
}
settings_json_set() { # $1 = value, or empty to remove the setting
  cp -p "$VSCODE_SETTINGS" "${VSCODE_SETTINGS}.$(date +%Y-%m-%dT%H-%M-%S).bak"
  python3 - "$VSCODE_SETTINGS" "$1" <<'PY'
import re,sys,json
p,val=sys.argv[1],sys.argv[2]
s=open(p,encoding='utf-8',newline='').read()
eol='\r\n' if '\r\n' in s else '\n'
s=re.sub(r'^[ \t]*"chatgpt\.cliExecutable"\s*:\s*"(?:[^"\\]|\\.)*"\s*,?[ \t]*\r?\n','',s,flags=re.M)
if val:
    line='  "chatgpt.cliExecutable": '+json.dumps(val)+','
    s=re.sub(r'\{', lambda m: '{'+eol+line, s, count=1)
open(p,'w',encoding='utf-8',newline='').write(s)
PY
}

status() {
  c_step "Codex versions and sandbox"
  local d v; d="${CODEX_BIN:-}"; v=$(vscode_codex_bin)
  [ -n "$d" ] && echo "   desktop bundled : $(ver "$d")  sandbox: $(sandbox_test "$d")"
  [ -n "$v" ] && echo "   vscode bundled  : $(ver "$v")  sandbox: $(sandbox_test "$v")"
  local o; o=$(installed_bin)
  [ -n "$o" ] && echo "   override        : $(ver "$o")  sandbox: $(sandbox_test "$o")  GPT-6 tools: $(bash "$TOOLS_DIR/scripts/tooltest.sh" "$o" code)  ($o)"
  local cur; cur=$(settings_json_get)
  if [ -n "$cur" ]; then echo "   VS Code chatgpt.cliExecutable = $cur"; else echo "   VS Code uses its bundled Codex (no override)"; fi
  if [ -n "$cur" ] && [ -n "$v" ] && [ "$(sandbox_test "$v")" = ok ]; then
    c_ok "The extension's bundled Codex works now: you can remove the override with: bash $0 vscode-off"; fi
}

download() {
  c_step "Download the latest stable Codex package for Linux (~140 MB)"
  local tmp; tmp=$(mktemp -d)
  curl -fL --progress-bar -o "$tmp/pkg.tgz" "$URL" || { c_err "download failed"; rm -rf "$tmp"; return 1; }
  mkdir -p "$tmp/pkg" && tar -xzf "$tmp/pkg.tgz" -C "$tmp/pkg" || { c_err "couldn't extract the package"; rm -rf "$tmp"; return 1; }
  if [ ! -x "$tmp/pkg/bin/codex" ] || [ ! -x "$tmp/pkg/bin/codex-code-mode-host" ]; then
    c_err "unexpected package layout (bin/codex or bin/codex-code-mode-host missing)"; rm -rf "$tmp"; return 1
  fi
  local v; v=$(ver "$tmp/pkg/bin/codex")
  # test in a staging folder first, so a failed test never touches the working install
  local stage="$OVR_DIR/.staging-$v"
  rm -rf "$stage"; mkdir -p "$OVR_DIR"; mv "$tmp/pkg" "$stage"; rm -rf "$tmp"
  c_step "Test Codex $v before switching to it"
  local t1 t2 t3
  t1=$(sandbox_test "$stage/bin/codex")
  t2=$(bash "$TOOLS_DIR/scripts/tooltest.sh" "$stage/bin/codex" code)
  t3=$(bash "$TOOLS_DIR/scripts/tooltest.sh" "$stage/bin/codex" direct)
  echo "   sandbox: $t1 | GPT-style (code mode) tool call: $t2 | DeepSeek-style tool call: $t3"
  if [ "$t1" != ok ] || [ "$t2" != ok ] || [ "$t3" != ok ]; then
    c_err "Codex $v failed a test; keeping the previous version (tested copy left in $stage)."; return 1
  fi
  rm -rf "${OVR_DIR:?}/$v"; mv "$stage" "$OVR_DIR/$v"
  # remove older versions, a leftover symlink, and the old WSL-home location of earlier kit versions
  for old in "$OVR_DIR"/*; do [ "$old" = "$OVR_DIR/$v" ] || rm -rf "$old"; done
  rm -rf "$LEGACY_OVR_DIR"
  c_ok "installed Codex $v at $OVR_DIR/$v/bin/codex"
}

case "${1:-status}" in
  status) status ;;
  get) [ -f "$VSCODE_SETTINGS" ] && settings_json_get ;;
  update) download && { b=$(installed_bin); cur=$(settings_json_get); if [ -n "$cur" ] && [ "$cur" != "$b" ]; then settings_json_set "$b"; c_ok "VS Code switched to $b"; fi; status; } ;;
  vscode-on)
    # install if there is no complete package yet (bin/codex + bin/codex-code-mode-host)
    b=$(installed_bin); [ -n "$b" ] || { download && b=$(installed_bin); } || exit 1
    [ -n "$b" ] || { c_err "no usable Codex package in $OVR_DIR"; exit 1; }
    # a plain Linux path works in Remote-WSL windows and in local windows with "Run Codex in WSL"
    [ "$(settings_json_get)" = "$b" ] || settings_json_set "$b"
    [ "$(settings_json_get)" = "$b" ] && c_ok "VS Code uses Codex $(ver "$b") ($b)" || { c_err "couldn't update settings.json"; exit 1; }
    echo "In VS Code: Ctrl+Shift+P -> 'Developer: Reload Window'. Undo any time: bash $0 vscode-off" ;;
  vscode-off)
    settings_json_set ""; [ -z "$(settings_json_get)" ] && c_ok "VS Code back to its bundled Codex. Reload the window." ;;
  *) echo "usage: $0 status|vscode-on|vscode-off|update|get"; exit 1 ;;
esac
