#!/usr/bin/env bash
# Diagnose (and with --fix, repair) the Codex + codex-router + VS Code setup.
# Safe to run any time; without --fix it changes nothing.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/env.sh"
FIX=0; [ "${1:-}" = "--fix" ] && FIX=1
problems=0; fixable=0
fail() { c_err "$*"; problems=$((problems+1)); }
need_fix() { fixable=$((fixable+1)); }
backup_config() { cp -p "$CONFIG_TOML" "${CONFIG_TOML}.$(date +%Y-%m-%dT%H-%M-%S).pre-check-fix.bak"; }
root_val() { # value of a root-level key (before first [table])
  awk -v k="$1" '/^\s*\[/{exit} $0 ~ "^\\s*"k"\\s*=" {sub(/^[^=]*=\s*/,""); gsub(/^"|"$/,""); print; exit}' "$CONFIG_TOML"; }

c_step "1. config.toml is valid"
if python3 -c 'import tomllib' 2>/dev/null; then
  if err=$(python3 -c 'import tomllib,sys;tomllib.load(open(sys.argv[1],"rb"))' "$CONFIG_TOML" 2>&1); then c_ok "parses fine"
  else fail "config.toml is broken TOML: ${err##*: }"; echo "   Restore a backup: ls -t $CODEX_HOME/config.toml.*.bak"; fi
else c_warn "python3 tomllib unavailable; skipping syntax check"; fi

c_step "2. No settings that block ChatGPT sign-in"
before=$problems
for k in forced_login_method preferred_auth_method; do
  if grep -qE "^\s*$k\s*=" "$CONFIG_TOML"; then
    fail "$k is set (this is what caused 'Unable to load sign-in requirements')"; need_fix
    if [ $FIX = 1 ]; then backup_config; sed -i -E "/^\s*$k\s*=/d" "$CONFIG_TOML"; c_ok "removed $k"; fi
  fi
done
[ $problems = "$before" ] && c_ok "none"

c_step "3. Desktop app runs Codex in WSL"
if grep -qE '^\s*runCodexInWindowsSubsystemForLinux\s*=\s*true' "$CONFIG_TOML"; then c_ok "on"
else fail "Desktop 'Run Codex in WSL' is OFF. The router catalog is a Linux path Windows can't read -> the app may fail to load. Turn it back on in the app settings, or run uninstall.sh."; fi

