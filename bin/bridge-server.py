#!/usr/bin/python3
"""Mac side of the bridge: lets a cloud session speak and ask questions through this Mac.

Listens on 127.0.0.1 only; a tunnel (Cloudflare Tunnel, ngrok, Tailscale Funnel…) exposes it.
  POST /hook  {command, hook, transcript_tail}  -> runs handfree.js like a local hook would
  POST /mcp   MCP JSON-RPC                       -> relayed to Spokenly on localhost
Every request must carry `Authorization: Bearer <bridge_token>` from ~/.config/claude-speak.json.
"""
import hmac
import json
import os
import subprocess
import sys
import tempfile
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIG_PATH = os.environ.get("HANDFREE_CONFIG") or os.path.expanduser("~/.config/claude-speak.json")
SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "handfree.js")
SPOKENLY_URL = os.environ.get("HANDFREE_SPOKENLY_URL", "http://localhost:51089")
HOOK_COMMANDS = {"", "--question", "--notify", "--session-rules"}
HOOK_TIMEOUT_SECONDS = 110
SPOKENLY_TIMEOUT_SECONDS = 900
# Cloudflare drops a request whose origin stays silent for 100 s; a dictation can last longer.
KEEPALIVE_SECONDS = 15


def load_config():
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


CONFIG = load_config()
TOKEN = CONFIG.get("bridge_token", "")
PORT = int(os.environ.get("HANDFREE_BRIDGE_PORT") or CONFIG.get("bridge_port", 8765))


def run_hook(command, hook, transcript_tail, overrides):
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False, encoding="utf-8") as transcript:
        transcript.writelines(transcript_tail)
    try:
        hook = dict(hook, transcript_path=transcript.name)
        args = ["osascript", "-l", "JavaScript", SCRIPT] + ([command] if command else [])
        env = dict(os.environ, HANDFREE_CONTEXT="cloud", HANDFREE_OVERRIDES=overrides if isinstance(overrides, str) else "")
        result = subprocess.run(args, input=json.dumps(hook), capture_output=True, text=True, timeout=HOOK_TIMEOUT_SECONDS, env=env)
        return result.stdout.strip()
    finally:
        os.unlink(transcript.name)


def ask_spokenly(body):
    request = urllib.request.Request(SPOKENLY_URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=SPOKENLY_TIMEOUT_SECONDS) as response:
        return response.read()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        sys.stderr.write("handfree bridge: " + format % args + "\n")

    def do_GET(self):
        self.reply(405, b"")

    def do_DELETE(self):
        self.reply(405, b"")

    def do_POST(self):
        if not TOKEN or not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + TOKEN):
            return self.reply(401, b"")
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/hook":
            return self.handle_hook(body)
        if self.path == "/mcp":
            return self.handle_mcp(body)
        self.reply(404, b"")

    def handle_hook(self, body):
        try:
            payload = json.loads(body)
        except ValueError:
            return self.reply(400, b"")
        if payload.get("command", "") not in HOOK_COMMANDS:
            return self.reply(400, b"")
        output = run_hook(payload.get("command", ""), payload.get("hook") or {}, payload.get("transcript_tail") or [], payload.get("overrides", ""))
        self.reply(200, output.encode("utf-8"), "text/plain; charset=utf-8")

    def handle_mcp(self, body):
        try:
            message = json.loads(body)
        except ValueError:
            return self.reply(400, b"")
        if message.get("method") != "tools/call":
            answer = ask_spokenly(body)
            return self.reply(200, answer, "application/json") if answer.strip() else self.reply(202, b"")
        self.stream_slow_call(body)

    def stream_slow_call(self, body):
        """A tool call waits for the dictation: answer as an event stream, with keep-alives until it ends."""
        outcome = {}

        def call():
            try:
                outcome["answer"] = ask_spokenly(body)
            except Exception as error:
                outcome["error"] = str(error)

        worker = threading.Thread(target=call)
        worker.start()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        while worker.is_alive():
            worker.join(KEEPALIVE_SECONDS)
            if worker.is_alive():
                self.wfile.write(b": keep-alive\n\n")
                self.wfile.flush()
        if "answer" in outcome:
            data = outcome["answer"]
        else:
            request_id = json.loads(body).get("id")
            data = json.dumps({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": outcome.get("error", "Spokenly failed")}}).encode()
        self.wfile.write(b"event: message\ndata: " + data.strip() + b"\n\n")
        self.wfile.flush()

    def reply(self, status, body, content_type="text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    if not TOKEN:
        sys.exit(f"handfree bridge: no bridge_token in {CONFIG_PATH}, refusing to start")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
