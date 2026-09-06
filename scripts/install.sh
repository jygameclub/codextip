#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_ROOT/scripts/build.sh"
DEST="$HOME/Applications/CodexTip.app"
mkdir -p "$HOME/Applications"
if [ -d "$DEST" ]; then
    # Stop only this exact installed binary before replacing it.
    pkill -f "^$DEST/Contents/MacOS/CodexTip$" || true
fi
ditto "$PROJECT_ROOT/dist/CodexTip.app" "$DEST"
open -g "$DEST"
echo "已安装并启动：$DEST"
