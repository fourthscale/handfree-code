#!/usr/bin/python3
"""Mac side of the bridge: lets a cloud session speak and ask questions through this Mac.

Listens on 127.0.0.1 only; a tunnel (Cloudflare Tunnel, ngrok, Tailscale Funnel…) exposes it.
  POST /hook  {command, hook, transcript_tail}  -> runs handfree.js like a local hook would
  POST /mcp   MCP JSON-RPC                       -> relayed to the Handfree Code app on localhost: the dictation tool only
  POST /ping                                     -> "handfree-bridge": the public address reaches this bridge
Every request must carry `Authorization: Bearer <bridge_token>` from ~/.config/handfree-code.json.
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

CONFIG_PATH = os.environ.get("HANDFREE_CONFIG") or next(
    (p for p in map(os.path.expanduser, ("~/.config/handfree-code.json", "~/.config/claude-speak.json")) if os.path.exists(p)),
    os.path.expanduser("~/.config/handfree-code.json"))  # the second: its name before 0.3.2
SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "handfree.js")
# Where its service sends stderr (install-bridge.sh).
LOG_PATH = os.environ.get("HANDFREE_BRIDGE_LOG") or os.path.expanduser("~/Library/Logs/handfree-bridge.log")
DICTATION_URL = os.environ.get("HANDFREE_DICTATION_URL", "http://localhost:51290")
HOOK_COMMANDS = {"", "--question", "--guard-question", "--answered", "--prompt-sent", "--notify", "--session-rules"}
# Under cloud-hook.py's own wait for each (itself under the hook's timeout in hooks/hooks.json): --answered reads "the
# rest", which takes minutes; the question's reading stops in time for this (QUESTION_READING_SECONDS in handfree.js).
HOOK_TIMEOUT_SECONDS = {"--answered": 290, "--guard-question": 20, "--prompt-sent": 6}
DEFAULT_HOOK_TIMEOUT_SECONDS = 105
MAX_BODY_BYTES = 64_000_000
DICTATION_TIMEOUT_SECONDS = 900
# What a cloud session may ask the app: its questions. Not the app's own methods (keys pressed, text pasted on this Mac).
MCP_METHODS = {"initialize", "tools/list"}
MCP_TOOLS = {"ask_user_dictation"}
# Cloudflare drops a request whose origin stays silent for 100 s; a dictation can last longer.
KEEPALIVE_SECONDS = 15
# What /ping answers: install-bridge.sh --check tells this bridge from any other server behind the address.
PING_ANSWER = b"handfree-bridge"


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
        try:
            result = subprocess.run(args, input=json.dumps(hook), capture_output=True, text=True, timeout=HOOK_TIMEOUT_SECONDS.get(command, DEFAULT_HOOK_TIMEOUT_SECONDS), env=env)
        except subprocess.TimeoutExpired:
            return ""  # a hook gone over its time says nothing, as Claude Code treats a local one
        return result.stdout.strip()
    finally:
        os.unlink(transcript.name)


def ask_dictation(body):
    request = urllib.request.Request(DICTATION_URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=DICTATION_TIMEOUT_SECONDS) as response:
        return response.read()


def trim_log(path, max_bytes=200_000, kept_lines=500):
    """Past max_bytes, a log keeps only its last lines: it never fills the disk."""
    try:
        if os.path.getsize(path) > max_bytes:
            with open(path, encoding="utf-8", errors="replace") as f:
                kept = f.readlines()[-kept_lines:]
            with open(path, "w", encoding="utf-8") as f:
                f.writelines(kept)
    except OSError:
        pass


def json_object(body):
    """The body as a JSON object, or None: anything else is refused before it can reach the handlers."""
    try:
        value = json.loads(body)
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        sys.stderr.write("handfree bridge: " + format % args + "\n")
        sys.stderr.flush()
        trim_log(LOG_PATH)

    def do_GET(self):
        self.reply(405, b"")

    def do_DELETE(self):
        self.reply(405, b"")

    def do_POST(self):
        given = self.headers.get("Authorization", "")
        if not given.isascii():
            return self.reply(400, b"")
        if not TOKEN or not hmac.compare_digest(given, "Bearer " + TOKEN):
            return self.reply(401, b"")
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return self.reply(400, b"")
        # A transcript's tail can be large (tool results): the bound only stops a length meant to exhaust memory.
        if not 0 <= length <= MAX_BODY_BYTES:
            return self.reply(413, b"")
        body = self.rfile.read(length)
        # A bridge URL set with a trailing slash gives //mcp.
        path = "/" + self.path.strip("/")
        if path == "/hook":
            return self.handle_hook(body)
        if path == "/mcp":
            return self.handle_mcp(body)
        if path == "/ping":
            return self.reply(200, PING_ANSWER)
        self.reply(404, b"")

    def handle_hook(self, body):
        payload = json_object(body)
        command = payload.get("command", "") if payload is not None else None
        if not isinstance(command, str) or command not in HOOK_COMMANDS:
            return self.reply(400, b"")
        hook, tail = payload.get("hook") or {}, payload.get("transcript_tail") or []
        if not isinstance(hook, dict) or not isinstance(tail, list) or not all(isinstance(line, str) for line in tail):
            return self.reply(400, b"")
        output = run_hook(command, hook, tail, payload.get("overrides", ""))
        self.reply(200, output.encode("utf-8"), "text/plain; charset=utf-8")

    def handle_mcp(self, body):
        message = json_object(body)
        if message is None:
            return self.reply(400, b"")
        method = message.get("method") if isinstance(message.get("method"), str) else ""
        params = message.get("params") if isinstance(message.get("params"), dict) else {}
        name = params.get("name") if isinstance(params.get("name"), str) else ""
        if method == "tools/call" and name in MCP_TOOLS:
            return self.stream_slow_call(body)
        if method not in MCP_METHODS and not method.startswith("notifications/"):
            return self.reply(403, b"")
        try:
            answer = ask_dictation(body)
        except (OSError, ValueError):  # the app not running, or not answering
            return self.reply(502, b"")
        self.reply(200, answer, "application/json") if answer.strip() else self.reply(202, b"")

    def stream_slow_call(self, body):
        """A tool call waits for the dictation: answer as an event stream, with keep-alives until it ends."""
        outcome = {}

        def call():
            try:
                outcome["answer"] = ask_dictation(body)
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
            request_id = json_object(body).get("id")
            data = json.dumps({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": outcome.get("error", "the dictation failed")}}).encode()
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
