#!/usr/bin/env bash
set -euo pipefail

# Pillbox — toggle voice dictation overlay
# Bind to a hotkey in your Hyprland config:
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

# Find gtk4-layer-shell library (required for Wayland layer-shell overlay)
find_layer_shell() {
    # Try pkg-config first
    if command -v pkg-config &>/dev/null; then
        local libdir
        libdir=$(pkg-config --variable=libdir gtk4-layer-shell-0 2>/dev/null) || true
        if [[ -n "$libdir" && -f "$libdir/libgtk4-layer-shell.so" ]]; then
            echo "$libdir/libgtk4-layer-shell.so"
            return
        fi
    fi
    # Search common paths
    local path
    for path in /usr/lib /usr/lib64 /usr/local/lib /usr/lib/x86_64-linux-gnu; do
        if [[ -f "$path/libgtk4-layer-shell.so" ]]; then
            echo "$path/libgtk4-layer-shell.so"
            return
        fi
    done
    echo ""
}

LAYER_SHELL_LIB=$(find_layer_shell)
if [[ -z "$LAYER_SHELL_LIB" ]]; then
    notify-send -a Pillbox "gtk4-layer-shell not found. Install it first." 2>/dev/null
    exit 1
fi

LD_PRELOAD="$LAYER_SHELL_LIB" \
GDK_BACKEND=wayland \
python3 "$SCRIPT_DIR/pillbox.py" &
disown
