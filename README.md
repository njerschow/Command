# Command

A tiny macOS menubar app that shows all your open terminal windows with smart 5-word summaries.

**Press <kbd>⌘</kbd> <kbd>.</kbd> to see every terminal at a glance.**

## Features

- **Smart summaries** — AI-generated descriptions via Claude Haiku, with local heuristics for common cases
- **Rolling context** — summaries remember what you were doing, not just what's on screen now
- **Action required** — green pulse when a terminal needs your attention
- **Instant switching** — click or <kbd>⌘</kbd> <kbd>1</kbd>–<kbd>9</kbd> to jump to any window/tab
- **Battery friendly** — adaptive polling, fingerprint-based change detection, batched AI calls
- **Info popover** — see how each summary was generated, activity history, TTY details
- **Native** — SwiftUI + AppKit, translucent materials, light/dark mode, 688KB binary

## Requirements

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools (to build from source)
- [Claude CLI](https://docs.anthropic.com/en/docs/claude-cli) (optional, for AI summaries)

## Install

### Download

**[Download Command.zip](https://github.com/njerschow/Command/releases/latest/download/Command.zip)** — unzip, drag to Applications.

> [!NOTE]
> macOS may block the app because it's from an unidentified developer. To allow it, go to **System Settings → Privacy & Security**, find the message about Command, and click **Open Anyway**. See [Apple's guide](https://support.apple.com/en-us/102445#openanyway) for details.

### Build from source

```bash
git clone https://github.com/njerschow/Command
cd Command
make app       # creates build/Command.app
make run       # builds and launches
```

## Usage

1. Launch Command — it appears in your menubar as a terminal icon
2. Click the icon or press <kbd>⌘</kbd> <kbd>.</kbd> to see all open terminals
3. Click any row to focus that window/tab
4. Hover to see <kbd>⌘</kbd> <kbd>N</kbd> shortcuts and the info button

### Permissions

On first launch, Command will ask for **Automation** permission to communicate with Terminal.app. Grant it — this is how it reads window titles and tab content.

## How it works

1. **Every 2 seconds**: scans Terminal.app windows via AppleScript for process state
2. **Every 5 minutes**: reads the last 100 lines of each active terminal, normalizes (strips ANSI, spinners, progress bars), and fingerprints for change detection
3. **On change**: tries local heuristics first (SSH, builds, servers, Claude Code). Only ambiguous terminals get sent to Claude Haiku in one batched call
4. **Rolling context**: past summaries are stored so the AI understands the broader task, not just the current screen

## Development

```bash
make dev       # debug build + run
make test      # run test suite (35 tests)
make dist      # release build + zip
make clean     # clean build artifacts
```

## Architecture

```
Sources/
├── main.swift                    # Entry point
├── App/AppDelegate.swift         # Menubar + popover + scanning
├── Models/
│   ├── TerminalWindow.swift      # TerminalApp, Tab, Group, Status
│   ├── TerminalContext.swift      # Summary state per tab
│   └── AppState.swift            # Observable state + MRU ordering
├── Services/
│   ├── TerminalScanner.swift     # Polling coordinator
│   ├── Adapters/TerminalAppAdapter.swift  # AppleScript scanner
│   ├── ContentReader.swift       # Terminal history reader
│   ├── ContentNormalizer.swift   # ANSI/spinner stripping + fingerprinting
│   ├── SummaryManager.swift      # Heuristics + AI summary orchestration
│   ├── WindowFocuser.swift       # Focus window + select tab
│   └── ProcessResolver.swift     # Process detection via ps
├── Views/
│   ├── TerminalListView.swift    # Main popover view
│   ├── TerminalRowView.swift     # Row with summary, status, info
│   ├── StatusDotView.swift       # Animated status indicator
│   └── FeedbackView.swift        # Inline feedback widget
└── Utilities/
    ├── HotkeyManager.swift       # Global ⌘. hotkey
    └── FeedbackSubmitter.swift   # HTTP feedback poster
```

## License

MIT
