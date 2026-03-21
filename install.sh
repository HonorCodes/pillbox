#!/usr/bin/env bash
set -euo pipefail

# Pillbox installer
# Copies pillbox to ~/.local/bin/ and creates config directory.

INSTALL_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/pillbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing Pillbox..."

# Create directories
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

# Copy main files
cp "$SCRIPT_DIR/pillbox.py" "$INSTALL_DIR/pillbox.py"
cp "$SCRIPT_DIR/pillbox-toggle.sh" "$INSTALL_DIR/pillbox-toggle.sh"
chmod +x "$INSTALL_DIR/pillbox.py" "$INSTALL_DIR/pillbox-toggle.sh"

# Copy example config if no config exists
if [[ ! -f "$CONFIG_DIR/pillbox.conf" ]]; then
    cp "$SCRIPT_DIR/pillbox.conf.example" "$CONFIG_DIR/pillbox.conf"
    echo "Created config at $CONFIG_DIR/pillbox.conf"
else
    echo "Config already exists at $CONFIG_DIR/pillbox.conf (not overwritten)"
fi

echo ""
echo "Installed to $INSTALL_DIR/"
echo ""
echo "Next steps:"
echo ""
echo "  1. Set up whisper-server (if not already running):"
echo "     sudo ./setup-server.sh"
echo ""
echo "  2. Add a keybinding to your Hyprland config:"
echo "     echo 'bind = \$mainMod, space, exec, $INSTALL_DIR/pillbox-toggle.sh' >> ~/.config/hypr/hyprland.conf"
echo ""
echo "  3. Add blur rules (optional, for glassmorphic effect):"
echo "     echo 'layerrule = blur on, match:namespace pillbox' >> ~/.config/hypr/hyprland.conf"
echo "     echo 'layerrule = ignore_alpha 0.3, match:namespace pillbox' >> ~/.config/hypr/hyprland.conf"
echo ""
echo "  4. Reload Hyprland:"
echo "     hyprctl reload"
echo ""
echo "  5. Press your keybinding and speak!"
