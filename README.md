# SwiftMux

A native macOS app for navigating tmux sessions, plus an optional headless server for remote access from a phone or browser. Built with SwiftUI + SwiftTerm; the server uses Hummingbird.

## Why

When you run multiple AI coding agents (Claude Code, Codex) in parallel tmux sessions, you need fast session switching with rich metadata. Terminal-based solutions (fzf popups, sesh) work but lack the persistent overview and native feel of a real app.

SwiftMux treats tmux sessions as the primary navigation object — not repos, not tabs, not windows.

## Architecture

- **SwiftUI** for the chrome (sidebar, command palette, metadata display)
- **SwiftTerm** (`LocalProcessTerminalView`) for terminal rendering
- **SwiftMuxServer** for optional HTTP/WebSocket remote control
- **tmux-pilot** (`tp ls --json`) for session metadata (repo, status, branch, desc, process)
- One terminal view, reattach on switch (tmux `switch-client` for fast switching)

## Key Features

- Sidebar listing all tmux sessions with metadata (name, repo, status, branch, process, desc)
- Command palette (Cmd-K) with fuzzy search across sessions
- Click or keyboard-navigate to switch sessions instantly
- Session metadata from tmux-pilot (@repo, @status, @branch, @desc)
- Color-coded status indicators (active, idle, done, waiting-human)
- Group-by-repo view option
- Peek mode — preview a session's last N lines without switching to it
- Keyboard-driven: arrow keys to navigate, Enter to switch, Esc to dismiss

## Requirements

- macOS 14+
- tmux
- tmux-pilot (`tp` CLI) — `pipx install tmux-pilot`

## Dependencies

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulator library
- [Hummingbird](https://github.com/hummingbird-project/hummingbird) — HTTP/WebSocket server, used only by `SwiftMuxServer`

## Remote Access

`SwiftMuxServer` exposes session metadata and a browser terminal attached to tmux through a PTY-backed WebSocket.

```bash
# Local only, no auth (default)
swift run SwiftMuxServer

# Bind to all interfaces with a bearer token
SWIFTMUX_HOST=0.0.0.0 SWIFTMUX_PORT=8421 SWIFTMUX_TOKEN=hunter2 \
  swift run SwiftMuxServer
```

Endpoints:

| Method | Path | Purpose |
|---|---|---|
| GET | `/healthz` | Liveness probe |
| GET | `/api/sessions` | List sessions from `tp ls --json`, enriched with git metadata |
| GET | `/api/sessions/:name/peek?lines=N` | Read recent scrollback |
| POST | `/api/sessions/:name/kill` | Kill a tmux session |
| WS | `/ws/sessions/:name` | Attach to `tmux attach -t <name>` |

When launched from the repo root, the server also serves the static PWA in `Web/` at `http://127.0.0.1:8421/`. Override that path with `SWIFTMUX_WEB_ROOT=/path/to/web`.

If `SWIFTMUX_TOKEN` is set and you use the browser client, open `/?token=<token>` once; the PWA stores it locally and uses it for API requests and WebSocket attachment.
