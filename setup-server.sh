#!/usr/bin/env bash
set -euo pipefail

# Pillbox Server Setup
# Builds whisper-server (whisper.cpp) with GPU or CPU support
# and sets it up as a systemd service.
#
# Usage:
#   sudo ./setup-server.sh                        # Interactive (default)
#   sudo ./setup-server.sh --yes                   # Non-interactive, accept all
#   sudo ./setup-server.sh --cpu                   # Force CPU-only build
#   sudo ./setup-server.sh --model=small.en        # Use a smaller model
#   sudo ./setup-server.sh --bind=0.0.0.0          # Listen on all interfaces
#   sudo ./setup-server.sh --language=auto         # Auto-detect language

MODEL_NAME="large-v3-turbo"
MODEL_DIR="/opt/whisper/models"
INSTALL_PREFIX="/usr/local"
PORT=9310
THREADS=4
CPU_ONLY=false
BIND_HOST="127.0.0.1"
LANGUAGE="en"
AUTO_YES=false

for arg in "$@"; do
    case "$arg" in
        --cpu) CPU_ONLY=true ;;
        --port=*) PORT="${arg#*=}" ;;
        --threads=*) THREADS="${arg#*=}" ;;
        --model=*) MODEL_NAME="${arg#*=}" ;;
        --bind=*) BIND_HOST="${arg#*=}" ;;
        --language=*) LANGUAGE="${arg#*=}" ;;
        --yes|-y) AUTO_YES=true ;;
    esac
done

MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL_NAME}.bin"
MODEL_FILE="$MODEL_DIR/ggml-${MODEL_NAME}.bin"

# ── Helpers ──

confirm() {
    if [[ "$AUTO_YES" == "true" ]]; then
        return 0
    fi
    local prompt="$1"
    printf "  %s [Y/n] " "$prompt"
    read -r reply
    reply="${reply:-y}"
    [[ "$reply" =~ ^[Yy] ]]
}

warn() { printf "  ⚠  %s\n" "$1"; }
ok()   { printf "  ✓  %s\n" "$1"; }
err()  { printf "  ✗  %s\n" "$1"; }

echo ""
echo "=== Pillbox Server Setup ==="
echo ""

# ── Step 1: Detect GPU ──
USE_CUDA=false
if [[ "$CPU_ONLY" == "false" ]] && command -v nvidia-smi &> /dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    ok "NVIDIA GPU detected: $GPU_NAME"
    USE_CUDA=true
elif [[ "$CPU_ONLY" == "false" ]]; then
    warn "No NVIDIA GPU found — will build CPU-only (slower)"
fi
echo ""

# ── Step 2: Check build dependencies ──
echo "── Checking build dependencies ──"

NEEDED_PKGS=()
MISSING_CMDS=()

for cmd in git cmake curl; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd"
    else
        MISSING_CMDS+=("$cmd")
    fi
done

# Check for C++ compiler
if command -v g++ &>/dev/null || command -v c++ &>/dev/null; then
    ok "C++ compiler"
else
    MISSING_CMDS+=("g++")
fi

if [[ "$USE_CUDA" == "true" ]]; then
    if command -v nvcc &>/dev/null; then
        ok "CUDA toolkit (nvcc)"
    else
        MISSING_CMDS+=("nvcc (CUDA toolkit)")
    fi
fi

