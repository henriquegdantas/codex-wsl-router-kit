#!/usr/bin/env bash
# End-to-end tool test for a Codex binary, without any API cost or real account:
# runs one turn against a local mock model that uses GPT-6-style "code mode"
# (tool_mode = code_mode_only), which needs `codex-code-mode-host` next to the binary,
# and runs `echo` through the sandboxed shell (bubblewrap).
# "direct" mode mimics routed models (DeepSeek etc.): plain exec_command, no code mode.
# Prints "ok" or the failure. usage: tooltest.sh <codex-binary> [code|direct]
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/env.sh"
bin=${1:?usage: tooltest.sh <codex-binary> [code|direct]}; mode=${2:-code}
[ -x "$bin" ] || { echo "binary not found: $bin"; exit 1; }

d=$(mktemp -d /tmp/codex-tooltest.XXXXXX); chmod 755 "$d"; mkdir -p "$d/home" "$d/sqlite" "$d/work"
cleanup() { [ -n "${mp:-}" ] && kill "$mp" 2>/dev/null; rm -rf "$d"; }
trap cleanup EXIT
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')

# model entry: copy a code_mode_only model from the Codex model cache, fall back to a minimal one
python3 - "$CODEX_HOME/models_cache.json" "$d/catalog.json" "$mode" <<'PY'
import json, sys
src, dst, mode = sys.argv[1:]
model = None
try:
    for m in json.load(open(src)).get("models", []):
        if isinstance(m, dict) and m.get("tool_mode") == "code_mode_only":
            model = dict(m); break
except Exception:
    pass
if model is None:
    model = {"slug": "x", "display_name": "x", "tool_mode": "code_mode_only", "shell_type": "shell_command",
             "visibility": "list", "supported_in_api": True, "context_window": 200000, "priority": 1,
             "supported_reasoning_levels": [], "default_reasoning_level": "medium",
             "apply_patch_tool_type": "freeform", "truncation_policy": {"mode": "tokens", "limit": 10000},
             "supports_parallel_tool_calls": False, "input_modalities": ["text"]}
if mode == "direct":
    model.pop("tool_mode", None)   # routed models: codex-router strips tool_mode
model["slug"] = "codex-tooltest"; model["display_name"] = "tooltest"
json.dump({"models": [model]}, open(dst, "w"))
PY
cat > "$d/home/config.toml" <<CFG
model = "codex-tooltest"
model_provider = "tooltest"
model_catalog_json = "$d/catalog.json"
approval_policy = "never"
sandbox_mode = "workspace-write"
[model_providers.tooltest]
name = "tooltest"
base_url = "http://127.0.0.1:$port/v1"
wire_api = "responses"
supports_websockets = false
[features]
code_mode_host = true
CFG

python3 "$TOOLS_DIR/scripts/lib/mock_responses.py" "$port" "$d" "$mode" & mp=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do (echo > /dev/tcp/127.0.0.1/"$port") 2>/dev/null && break; sleep 0.3; done

{
  echo '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-tooltest","version":"0"}}}'
  echo '{"method":"initialized"}'
  echo "{\"id\":2,\"method\":\"thread/start\",\"params\":{\"cwd\":\"$d/work\"}}"
  for _ in $(seq 1 40); do grep -q '"thread":{"id"' "$d/out.txt" 2>/dev/null && break; sleep 0.25; done
  tid=$(grep -o '"thread":{"id":"[^"]*' "$d/out.txt" | head -n1 | cut -d'"' -f6)
  echo "{\"id\":3,\"method\":\"turn/start\",\"params\":{\"threadId\":\"$tid\",\"input\":[{\"type\":\"text\",\"text\":\"tooltest\"}]}}"
  for _ in $(seq 1 80); do grep -q '"method":"turn/completed"' "$d/out.txt" 2>/dev/null && break; sleep 0.25; done
} | (cd "$d/work" && env CODEX_HOME="$d/home" CODEX_SQLITE_HOME="$d/sqlite" RUST_LOG=error \
       timeout 40 "$bin" -c features.code_mode_host=true app-server) > "$d/out.txt" 2>&1

if [ -f "$d/tool_output.json" ] && grep -q CODEX_TOOLTEST_OK "$d/tool_output.json"; then echo ok
elif [ -f "$d/tool_output.json" ]; then echo "tool failed: $(python3 -c 'import json,sys;print(str(json.load(open(sys.argv[1])).get("output"))[:220])' "$d/tool_output.json")"
else echo "no tool result: $(grep -a -m1 -i -E 'error|warning' "$d/out.txt" | sed -E 's/\x1b\[[0-9;]*m//g' | cut -c1-220)"; fi
