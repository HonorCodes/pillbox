#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
# Pillbox Installer
# Sets up voice dictation for Hyprland/Wayland.
# ─────────────────────────────────────────────────────────

INSTALL_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/pillbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HYPR_CONF="${HOME}/.config/hypr/hyprland.conf"

# ── Colors ──────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Helpers ─────────────────────────────────────────────

info()    { printf "${BLUE}::${RESET} %s\n" "$1"; }
ok()      { printf "${GREEN} ✓${RESET} %s\n" "$1"; }
warn()    { printf "${YELLOW} !${RESET} %s\n" "$1"; }
err()     { printf "${RED} ✗${RESET} %s\n" "$1"; }
header()  { printf "\n${BOLD}%s${RESET}\n" "$1"; }

ask() {
    local prompt="$1" default="$2" reply
    if [[ "$default" == "y" ]]; then
        printf "${CYAN} ?${RESET} %s [Y/n] " "$prompt"
    else
        printf "${CYAN} ?${RESET} %s [y/N] " "$prompt"
    fi
    read -r reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

ask_input() {
    local prompt="$1" default="$2" reply
    printf "${CYAN} ?${RESET} %s " "$prompt"
    printf "${DIM}(%s)${RESET} " "$default"
    read -r reply
    printf '%s' "${reply:-$default}"
}

# ── Banner ──────────────────────────────────────────────

printf "\n"
printf "${BOLD}  Pillbox Installer${RESET}\n"
printf "${DIM}  Voice dictation for Hyprland${RESET}\n"
printf "\n"

# ─────────────────────────────────────────────────────────
# 1. Detect distro & check dependencies
# ─────────────────────────────────────────────────────────

header "1. Checking dependencies"

# Detect package manager
PKG_MGR=""
if command -v pacman &>/dev/null; then
    PKG_MGR="pacman"
elif command -v apt &>/dev/null; then
    PKG_MGR="apt"
elif command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
fi

if [[ -n "$PKG_MGR" ]]; then
    ok "Package manager: $PKG_MGR"
else
    warn "Could not detect package manager"
fi

# Define dependencies per distro
# Format: command|pacman_pkg|apt_pkg|dnf_pkg
DEPS=(
    "python3|python|python3|python3"
    "python3 -c 'import gi'|python-gobject|python3-gi|python3-gobject"
    "pkg-config --exists gtk4|gtk4|libgtk-4-dev|gtk4-devel"
    "pkg-config --exists gtk4-layer-shell-0|gtk4-layer-shell|libgtk4-layer-shell-dev|gtk4-layer-shell-devel"
    "gst-inspect-1.0 level|gst-plugins-good|gstreamer1.0-plugins-good|gstreamer1-plugins-good"
    "wtype -h|wtype|wtype|wtype"
    "wl-copy --version|wl-clipboard|wl-clipboard|wl-clipboard"
    "curl --version|curl|curl|curl"
    "pw-record --help|pipewire|pipewire|pipewire"
)

MISSING_CMDS=()
MISSING_PKGS=()

for dep in "${DEPS[@]}"; do
    IFS='|' read -r check_cmd pkg_pac pkg_apt pkg_dnf <<< "$dep"
    # shellcheck disable=SC2086
    if eval $check_cmd &>/dev/null 2>&1; then
        ok "$(echo "$check_cmd" | cut -d' ' -f1)"
    else
        short_name="$(echo "$check_cmd" | cut -d' ' -f1)"
        err "Missing: $short_name"
        MISSING_CMDS+=("$short_name")
        case "$PKG_MGR" in
            pacman) MISSING_PKGS+=("$pkg_pac") ;;
            apt)    MISSING_PKGS+=("$pkg_apt") ;;
            dnf)    MISSING_PKGS+=("$pkg_dnf") ;;
        esac
    fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    printf "\n"
    warn "Missing dependencies. Install with:"
    printf "\n"
    case "$PKG_MGR" in
        pacman)
            printf "  sudo pacman -S %s\n" \
                "${MISSING_PKGS[*]}"
            ;;
        apt)
            printf "  sudo apt install %s\n" \
                "${MISSING_PKGS[*]}"
            ;;
        dnf)
            printf "  sudo dnf install %s\n" \
                "${MISSING_PKGS[*]}"
            ;;
        *)
            printf "  Install: %s\n" \
                "${MISSING_CMDS[*]}"
            ;;
    esac
    printf "\n"
    if ! ask "Continue anyway?" "n"; then
        printf "\n"
        info "Install dependencies and re-run."
        exit 1
    fi
