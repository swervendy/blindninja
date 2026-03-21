# Blind Ninja

Native macOS terminal multiplexer for Claude Code sessions. Manage multiple Claude, Deploy, and Shell sessions side-by-side with real-time state detection.

## Quick Start

```bash
swift build
open .build/debug/BlindNinja
```

Production build + install to `/Applications`:

```bash
./build.sh --deploy
```

## Requirements

- macOS 14+
- Swift 5.9+
- [Claude Code CLI](https://claude.ai/claude-code) installed

## Architecture

```
Sources/BlindNinja/
├── App/              AppDelegate, main — multi-window management, menus
├── Models/           SessionInfo, SessionType, AppTheme (6 themes)
├── Managers/         SessionManager, PTYManager, StateDetector, SessionPersistence
├── Views/
│   ├── Sidebar/      Session list, state dots, row views
│   ├── Terminal/     TerminalHostViewController, DrawerViewController, FileEditorView
│   └── Shared/       ProjectPickerPanel, ClickableView
└── Utilities/        ANSI stripping
```

**Key components:**
- **SessionManager** — PTY lifecycle, output buffering, state detection, session CRUD
- **PTYManager** — `forkpty()` wrapper, TIOCSWINSZ resize, process I/O
- **StateDetector** — Parses terminal output to classify sessions as `idle`, `working`, `waiting`, or `blocked`
- **TerminalHostViewController** — SwiftTerm-based terminal display with per-session view pooling
- **DrawerViewController** — Bottom panel for shell tabs

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘N` | New Window |
| `⌘T` | New Claude Session |
| `⌘D` | New Deploy Session |
| `⇧⌘T` | New Shell Tab |
| `⌘W` | Close Session |
| `⌘R` | Rename Session |
| `⌘O` | Open Project |
| `⌘B` | Toggle Sidebar |
| `⌘J` | Toggle Drawer |
| `⌘1-9` | Switch to Session |
| `⇧⌘[` / `⇧⌘]` | Previous / Next Session |
| `⌘+` / `⌘-` / `⌘0` | Zoom In / Out / Reset |

## Dependencies

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — Terminal emulation
