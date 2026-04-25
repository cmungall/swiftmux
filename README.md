# SwiftMux

A native macOS app for navigating tmux sessions, plus an optional headless server for remote access from a phone or any browser. Built with SwiftUI + SwiftTerm; the server uses Hummingbird.

## Why

When you run multiple AI coding agents (Claude Code, Codex) in parallel tmux sessions, you need fast session switching with rich metadata. Terminal-based solutions (fzf popups, sesh) work but lack the persistent overview and native feel of a real app.

SwiftMux treats tmux sessions as the primary navigation object — not repos, not tabs, not windows.

## Architecture

- **SwiftUI** for the chrome (sidebar, command palette, metadata display)
- **SwiftTerm** (`LocalProcessTerminalView`) for terminal rendering
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
- [Hummingbird](https://github.com/hummingbird-project/hummingbird) — HTTP/WebSocket server (server target only)

## Remote access (SwiftMuxServer)

`SwiftMuxServer` is a separate executable target that exposes the same session data plus a WebSocket-attached PTY, so you can drive your tmux sessions from a phone browser (PWA), the iPad, or any HTTP client on your tailnet.

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
| GET | `/healthz` | Liveness probe (always unauthenticated) |
| GET | `/api/sessions` | List sessions (`tp ls --json` + git enrichment) |
| GET | `/api/sessions/:name/peek?lines=N` | Last N lines from a session |
| POST | `/api/sessions/:name/kill` | Kill a session |
| WS | `/ws/sessions/:name` | Attach a PTY to `tmux attach -t <name>` |

WebSocket protocol:

- Client → server: text frames are written as input bytes to the PTY (use this for keystrokes); binary frames likewise. A text frame parsed as JSON with `{"type":"resize","rows":R,"cols":C}` resizes the PTY.
- Server → client: binary frames carrying raw PTY output bytes.

For exposure beyond the loopback interface, prefer Tailscale (bind to your tailnet IP) rather than punching firewall holes. The bearer-token middleware is a backstop.

### Web client (PWA)

A vanilla-JS client lives in `Web/`. When `SwiftMuxServer` starts in the repo root it serves the directory as static files, so opening `http://<your-mac>:8421/` in any browser gives you the sidebar + xterm.js terminal.

- Mobile-first layout with a slide-in sidebar and a row of helper keys (Esc, Tab, ^C/^D/^Z/^L, arrows, `|`, `~`).
- Fuzzy search, status-color dots, group-by-repo, just like the macOS app.
- `manifest.webmanifest` + a small service worker — on iOS Safari, Share → "Add to Home Screen" gives an app icon and full-screen launch with no Safari chrome.

xterm.js, xterm-addon-fit, and their CSS load from jsDelivr on first visit; the service worker caches them for offline reuse. No build step.

To override the static root: `SWIFTMUX_WEB_ROOT=/some/other/path swift run SwiftMuxServer`.
