#!/usr/bin/env python3
"""Tiny local stand-in for the Responses API, used by scripts/tooltest.sh.

It lets a Codex binary run one real turn without any API cost: the first request is
answered with a code-mode `exec` tool call that runs a shell command through
`tools.exec_command`; the follow-up request (carrying the tool output) is answered
with a plain "DONE" message and the tool output is saved for inspection.

usage: mock_responses.py <port> <workdir> [code|direct]

"code" mimics GPT-6 models (tool_mode = code_mode_only, needs codex-code-mode-host);
"direct" mimics routed models such as DeepSeek (plain exec_command function tool).
"""
import http.server
import json
import sys

PORT = int(sys.argv[1])
WORKDIR = sys.argv[2]
MODE = sys.argv[3] if len(sys.argv) > 3 else "code"
JS = 'const r = await tools.exec_command({cmd: "echo CODEX_TOOLTEST_OK"}); text(r);'


def sse(event, data):
    return f"event: {event}\ndata: {json.dumps(data)}\n\n".encode()


class Handler(http.server.BaseHTTPRequestHandler):
    n = 0

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        try:
            req = json.loads(self.rfile.read(length))
        except Exception:
            req = {}
        Handler.n += 1
        items = [i for i in req.get("input", []) if isinstance(i, dict)]
        outputs = [i for i in items if str(i.get("type", "")).endswith("_output")]
        if outputs:
            with open(f"{WORKDIR}/tool_output.json", "w") as f:
                json.dump(outputs[-1], f)
            item = {"type": "message", "id": "msg_1", "role": "assistant", "status": "completed",
                    "content": [{"type": "output_text", "text": "DONE", "annotations": []}]}
        elif MODE == "direct":
            item = {"type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "exec_command",
                    "arguments": json.dumps({"cmd": "echo CODEX_TOOLTEST_OK"}), "status": "completed"}
        else:
            item = {"type": "custom_tool_call", "id": "ctc_1", "call_id": "call_1",
                    "name": "exec", "input": JS, "status": "completed"}
        rid = f"resp_{Handler.n}"
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        self.wfile.write(sse("response.created", {"type": "response.created", "response": {"id": rid}}))
        self.wfile.write(sse("response.output_item.done",
                             {"type": "response.output_item.done", "output_index": 0, "item": item}))
        self.wfile.write(sse("response.completed", {"type": "response.completed", "response": {
            "id": rid, "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}}))
        self.wfile.flush()


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
