#!/usr/bin/env bash
set -euo pipefail

# Pillbox — toggle voice dictation overlay
# Bind this to a hotkey in your Hyprland config:
#   bind = $mainMod, space, exec, /path/to/pillbox-toggle.sh

PIDFILE="/tmp/pillbox.pid"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -f "$PIDFILE" ]]; then
    PID=$(cat "$PIDFILE")
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        rm -f "$PIDFILE"
        exit 0
    fi
    rm -f "$PIDFILE"
fi

LD_PRELOAD=/usr/lib/libgtk4-layer-shell.so \
GDK_BACKEND=wayland \
python3 "$SCRIPT_DIR/pillbox.py" &
disown