fi

# ─────────────────────────────────────────────────────────
# 2. Install pillbox files
# ─────────────────────────────────────────────────────────

header "2. Installing pillbox"

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

cp "$SCRIPT_DIR/pillbox.py" \
    "$INSTALL_DIR/pillbox.py"
cp "$SCRIPT_DIR/pillbox-toggle.sh" \
    "$INSTALL_DIR/pillbox-toggle.sh"
chmod +x \
    "$INSTALL_DIR/pillbox.py" \
    "$INSTALL_DIR/pillbox-toggle.sh"
ok "Installed to $INSTALL_DIR/"

if [[ ! -f "$CONFIG_DIR/pillbox.conf" ]]; then
    cp "$SCRIPT_DIR/pillbox.conf.example" \
        "$CONFIG_DIR/pillbox.conf"
    ok "Created config at $CONFIG_DIR/pillbox.conf"
else
    ok "Config exists (not overwritten)"
fi

INSTALLED_SERVER=false
INSTALLED_BIND=false
BIND_KEY=""

# ─────────────────────────────────────────────────────────
# 3. Whisper server setup
# ─────────────────────────────────────────────────────────

header "3. Whisper server"

if systemctl is-active --quiet whisper-server 2>/dev/null; then
    ok "whisper-server is already running"
else
    printf "\n"
    info "Pillbox needs a whisper-server for transcription."
    info "You can set one up now or point to a remote one later."
    printf "\n"

    if ask "Set up whisper-server locally?" "n"; then
        # GPU detection
        HAS_GPU=false
        if command -v nvidia-smi &>/dev/null; then
            HAS_GPU=true
            GPU_NAME=$(nvidia-smi \
                --query-gpu=name \
                --format=csv,noheader 2>/dev/null \
                | head -1)
            ok "GPU detected: $GPU_NAME"
        else
            warn "No NVIDIA GPU detected (CPU build)"
        fi

        # Model selection
        printf "\n"
        info "Select a whisper model:"
        printf "\n"
        printf "  ${BOLD}1)${RESET} tiny.en    "
        printf "${DIM}~75MB   fastest, basic accuracy${RESET}\n"
        printf "  ${BOLD}2)${RESET} base.en    "
        printf "${DIM}~148MB  fast, good accuracy${RESET}\n"
        printf "  ${BOLD}3)${RESET} small.en   "
        printf "${DIM}~488MB  moderate, great accuracy${RESET}\n"
        if [[ "$HAS_GPU" == "true" ]]; then
            printf "  ${BOLD}4)${RESET} large-v3-turbo  "
            printf "${DIM}~1.5GB  best (recommended with GPU)${RESET}\n"
        else
            printf "  ${BOLD}4)${RESET} large-v3-turbo  "
            printf "${DIM}~1.5GB  best (slow without GPU)${RESET}\n"
        fi
        printf "\n"

        if [[ "$HAS_GPU" == "true" ]]; then
            DEFAULT_MODEL="4"
        else
            DEFAULT_MODEL="2"
        fi

        MODEL_CHOICE=$(ask_input \
            "Model [1-4]:" "$DEFAULT_MODEL")
        printf "\n"

        case "$MODEL_CHOICE" in
            1) MODEL_NAME="tiny.en" ;;
            2) MODEL_NAME="base.en" ;;
            3) MODEL_NAME="small.en" ;;
            4) MODEL_NAME="large-v3-turbo" ;;
            *)
                warn "Invalid choice, using base.en"
                MODEL_NAME="base.en"
                ;;
        esac

        ok "Selected model: $MODEL_NAME"

        SUDO_ARGS=("sudo" "$SCRIPT_DIR/setup-server.sh"
            "--model=$MODEL_NAME")
        if [[ "$HAS_GPU" != "true" ]]; then
            SUDO_ARGS+=("--cpu")
        fi

        printf "\n"
        info "This will run with sudo:"
        printf "  %s\n" "${SUDO_ARGS[*]}"
        printf "\n"

        if ask "Continue?" "y"; then
            printf "\n"
            "${SUDO_ARGS[@]}"
            INSTALLED_SERVER=true
        else
            warn "Skipped server setup"
            info "Run manually: sudo ./setup-server.sh"
        fi
    else
        info "Set server_url in $CONFIG_DIR/pillbox.conf"
        info "to point to your whisper-server instance."
    fi
