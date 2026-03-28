# SwiftMux

A native macOS app for navigating tmux sessions. Built with SwiftUI + SwiftTerm.

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