if [[ ${#MISSING_CMDS[@]} -gt 0 ]]; then
    echo ""
    err "Missing: ${MISSING_CMDS[*]}"
    echo ""

    # Suggest install commands but don't run them
    if command -v apt &>/dev/null; then
        echo "  Install with:"
        echo "    sudo apt install git cmake build-essential libcurl4-openssl-dev curl"
        [[ "$USE_CUDA" == "true" ]] && echo "    sudo apt install nvidia-cuda-toolkit"
    elif command -v pacman &>/dev/null; then
        echo "  Install with:"
        echo "    sudo pacman -S git cmake base-devel curl"
        [[ "$USE_CUDA" == "true" ]] && echo "    sudo pacman -S cuda"
    elif command -v dnf &>/dev/null; then
        echo "  Install with:"
        echo "    sudo dnf install git cmake gcc-c++ libcurl-devel curl"
        [[ "$USE_CUDA" == "true" ]] && echo "    sudo dnf install cuda-toolkit"
    fi

    echo ""
    echo "  Install the missing dependencies and re-run this script."
    exit 1
fi
echo ""

# ── Step 3: Check for conflicts ──
echo "── Checking for conflicts ──"

if [[ -f "$INSTALL_PREFIX/bin/whisper-server" ]]; then
    warn "whisper-server already exists at $INSTALL_PREFIX/bin/whisper-server"
    if ! confirm "Overwrite it?"; then
        echo "  Aborted."
        exit 0
    fi
else
    ok "No existing whisper-server installation"
fi

if [[ -f /etc/systemd/system/whisper-server.service ]]; then
    warn "whisper-server.service already exists"
    if ! confirm "Replace the systemd service?"; then
        echo "  Aborted."
        exit 0
    fi
else
    ok "No existing systemd service"
fi

if ss -tlnp 2>/dev/null | grep -q ":$PORT "; then
    warn "Port $PORT is already in use:"
    ss -tlnp 2>/dev/null | grep ":$PORT " | head -1
    if ! confirm "Continue anyway?"; then
        echo "  Aborted. Use --port=NNNN to pick a different port."
        exit 0
    fi
else
    ok "Port $PORT is available"
fi
echo ""

# ── Step 4: Build whisper.cpp ──
echo "── Building whisper.cpp (v1.8.4) ──"

if ! confirm "Build and install whisper-server to $INSTALL_PREFIX/?"; then
    echo "  Aborted."
    exit 0
fi

BUILD_DIR=$(mktemp -d)
cd "$BUILD_DIR"
git clone --depth 1 --branch v1.8.4 \
    https://github.com/ggml-org/whisper.cpp.git .

CMAKE_ARGS=(
    -B build
    -DWHISPER_BUILD_SERVER=ON
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX"
    -DBUILD_SHARED_LIBS=ON
)

if [[ "$USE_CUDA" == "true" ]]; then
    CMAKE_ARGS+=(-DGGML_CUDA=ON)
    echo "  Building with CUDA support..."
else
    echo "  Building CPU-only..."
fi

cmake "${CMAKE_ARGS[@]}"
cmake --build build -j"$(nproc)"
cmake --install build
ldconfig  # register shared libraries
cd /
rm -rf "$BUILD_DIR"
ok "whisper-server installed to $INSTALL_PREFIX/bin/"
echo ""

# ── Step 5: Download model ──
echo "── Model: $MODEL_NAME ──"
mkdir -p "$MODEL_DIR"
if [[ -f "$MODEL_FILE" ]]; then
    ok "Model already exists: $(du -h "$MODEL_FILE" | cut -f1)"
else
    echo "  Downloading from HuggingFace..."
    curl -L --progress-bar -o "$MODEL_FILE" "$MODEL_URL"
    ok "Downloaded: $(du -h "$MODEL_FILE" | cut -f1)"
fi
echo ""

# ── Step 6: Create systemd service ──
echo "── Systemd service ──"

if ! confirm "Create and enable whisper-server systemd service?"; then
    echo ""
    echo "  You can run whisper-server manually:"
    echo "    $INSTALL_PREFIX/bin/whisper-server \\"
    echo "      -m $MODEL_FILE \\"
    echo "      -t $THREADS --host $BIND_HOST --port $PORT -l $LANGUAGE"
    exit 0
fi

cat > /etc/systemd/system/whisper-server.service << EOF
[Unit]
Description=Whisper Speech-to-Text Server (Pillbox)
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_PREFIX/bin/whisper-server \\
    -m $MODEL_FILE \\
    -t $THREADS \\
    --host $BIND_HOST \\
    --port $PORT \\
    -l $LANGUAGE
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable whisper-server
systemctl restart whisper-server
sleep 3

if systemctl is-active --quiet whisper-server; then
    ok "whisper-server running on $BIND_HOST:$PORT"
    echo ""
    echo "  Test with:"
    echo "    curl -F 'file=@audio.wav' http://localhost:$PORT/inference"
else
    err "Failed to start"
    echo "  Check: journalctl -u whisper-server -n 20"
    exit 1
fi

echo ""
echo "=== Setup complete ==="