fi

# ─────────────────────────────────────────────────────────
# 4. Hyprland keybinding
# ─────────────────────────────────────────────────────────

header "4. Hyprland keybinding"

if [[ ! -f "$HYPR_CONF" ]]; then
    warn "No hyprland.conf found at $HYPR_CONF"
    info "Add a keybinding manually after install."
else
    # Check if pillbox binding already exists
    if grep -q "pillbox-toggle" "$HYPR_CONF" 2>/dev/null; then
        ok "Keybinding already configured"
    else
        printf "\n"
        if ask "Add keybinding to hyprland.conf?" "n"; then
            BIND_KEY=$(ask_input \
                "Key combo:" "SUPER+Space")
            printf "\n"

            # Parse modifier and key
            BIND_MOD=""
            BIND_KEYNAME=""
            IFS='+' read -r BIND_MOD BIND_KEYNAME \
                <<< "$BIND_KEY"

            # Map common modifier names
            case "${BIND_MOD,,}" in
                super|mod|mod4) BIND_MOD="\$mainMod" ;;
                alt|mod1) BIND_MOD="ALT" ;;
                ctrl|control) BIND_MOD="CTRL" ;;
                shift) BIND_MOD="SHIFT" ;;
            esac

            BIND_KEYNAME="${BIND_KEYNAME,,}"

            BIND_LINES=$(cat <<EOF

# Pillbox voice dictation
bind = ${BIND_MOD}, ${BIND_KEYNAME}, exec, ${INSTALL_DIR}/pillbox-toggle.sh
layerrule = blur on, match:namespace pillbox
layerrule = ignore_alpha 0.3, match:namespace pillbox
EOF
)
            printf "\n"
            info "Will append to $HYPR_CONF:"
            printf "${DIM}%s${RESET}\n" "$BIND_LINES"
            printf "\n"

            if ask "Confirm?" "y"; then
                printf '%s\n' "$BIND_LINES" \
                    >> "$HYPR_CONF"
                ok "Keybinding added"
                INSTALLED_BIND=true

                if command -v hyprctl &>/dev/null; then
                    hyprctl reload &>/dev/null && \
                        ok "Hyprland reloaded" || \
                        warn "Could not reload Hyprland"
                fi
            else
                warn "Skipped keybinding"
            fi
        fi
    fi
fi

# ─────────────────────────────────────────────────────────
# 5. Summary
# ─────────────────────────────────────────────────────────

header "Done!"
printf "\n"

printf "  ${BOLD}Installed${RESET}\n"
ok "$INSTALL_DIR/pillbox.py"
ok "$INSTALL_DIR/pillbox-toggle.sh"
ok "$CONFIG_DIR/pillbox.conf"
if [[ "$INSTALLED_SERVER" == "true" ]]; then
    ok "whisper-server (systemd service)"
fi
if [[ "$INSTALLED_BIND" == "true" ]]; then
    ok "Hyprland keybinding: $BIND_KEY"
fi

printf "\n"
printf "  ${BOLD}Usage${RESET}\n"
if [[ "$INSTALLED_BIND" == "true" ]]; then
    info "Press ${BOLD}${BIND_KEY}${RESET} to toggle dictation"
else
    info "Bind ${INSTALL_DIR}/pillbox-toggle.sh to a hotkey"
fi
info "Edit ${CONFIG_DIR}/pillbox.conf to customize"

printf "\n"
printf "  ${BOLD}Uninstall${RESET}\n"
printf "${DIM}"
printf "  rm %s/pillbox.py\n" "$INSTALL_DIR"
printf "  rm %s/pillbox-toggle.sh\n" "$INSTALL_DIR"
printf "  rm -r %s\n" "$CONFIG_DIR"
if [[ "$INSTALLED_SERVER" == "true" ]]; then
    printf "  sudo systemctl disable --now whisper-server\n"
fi
if [[ "$INSTALLED_BIND" == "true" ]]; then
    printf "  # Remove pillbox lines from %s\n" \
        "$HYPR_CONF"
fi
printf "${RESET}\n"
