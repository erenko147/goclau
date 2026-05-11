# Claude Code for Godot 4

A Godot 4 editor plugin that connects Claude AI to your game development workflow — **no API key required**, just a Claude premium account with Claude Code installed.

## How it works

```
Godot Editor Plugin  ──HTTP──►  Python Bridge Server  ──subprocess──►  claude CLI
```

The plugin talks to a small local Python server, which runs the `claude` CLI (Claude Code). Claude Code authenticates with your Claude premium account, so you never need to manage API keys.

## Requirements

- **Godot 4.x**
- **Python 3.8+** (for the bridge server)
- **Claude Code CLI** — install from https://claude.ai/code and run `claude login` once

## Setup

### 1. Install the plugin

Copy the `addons/claude_code_godot/` folder into your Godot project's `addons/` directory.

In Godot: **Project → Project Settings → Plugins** → enable **GoClau**.

### 2. Start the bridge server

Click the **Start Server** button inside the GoClau panel — it automatically launches `addons/claude_code_godot/server/claude_server.py` using Python in the background.

If auto-start fails (Python not in PATH), start it manually:

**Linux / macOS:**
```bash
python3 addons/claude_code_godot/server/claude_server.py
```

**Windows:**
```
python addons\claude_code_godot\server\claude_server.py
```

The server runs on `http://127.0.0.1:9876` by default.

### 3. Use it

A **Claude** tab appears at the bottom of the Godot editor.

| Feature | How to use |
|---|---|
| **Chat** | Type in the input box, press **Send** or **Ctrl+Enter** |
| **Include current script** | Check "Current Script" before sending |
| **Include scene info** | Check "Scene Info" before sending |
| **Run a one-off task** | Use the "Run task:" bar at the bottom |
| **New conversation** | Click **New Chat** to reset context |

## Server API

The Python server exposes a minimal REST API on `http://127.0.0.1:9876`:

| Endpoint | Method | Body | Description |
|---|---|---|---|
| `/status` | GET | — | Health check |
| `/chat` | POST | `{message, context?}` | Send a chat message |
| `/reset` | POST | — | Reset conversation history |
| `/run` | POST | `{command, cwd?}` | Run a one-shot Claude task |

## Project structure

```
addons/claude_code_godot/
  plugin.cfg          # Godot plugin metadata
  plugin.gd           # EditorPlugin entry point
  claude_panel.gd     # Bottom-panel chat UI
  claude_client.gd    # HTTP client wrapper
  server/
    claude_server.py  # Python bridge server (no extra dependencies)
```

## Troubleshooting

**"claude CLI not found"** — Make sure Claude Code is installed and `claude` is in your `PATH`. Run `claude login` in a terminal first.

**Server won't start from "Start Server" button** — Start it manually: `cd server && python3 claude_server.py`

**Responses are very slow** — Normal for complex requests. Claude Code processes each message as a full CLI invocation.

**Conversation context is lost** — Click "New Chat" only when you want to reset. Context is preserved across messages within the same session.
