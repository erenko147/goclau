#!/usr/bin/env python3
"""
GoClau Bridge Server
Wraps the `claude` CLI so Godot can use Claude via a Claude premium account.
"""

import json
import os
import re
import subprocess
import sys
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
from typing import List, Optional, Tuple

HOST = "127.0.0.1"
DEFAULT_PORT = 9876

conversation_history = []
lock = threading.Lock()

# ── Prompts ───────────────────────────────────────────────────────────────────

CHAT_SYSTEM = """\
You are a helpful Godot 4 assistant embedded in the editor.

When you want to suggest changes to a file, use this format:

<propose_file path="relative/path/to/file.gd">
complete file content
</propose_file>

The editor will show the user a dialog to approve or reject each proposed change
before anything is written to disk. You may propose multiple files at once.

Keep answers concise and practical. Use GDScript unless asked for C#.\
"""

AGENT_SYSTEM = """\
You are a Godot 4 coding assistant that creates and modifies project files.

Output every file you want to write using this format:

<write_file path="relative/path/from/project/root">
complete file content
</write_file>

Rules:
- Always output the COMPLETE file — never partial or truncated content.
- Paths are relative to the Godot project root (e.g. scripts/player.gd).
- You may write multiple files in one response.
- After the file blocks, briefly explain what you changed and why.
- Use GDScript unless the user asks for C#.\
"""

# ── Regex helpers ─────────────────────────────────────────────────────────────

_PROPOSE_RE = re.compile(r'<propose_file\s+path="([^"]+)">(.*?)</propose_file>', re.DOTALL)
_WRITE_RE   = re.compile(r'<write_file\s+path="([^"]+)">(.*?)</write_file>',   re.DOTALL)
_FENCE_RE   = re.compile(r"^```[^\n]*\n|```$", re.MULTILINE)


def _strip_fences(content: str) -> str:
    return _FENCE_RE.sub("", content).strip()


def _extract_tags(pattern: re.Pattern, text: str) -> List[dict]:
    return [
        {"path": m.group(1).strip(), "content": _strip_fences(m.group(2))}
        for m in pattern.finditer(text)
    ]


def _remove_tags(pattern: re.Pattern, text: str, label: str) -> str:
    return pattern.sub(lambda m: f"[{label}: {m.group(1).strip()}]", text).strip()


# ── Write files ───────────────────────────────────────────────────────────────

def write_files(files: List[dict], base_dir: str) -> List[str]:
    """Write files to disk. Returns list of successfully written relative paths."""
    written = []
    base = os.path.normpath(base_dir)
    for f in files:
        full = os.path.normpath(os.path.join(base, f["path"]))
        if not full.startswith(base):
            print(f"[goclau] Blocked write outside project: {full}")
            continue
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as fp:
            fp.write(f["content"] + "\n")
        written.append(f["path"])
        print(f"[goclau] Wrote: {f['path']}")
    return written


# ── Claude wrappers ───────────────────────────────────────────────────────────

def run_claude(prompt: str, cwd: Optional[str] = None) -> Tuple[str, int]:
    try:
        r = subprocess.run(
            ["claude", "-p", prompt],
            capture_output=True, text=True, timeout=120,
            cwd=cwd or os.getcwd(),
        )
        return r.stdout.strip() or r.stderr.strip(), r.returncode
    except FileNotFoundError:
        return (
            "Error: 'claude' CLI not found. "
            "Install Claude Code from https://claude.ai/code and make sure it's in your PATH.",
            1,
        )
    except subprocess.TimeoutExpired:
        return "Error: Claude timed out after 120 seconds.", 1


def run_claude_agent(command: str, context: str, cwd: str) -> Tuple[str, int, List[str]]:
    """Run task bar: Claude writes files via <write_file> tags, server applies them."""
    parts = [AGENT_SYSTEM, ""]
    if context:
        parts.append(f"=== Project context ===\n{context}\n")
    parts.append(f"Task: {command}")

    raw, code = run_claude("\n".join(parts), cwd=cwd)
    files = _extract_tags(_WRITE_RE, raw)
    written = write_files(files, cwd)
    display = _remove_tags(_WRITE_RE, raw, "wrote")
    return display, code, written


