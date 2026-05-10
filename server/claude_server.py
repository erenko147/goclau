#!/usr/bin/env python3
"""
Claude Code Godot Bridge Server
Wraps the `claude` CLI so Godot can use Claude via a premium account (no API key needed).
"""

import json
import subprocess
import threading
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

HOST = "127.0.0.1"
DEFAULT_PORT = 9876

conversation_history = []
lock = threading.Lock()

SYSTEM_PROMPT = (
    "You are a helpful assistant embedded in the Godot 4 game engine editor. "
    "You help game developers with GDScript, Godot APIs, scene design, shaders, "
    "and general game development questions. Keep responses concise and practical. "
    "When showing code, always use GDScript unless the user asks for C#."
)


def run_claude(prompt: str, cwd: str | None = None) -> tuple[str, int]:
    """Run claude CLI with a prompt, return (output, returncode)."""
    try:
        result = subprocess.run(
            ["claude", "-p", prompt],
            capture_output=True,
            text=True,
            timeout=120,
            cwd=cwd or os.getcwd(),
        )
        return result.stdout.strip() or result.stderr.strip(), result.returncode
    except FileNotFoundError:
        return (
            "Error: 'claude' CLI not found. "
            "Install Claude Code from https://claude.ai/code and make sure it's in your PATH.",
            1,
        )
    except subprocess.TimeoutExpired:
        return "Error: Claude timed out after 120 seconds.", 1


def build_chat_prompt(message: str, context: str) -> str:
    parts = [SYSTEM_PROMPT, ""]

    if context:
        parts.append(f"=== Context ===\n{context}\n")

    for turn in conversation_history:
        parts.append(f"Human: {turn['user']}")
        parts.append(f"Assistant: {turn['assistant']}")
        parts.append("")

    parts.append(f"Human: {message}")
    parts.append("Assistant:")
    return "\n".join(parts)


class ClaudeHandler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self._send_cors_headers(200)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/status":
            self._respond(200, {"status": "ok", "history_turns": len(conversation_history)})
        else:
            self._respond(404, {"error": "Not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            data = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self._respond(400, {"error": "Invalid JSON"})
            return

        if path == "/chat":
            self._handle_chat(data)
        elif path == "/reset":
            self._handle_reset()
        elif path == "/run":
            self._handle_run(data)
        else:
            self._respond(404, {"error": "Not found"})

    # ------------------------------------------------------------------
    def _handle_chat(self, data: dict):
        message = data.get("message", "").strip()
        if not message:
            self._respond(400, {"error": "message is required"})
            return

        context = data.get("context", "")

        with lock:
            prompt = build_chat_prompt(message, context)
            response, code = run_claude(prompt)

            if code == 0:
                conversation_history.append({"user": message, "assistant": response})

        self._respond(200 if code == 0 else 500, {"response": response})

    def _handle_reset(self):
        with lock:
            conversation_history.clear()
        self._respond(200, {"status": "conversation reset"})

    def _handle_run(self, data: dict):
        command = data.get("command", "").strip()
        if not command:
            self._respond(400, {"error": "command is required"})
            return
        cwd = data.get("cwd") or None
        response, code = run_claude(command, cwd=cwd)
        self._respond(200, {"response": response, "exit_code": code})

    # ------------------------------------------------------------------
    def _respond(self, status: int, payload: dict):
        body = json.dumps(payload).encode()
        self._send_cors_headers(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_cors_headers(self, status: int):
        self.send_response(status)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def log_message(self, fmt, *args):
        print(f"[claude-server] {self.address_string()} - {fmt % args}")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT
    server = HTTPServer((HOST, port), ClaudeHandler)
    print(f"Claude Code Godot server listening on http://{HOST}:{port}")
    print("Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")


if __name__ == "__main__":
    main()
