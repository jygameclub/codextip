#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PROJECT_ROOT/dist/CodexTip.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CodexTip" "$APP/Contents/MacOS/CodexTip"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_ROOT/Sources/CodexTip/Assets/codex-logo.png" "$APP/Contents/Resources/codex-logo.png"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "已构建：$APP"
