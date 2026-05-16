# Architecture

A single-binary AppKit + SwiftUI menu-bar app. All source lives in one file: [Sources/CodexUsageWatcher/main.swift](Sources/CodexUsageWatcher/main.swift). No external dependencies; the build is a direct `swiftc` invocation that links `AppKit` and `SwiftUI`.

## Repository layout

```
.
├── README.md
├── ARCHITECTURE.md            (this file)
├── Sources/CodexUsageWatcher/
│   ├── main.swift             data layer + SwiftUI views + AppDelegate
│   └── Info.plist             bundle metadata (bundle id, version, icon)
├── scripts/
│   ├── build-app.sh           compiles, assembles .app bundle, generates icon
│   └── generate-app-icon.swift  produces Resources/AppIcon.icns
└── build/
    └── Codex Usage Watcher.app   build output (gitignored)
```

## Layers

The single source file is organized as four layers, top to bottom:

1. **Domain models** — plain Swift structs for the parsed shape of the data.
2. **Reader / store** — file I/O and parsing, plus an `ObservableObject` that polls.
3. **SwiftUI views** — the panel UI rendered into an `NSPopover`.
4. **AppDelegate** — wires the status item and popover; bridges the data store into AppKit.

### 1. Domain models

| Type | Purpose |
| --- | --- |
| `TokenUsage` | Input / cached / output / reasoning / total token counts. |
| `CodexTurn` | One parsed turn from `codex-tui.log` (date, thread id, model, effort, usage). |
| `CodexRateLimit` | One rate-limit window (`usedPercent`, `windowMinutes`, `resetsAt`). |
| `CodexStatus` | Aggregated `/status` snapshot: primary + secondary limits, plan type, model context window. |
| `UsageSnapshot` | What the UI consumes — aggregates for today / 24h / 7d, plus the latest `CodexStatus`. |

### 2. Reader / store

**`CodexUsageReader`** owns the I/O and parsing logic. Two independent inputs:

- **`~/.codex/log/codex-tui.log`** — a plain text TUI log. The reader tails the last 20 MB (`maxBytes`), drops the first partial line, then per line:
  - Regex-extracts `codex.turn.token_usage.<field>=<int>` pairs (`tokenRegex`).
  - Pulls `thread.id`, `model`, and `codex.turn.reasoning_effort` via simple `fieldValue` lookups.
  - Parses the leading ISO-8601 timestamp.
  - Lines whose `total_tokens` is `0` are dropped.

  The resulting `[CodexTurn]` feeds the time-bucketed summaries (today, last 24h, last 7d, per-model, per-effort).

- **`~/.codex/sessions/**/*.jsonl`** — JSONL session event files. The reader:
  - Walks the directory with `FileManager.enumerator`, sorts files by modification time (newest first), and looks at up to the 60 most recent.
  - Tails the last 8 MB of each file, scans lines in reverse, and stops at the first line containing `"type":"token_count"`.
  - Decodes the line as a `StatusEvent` and returns a `CodexStatus`.

  Only the most recent `token_count` event survives — that's what the meters and stat rows render.

**`UsageStore`** is the single `ObservableObject` the UI binds to. It calls `reader.read()` immediately, then on a 30-second `Timer`, republishing a fresh `UsageSnapshot` each tick.

### 3. SwiftUI views

All in [main.swift](Sources/CodexUsageWatcher/main.swift) under the third section. The shape is:

```
UsagePanel
├── header          gauge symbol + title + relative "Updated …" + refresh button
├── UsageMeter      "Current" — percent, capsule meter, reset countdown
├── UsageMeter      "Weekly"  — same shape, secondary window
└── compactStats    Plan / Last turn / Session / Context window rows
```

- `UsageMeter` picks its bar color (`Color(nsColor: .systemGreen/.systemYellow/.systemRed)`) from `clampedPercent` so the visual urgency tracks usage.
- All chrome uses semantic colors (`.primary`, `.secondary`, `.tertiary`, `Color(nsColor: .separatorColor / .quaternaryLabelColor)`). There is no custom palette.
- The background is a single `NSVisualEffectView` (`material: .hudWindow`, blending behind the window) via the `VisualEffectBackground` `NSViewRepresentable`.

### 4. AppDelegate

`AppDelegate` owns three AppKit objects:

| Object | Configuration |
| --- | --- |
| `NSStatusItem` | Variable-length, template SF Symbol `gauge.with.dots.needle.50percent`, attributed title using `NSFont.monospacedDigitSystemFont` so the percent doesn't jitter. Action: `togglePopover`. |
| `NSPopover` | `behavior = .transient`, hosts `UsagePanel`, and includes Refresh and Quit controls in the panel header. |

A `Combine` `sink` on `store.$snapshot` re-renders the menu-bar title whenever a fresh snapshot is published.

## Lifecycle

1. `main` (bottom of [main.swift](Sources/CodexUsageWatcher/main.swift)) checks for the `--snapshot` CLI flag — if present, runs one read, prints `key=value` lines, exits. Otherwise it instantiates `NSApplication`, attaches `AppDelegate`, sets `.accessory` activation policy, and runs.
2. `applicationDidFinishLaunching` starts the store (begins polling), configures the status item, and prepares the popover without showing it automatically.
3. The store publishes a new `UsageSnapshot` every 30 s; the menu-bar title updates via the Combine sink, and the popover updates via SwiftUI's normal `@ObservedObject` re-render path.
4. `applicationShouldHandleReopen` re-shows the popover when the user re-launches a running instance from Finder.

## CLI

```
CodexUsageWatcher --snapshot
```

Runs one full `CodexUsageReader.read()` synchronously and prints the parsed snapshot as `key=value` lines (today/24h totals + `/status` fields + latest turn). Useful for sanity-checking parsing without launching the GUI; also handy as a building block for shell scripts.

## Build

`scripts/build-app.sh`:

1. Cleans `build/Codex Usage Watcher.app`.
2. Generates `Resources/AppIcon.icns` via `scripts/generate-app-icon.swift`.
3. Invokes `swiftc -target arm64-apple-macosx14.0 -O` with `AppKit` and `SwiftUI` frameworks, emitting `Contents/MacOS/CodexUsageWatcher`.
4. Copies `Info.plist` into `Contents/`.

There is no `Package.swift` and no Xcode project; the build is intentionally minimal.

## Privacy / what is _not_ read

- No auth tokens, API keys, or message content are read from the JSONL files. Only lines whose payload `type` is `token_count` are decoded; everything else is skipped.
- No network calls. All data is local.
- The 20 MB / 8 MB tail caps mean very large logs are sampled, not fully loaded.
