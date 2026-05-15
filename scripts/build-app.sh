#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Codex Usage Watcher"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES"
mkdir -p "$ROOT_DIR/build"

swift "$ROOT_DIR/scripts/generate-app-icon.swift" "$RESOURCES/AppIcon.icns"

swiftc \
  -target arm64-apple-macosx14.0 \
  -O \
  -framework AppKit \
  -framework SwiftUI \
  "$ROOT_DIR/Sources/CodexUsageWatcher/main.swift" \
  -o "$MACOS/CodexUsageWatcher"

cp "$ROOT_DIR/Sources/CodexUsageWatcher/Info.plist" "$CONTENTS/Info.plist"

echo "Built $APP_BUNDLE"
