#!/usr/bin/env bash
# Workaround helper for Codex bug #46110: "error building bubblewrap command: mountinfo path
# is not absolute". Codex 0.155.x (bundled in desktop app / VS Code 26.917.x) rejects namespace
# mounts (Docker container netns, snapd) in /proc/self/mountinfo. Fixed in Codex CLI 0.156.0+.
# Not related to codex-router.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/env.sh"
bad() { awk '$4 !~ /^\// {print}' /proc/self/mountinfo; }

c_step "Mount entries that trigger the bug"
if [ -z "$(bad)" ]; then c_ok "None right now, so the sandbox should work. (Starting Docker containers brings them back.)"; exit 0; fi
bad | awk '{print "   " $5 "  (" $(NF-2) ")"}'
n_docker=$(bad | awk '$5 ~ "^/run/docker/netns/"' | wc -l)
snap_mnts=$(bad | awk '$5 ~ "^/run/snapd/ns/" {print $5}')

if [ -n "$snap_mnts" ]; then
  c_step "snapd namespace mounts"
  if confirm "Unmount the snapd ones (sudo; snapd recreates them only if a snap runs)?"; then
    for m in $snap_mnts; do sudo umount "$m" && c_ok "unmounted $m" || c_err "could not unmount $m"; done
  fi
fi

if [ "$n_docker" -gt 0 ]; then
  c_step "Docker: $n_docker running container network namespaces"
  echo "These can't be safely removed while containers run. Options:"
  echo "  1) VS Code: use the newest Codex CLI (has the fix) via the extension's cliExecutable setting"
  echo "  2) Stop all running Docker containers now (sandbox works until you start containers again)"
  echo "  3) Do nothing: wait for a desktop/VS Code update (check with 'Check Codex Setup.cmd')"
  read -r -p "Choose [1/2/3]: " opt
  case "$opt" in
    1) bash "$TOOLS_DIR/scripts/codex-override.sh" vscode-on ;;
    2) docker ps --format '   {{.Names}}  ({{.Image}})'
       # shellcheck disable=SC2046  # one container id per word
       confirm "Stop all of these?" && docker stop $(docker ps -q) >/dev/null && c_ok "stopped. Restart later with: docker start <name>" ;;
    *) echo "OK, nothing changed." ;;
  esac
fi
echo
echo "Desktop app: until OpenAI ships the update, Codex can still ask you to approve running a"
echo "command outside the sandbox when it hits this error."