c_step "4. Router entries in config.toml"
prov=$(root_val model_provider); base=$(root_val openai_base_url); cat=$(root_val model_catalog_json)
router_ok=1
[[ "$base" == http://127.0.0.1:* ]] && c_ok "openai_base_url -> local router" || { fail "openai_base_url missing (an update probably rewrote config.toml)"; router_ok=0; }
if [ -z "$cat" ]; then fail "model_catalog_json missing"; router_ok=0
elif [[ "$cat" =~ ^[A-Za-z]:[\\/] ]]; then fail "model_catalog_json is a Windows path ($cat); WSL can't read it"; router_ok=0
elif [ -f "$cat" ]; then c_ok "catalog: $cat"; else fail "catalog file missing: $cat"; router_ok=0; fi
[ "$prov" = "codex-router-signed" ] && c_ok "provider: codex-router-signed (ChatGPT + routed models)" \
  || { fail "model_provider is '${prov:-<default openai>}', not codex-router-signed -> DeepSeek models won't route"; router_ok=0; }
grep -q '^\[model_providers.codex-router-signed\]' "$CONFIG_TOML" || { fail "[model_providers.codex-router-signed] table missing"; router_ok=0; }
if [ $router_ok = 0 ]; then need_fix
  if [ $FIX = 1 ]; then
    backup_config
    "$ROUTER_DIR/bin/doctor" --fix || true
    "$ROUTER_DIR/bin/refresh-catalog" || true
    "$ROUTER_DIR/bin/control" signed-routing on || true
    c_ok "ran router repair (doctor --fix, refresh-catalog, signed-routing on); re-run this check to confirm"
  fi
fi

c_step "5. Router service"
if systemctl --user is-active --quiet codex-router.service 2>/dev/null; then c_ok "running"
else fail "codex-router service not running"; need_fix
  [ $FIX = 1 ] && { "$ROUTER_DIR/bin/start" || true; sleep 3; systemctl --user is-active --quiet codex-router.service && c_ok "started"; }
fi
if [ -n "$base" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${base%/}/health" 2>/dev/null || true); code=${code:-000}
  hostport=$(echo "$base" | cut -d/ -f3)
  [ "$code" != "000" ] && c_ok "router answers on $hostport (HTTP $code)" || fail "router not answering on $hostport"
fi

c_step "6. VS Code extension"
if [ -f "$VSCODE_SETTINGS" ]; then
  grep -qE '"chatgpt\.runCodexInWindowsSubsystemForLinux"\s*:\s*true' "$VSCODE_SETTINGS" && c_ok "'Run Codex in WSL' on" \
    || { fail "VS Code 'Run Codex in WSL' is off -> extension reads the Windows config natively and can break"; need_fix
         [ $FIX = 1 ] && bash "$TOOLS_DIR/scripts/setup-vscode.sh"; }
fi
got=$(login_shell_codex_home)
[ "$got" = "$CODEX_HOME" ] && c_ok "WSL login shell CODEX_HOME -> shared home" \
  || { fail "WSL login shell CODEX_HOME is '$got' (VS Code would use a separate config)"; need_fix
       [ $FIX = 1 ] && bash "$TOOLS_DIR/scripts/setup-vscode.sh"; }

sg=$(vscode_server_codex_home)
[ "$sg" = "$CODEX_HOME" ] && c_ok "Remote-WSL server env (server-env-setup) CODEX_HOME -> shared home" \
  || { fail "Remote-WSL VS Code server would use CODEX_HOME='$sg' (WSL-remote windows get a separate config)"; need_fix
       [ $FIX = 1 ] && bash "$TOOLS_DIR/scripts/setup-vscode.sh"; }
for where in login server; do
  if [ $where = login ]; then v=$(login_shell_var CODEX_SQLITE_HOME); label="WSL login shell"; else v=$(vscode_server_var CODEX_SQLITE_HOME); label="Remote-WSL server env"; fi
  if [ "$v" = "$LINUX_SQLITE_HOME" ]; then c_ok "$label CODEX_SQLITE_HOME -> $v (Linux filesystem)"
  else fail "$label CODEX_SQLITE_HOME is '${v:-unset}': Linux Codex can't open the SQLite state in the Windows home -> 'failed to initialize sqlite state runtime', extension loads forever"; need_fix
       [ $FIX = 1 ] && bash "$TOOLS_DIR/scripts/setup-vscode.sh"; fi
done
ipc=$(ipc_socket_ok)
[ "$ipc" = ok ] && c_ok "Unix sockets work in $IPC_DST" || { fail "extension IPC socket folder unusable ($IPC_DST: ${ipc:-error}) -> extension can hang"; need_fix
  [ $FIX = 1 ] && bash "$TOOLS_DIR/scripts/setup-vscode.sh"; }
cli=$(bash "$TOOLS_DIR/scripts/codex-override.sh" get 2>/dev/null)
if [ -n "$cli" ]; then
  if [[ "$cli" != /* ]]; then fail "chatgpt.cliExecutable is not a Linux path ($cli): Remote-WSL windows can't start it (extension loads forever)"; need_fix
    [ $FIX = 1 ] && bash "$TOOLS_DIR/scripts/codex-override.sh" vscode-on
  elif [ -x "$cli" ]; then c_ok "chatgpt.cliExecutable -> $cli ($("$cli" --version 2>/dev/null | awk '{print $NF}'))"
  else fail "chatgpt.cliExecutable points to a missing file: $cli"; need_fix
    [ $FIX = 1 ] && bash "$TOOLS_DIR/scripts/codex-override.sh" update; fi
fi

c_step "6b. Start Codex exactly like the VS Code extension does"
eff_bin=$(bash "$TOOLS_DIR/scripts/codex-override.sh" get 2>/dev/null); [ -n "$eff_bin" ] || eff_bin=$(vscode_codex_bin)
if [ -x "$eff_bin" ]; then
  r=$(appserver_smoke "$eff_bin" "$(vscode_server_var CODEX_HOME)" "$(vscode_server_var CODEX_SQLITE_HOME)")
  [ "$r" = ok ] && c_ok "app-server ($("$eff_bin" --version | awk '{print $NF}')) starts and answers with the VS Code environment" \
    || fail "app-server with the VS Code environment fails: $r"
else c_warn "no VS Code Codex binary found to test"; fi

c_step "7. Sandbox self-test (desktop + VS Code Codex binaries)"
tmpd=$(mktemp -d /tmp/codex-check.XXXXXX); chmod 755 "$tmpd"  # plain /tmp dir the sandbox helper can reach
vs_override=$(bash "$TOOLS_DIR/scripts/codex-override.sh" get 2>/dev/null)
vs_bin=$(vscode_codex_bin)
if [ -n "$vs_override" ]; then
  ovr_linux="$HOME/.local/share/codex-override/current/codex"
  if [ -x "$ovr_linux" ]; then c_ok "VS Code uses override Codex $("$ovr_linux" --version | awk '{print $NF}') (chatgpt.cliExecutable)"
  else fail "VS Code chatgpt.cliExecutable points to a missing binary ($vs_override)"; need_fix
       [ $FIX = 1 ] && bash "$TOOLS_DIR/scripts/codex-override.sh" update; fi
fi
for pair in "desktop:${CODEX_BIN:-}" "vscode-bundled:$vs_bin" ${vs_override:+"vscode-override:$HOME/.local/share/codex-override/current/codex"}; do
  name=${pair%%:*}; bin=${pair#*:}
  [ -n "$bin" ] && [ -x "$bin" ] || { c_warn "$name: codex binary not found"; continue; }
  ver=$("$bin" --version 2>/dev/null | awk '{print $NF}')
  # isolated, empty CODEX_HOME: tests only the sandbox, never touches your real config
  mkdir -p "$tmpd/home" "$tmpd/work"
  out=$(cd "$tmpd/work" && CODEX_HOME="$tmpd/home" timeout 20 "$bin" sandbox -- sh -c 'echo SANDBOX_OK' 2>&1)
  if grep -q SANDBOX_OK <<<"$out"; then c_ok "$name ($ver): sandbox works"
    [ "$name" = "vscode-bundled" ] && [ -n "$vs_override" ] && c_warn "VS Code's bundled Codex works now; you can drop the override: bash $TOOLS_DIR/scripts/codex-override.sh vscode-off"
  elif grep -q "mountinfo path is not absolute" <<<"$out"; then
    fail "$name ($ver): hits Codex bug #46110 (mountinfo path is not absolute)"
    n=$(awk '$4 !~ /^\// && $5 ~ "^/run/docker/netns/"' /proc/self/mountinfo | wc -l)
    [ "$n" -gt 0 ] && echo "     trigger: $n running Docker container network namespaces. Run 'Fix Codex Sandbox.cmd' for options."
    [ "$name" = "vscode-bundled" ] && [ -n "$vs_override" ] && { problems=$((problems-1)); echo "     (ignored: VS Code is using the override binary)"; }
  else fail "$name ($ver): sandbox failed: $(tail -n1 <<<"$out")"; fi
done
rm -rf "$tmpd"

c_step "7b. /etc/fstab (WSL prints 'Processing /etc/fstab with mount -a failed' if an entry fails)"
act=$(grep -v -E '^\s*(#|$)' /etc/fstab 2>/dev/null)
if [ -z "$act" ]; then c_ok "no active entries"
else echo "$act" | sed 's/^/     /'
  grep -q -E '/mnt/[a-z]/' <<<"$act" && c_warn "entries under /mnt/<drive> fail at WSL boot (mounted before Windows drives); remove them or use a systemd unit"
  grep -q -E '^\s*(LABEL|UUID|PARTUUID)=' <<<"$act" && c_warn "LABEL=/UUID= entries (e.g. cloudimg-rootfs) don't exist inside WSL and make 'mount -a' fail at boot. Not related to Codex; comment them out with: sudo sed -i 's|^\\(LABEL=\\|UUID=\\)|# &|' /etc/fstab"
fi

c_step "8. Latest Codex extension log (Remote-WSL VS Code server)"
lg=$(vscode_remote_codex_log)
if [ -n "$lg" ]; then
  echo "   $lg"
  # only look at what happened since the extension last (re)started Codex
  start=$(grep -a -n "Spawning codex app-server" "$lg" | tail -n1 | cut -d: -f1); start=${start:-1}
  echo "   (since line $start: last Codex start at $(sed -n "${start}p" "$lg" | cut -c1-23))"
  errs=$(tail -n +"$start" "$lg" | grep -a -i -E '\[error\]|ENOENT|EACCES|ENOTSUP|panic|exited with|fatal' | tail -n 8)
  last_err_ts=$(tail -n1 <<<"$errs" | cut -c1-23)
  last_line_ts=$(tail -n1 "$lg" | cut -c1-23)
  if [ -z "$errs" ]; then c_ok "no errors since the last Codex start"
  else
    c_warn "errors since the last Codex start (newest last):"; sed 's/^/     /' <<<"$errs" | cut -c1-240
    [ "$last_err_ts" != "$last_line_ts" ] && echo "     log continued after the last error (latest entry $last_line_ts) - may already be recovered; reload VS Code and re-check"
    first=$(tail -n +"$start" "$lg" | grep -a -n -m1 -i -E '\[error\]|fatal' | cut -d: -f1)
    if [ -n "$first" ]; then
      echo "     --- what happened right before the first error ---"
      tail -n +"$start" "$lg" | head -n "$first" | tail -n 25 | cut -c1-260 | sed 's/^/     /'
    fi
  fi
else echo "   (no Remote-WSL Codex extension log found; local-window logs are in %APPDATA%\\Code\\logs)"; fi

c_step "Summary"
if [ $problems = 0 ]; then c_ok "Everything looks good."
elif [ $FIX = 1 ]; then c_warn "$problems problem(s) found; fixes applied where possible. Run this check again, then fully quit/reopen the app (and reload VS Code)."
else c_warn "$problems problem(s) found ($fixable auto-fixable). Run with --fix  (or double-click 'Fix Codex Setup.cmd')."; fi
