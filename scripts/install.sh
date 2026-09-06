#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_ROOT/scripts/build.sh"
DEST="$HOME/Applications/CodexTip.app"
mkdir -p "$HOME/Applications"
if [ -d "$DEST" ]; then
    # Stop only this exact installed binary before replacing it.
    pkill -f "^$DEST/Contents/MacOS/CodexTip$" || true
    # Wait for termination before replacing/relaunching; otherwise Launch Services
    # can still see the old instance and reject the new launch with error -600.
    for attempt in {1..50}; do
        if ! pgrep -f "^$DEST/Contents/MacOS/CodexTip$" >/dev/null; then break; fi
        sleep 0.1
    done
    if pgrep -f "^$DEST/Contents/MacOS/CodexTip$" >/dev/null; then
        echo "CodexTip 尚未退出，请稍后重试 / CodexTip is still exiting; retry shortly." >&2
        exit 1
    fi
fi
ditto "$PROJECT_ROOT/dist/CodexTip.app" "$DEST"
open -g "$DEST"
echo "已安装并启动：$DEST"
