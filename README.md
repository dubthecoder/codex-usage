# Codex Usage Watcher

A small macOS menu-bar watcher for local Codex usage.

It reads Codex's saved `/status` events from `~/.codex/sessions/**/*.jsonl`, including:

- current window usage percent
- weekly window usage percent
- reset timestamps
- plan type
- latest turn token count
- session token count

The app does not read or display auth tokens. It only scans saved session event lines whose payload type is `token_count`.

## Build

```bash
./scripts/build-app.sh
```

The built app is written to:

```text
build/Codex Usage Watcher.app
```

## Run

```bash
open "build/Codex Usage Watcher.app"
```

It opens a compact OpenAI-themed window and also appears as a menu-bar item. The menu-bar number shows Codex's current `/status` usage percent.

## Verify Data Parsing

```bash
"build/Codex Usage Watcher.app/Contents/MacOS/CodexUsageWatcher" --snapshot
```
