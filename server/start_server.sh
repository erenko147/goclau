#!/usr/bin/env bash
# Start the Claude Code Godot bridge server.
# Usage: ./start_server.sh [port]   (default port: 9876)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required but not found."
    exit 1
fi

if ! command -v claude &>/dev/null; then
    echo "Warning: 'claude' CLI not found in PATH."
    echo "Install Claude Code from https://claude.ai/code"
fi

exec python3 "$SCRIPT_DIR/claude_server.py" "$@"