def run_claude_chat(message: str, context: str) -> Tuple[str, int, List[dict]]:
    """Chat: Claude may propose file changes via <propose_file> tags (not auto-written)."""
    parts = [CHAT_SYSTEM, ""]
    if context:
        parts.append(f"=== Context ===\n{context}\n")
    for turn in conversation_history:
        parts.append(f"Human: {turn['user']}")
        parts.append(f"Assistant: {turn['assistant']}")
        parts.append("")
    parts.append(f"Human: {message}")
    parts.append("Assistant:")

    raw, code = run_claude("\n".join(parts))
    proposed = _extract_tags(_PROPOSE_RE, raw)
    display = _remove_tags(_PROPOSE_RE, raw, "proposed")
    return display, code, proposed


# ── Git helpers ───────────────────────────────────────────────────────────────

def git_available(cwd: str) -> bool:
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            capture_output=True, text=True, cwd=cwd,
        )
        return r.returncode == 0
    except Exception:
        return False


def git_diff(cwd: str) -> str:
    try:
        r = subprocess.run(["git", "diff"], capture_output=True, text=True, cwd=cwd)
        return r.stdout
    except Exception:
        return ""


def git_restore(cwd: str) -> Tuple[bool, str]:
    try:
        r = subprocess.run(["git", "restore", "."], capture_output=True, text=True, cwd=cwd)
        return (True, "") if r.returncode == 0 else (False, r.stderr.strip())
    except FileNotFoundError:
        return False, "git not found in PATH."
    except Exception as e:
        return False, str(e)


# ── HTTP handler ──────────────────────────────────────────────────────────────

class ClaudeHandler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self._send_cors_headers(200)
        self.end_headers()

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

        routes = {
            "/chat":   self._handle_chat,
            "/reset":  self._handle_reset,
            "/run":    self._handle_run,
            "/apply":  self._handle_apply,
            "/reject": self._handle_reject,
        }
        handler = routes.get(path)
        if handler:
            handler(data)
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
            display, code, proposed = run_claude_chat(message, context)
            if code == 0:
                conversation_history.append({"user": message, "assistant": display})

        self._respond(200 if code == 0 else 500, {
            "response": display,
            "proposed_writes": proposed,   # [{path, content}, ...] — not yet written
        })

    def _handle_reset(self, data: dict = None):
        with lock:
            conversation_history.clear()
        self._respond(200, {"status": "ok", "reset": True})

    def _handle_run(self, data: dict):
        command = data.get("command", "").strip()
        if not command:
            self._respond(400, {"error": "command is required"})
            return
        cwd     = data.get("cwd") or os.getcwd()
        context = data.get("context", "")

        display, code, written = run_claude_agent(command, context, cwd)

        has_git = git_available(cwd)
        diff    = git_diff(cwd) if has_git else ""

        self._respond(200, {
            "type":          "run",
            "response":      display,
            "exit_code":     code,
            "diff":          diff,
            "has_changes":   bool(diff.strip()) or bool(written),
            "written_files": written,
            "has_git":       has_git,
            "cwd":           cwd,
        })

    def _handle_apply(self, data: dict):
        """Apply proposed chat file writes to disk, return diff."""
        files = data.get("files", [])
        cwd   = data.get("cwd") or os.getcwd()
        if not files:
            self._respond(400, {"error": "files list is required"})
            return

        written = write_files(files, cwd)
        has_git = git_available(cwd)
        diff    = git_diff(cwd) if has_git else ""

        self._respond(200, {
            "status":        "ok",
            "written_files": written,
            "diff":          diff,
            "has_changes":   bool(diff.strip()),
            "has_git":       has_git,
            "cwd":           cwd,
        })

    def _handle_reject(self, data: dict):
        cwd = data.get("cwd") or os.getcwd()
        ok, err = git_restore(cwd)
        if ok:
            self._respond(200, {"status": "ok", "reverted": True})
        else:
            self._respond(500, {"error": err})

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
        print(f"[goclau] {self.address_string()} - {fmt % args}")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT
    server = HTTPServer((HOST, port), ClaudeHandler)
    print(f"GoClau bridge server on http://{HOST}:{port}")
    print("Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")


if __name__ == "__main__":
    main()
