# Codex Usage Watcher

A small macOS menu-bar utility that surfaces local Codex usage at a glance.

It reads Codex's locally-saved `/status` events from `~/.codex/sessions/**/*.jsonl` and per-turn token totals from `~/.codex/log/codex-tui.log`. Surfaced data includes:

- current window usage percent
- weekly window usage percent
- reset timestamps for both windows
- plan type
- last turn and session token totals
- model context window size

The app does not read or display auth tokens. It only scans saved log lines and session event lines whose payload type is `token_count`.

## UI

- **Menu-bar item.** A template SF Symbol (`gauge.with.dots.needle.50percent`) next to the current `/status` percent in monospaced digits. The icon auto-tints with the menu bar.
- **Floating panel.** A HUD-style `NSPanel` (utility window, non-activating, joins all spaces) that follows the system appearance (light/dark). Clicking the menu-bar icon also toggles a transient popover with the same content.
- **Native styling.** Semantic system colors throughout — `.primary` / `.secondary` for text, `Color(nsColor: .separatorColor)` for chrome, and the meter accent escalates green → yellow → red as usage rises.

## Build

```bash
./scripts/build-app.sh
```

The built app is written to:

```text
build/Codex Usage Watcher.app
```

Build requirements: Swift toolchain (Xcode command-line tools), macOS 14+, Apple Silicon (the build script targets `arm64-apple-macosx14.0`).

## Run

```bash
open "build/Codex Usage Watcher.app"
```

On first launch, open Codex and run `/status` at least once so Codex writes a `token_count` event into its session log — otherwise the panel shows "Open Codex /status once to populate usage". The watcher polls both source files every 30 seconds; the refresh button forces an immediate re-read.

## Verify Data Parsing

```bash
"build/Codex Usage Watcher.app/Contents/MacOS/CodexUsageWatcher" --snapshot
```

Prints the parsed values as `key=value` lines and exits — useful for confirming the watcher can see your Codex logs without launching the GUI.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the data flow, file layout, and how the UI is wired to AppKit.
