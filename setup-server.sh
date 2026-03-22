#!/usr/bin/env bash
set -euo pipefail

# Pillbox Server Setup
# Installs whisper-server (whisper.cpp) with GPU or CPU support
# and sets it up as a systemd service.
#
# Usage:
#   sudo ./setup-server.sh                          # Auto-detect GPU, large-v3-turbo
#   sudo ./setup-server.sh --cpu                    # Force CPU-only build
#   sudo ./setup-server.sh --model=small.en         # Use a smaller model
#   sudo ./setup-server.sh --bind=0.0.0.0           # Listen on all interfaces
#   sudo ./setup-server.sh --language=auto           # Auto-detect language

MODEL_NAME="large-v3-turbo"
MODEL_DIR="/opt/whisper/models"
INSTALL_PREFIX="/usr/local"
PORT=9310
THREADS=4
CPU_ONLY=false
BIND_HOST="127.0.0.1"
LANGUAGE="en"

for arg in "$@"; do
    case "$arg" in
        --cpu) CPU_ONLY=true ;;
        --port=*) PORT="${arg#*=}" ;;
        --threads=*) THREADS="${arg#*=}" ;;
        --model=*) MODEL_NAME="${arg#*=}" ;;
        --bind=*) BIND_HOST="${arg#*=}" ;;
        --language=*) LANGUAGE="${arg#*=}" ;;
    esac
done

MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL_NAME}.bin"
MODEL_FILE="$MODEL_DIR/ggml-${MODEL_NAME}.bin"

echo "=== Pillbox Server Setup ==="
echo ""

# ── Step 1: Detect GPU ──
USE_CUDA=false
if [[ "$CPU_ONLY" == "false" ]] && command -v nvidia-smi &> /dev/null; then
    echo "NVIDIA GPU detected:"
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
    USE_CUDA=true
    echo ""
elif [[ "$CPU_ONLY" == "false" ]]; then
    echo "No NVIDIA GPU found. Building CPU-only (slower but works)."
    echo "Install NVIDIA drivers first for GPU acceleration."
    echo ""
fi

# ── Step 2: Install build dependencies ──
echo "── Installing build dependencies ──"
if command -v apt &> /dev/null; then
    apt-get update -qq
    apt-get install -y -qq git cmake build-essential libcurl4-openssl-dev curl
    if [[ "$USE_CUDA" == "true" ]]; then
        apt-get install -y -qq nvidia-cuda-toolkit
    fi
elif command -v pacman &> /dev/null; then
    pacman -S --needed --noconfirm git cmake base-devel curl
    if [[ "$USE_CUDA" == "true" ]]; then
        pacman -S --needed --noconfirm cuda
    fi
elif command -v dnf &> /dev/null; then
    dnf install -y git cmake gcc-c++ libcurl-devel curl
    if [[ "$USE_CUDA" == "true" ]]; then
        dnf install -y cuda-toolkit
    fi
else
    echo "Unsupported package manager. Install manually:"
    echo "  git, cmake, C++ compiler, libcurl, curl"
    echo "  For GPU: CUDA toolkit"
    exit 1
fi
echo ""

# ── Step 3: Build whisper.cpp ──
echo "── Building whisper.cpp ──"
BUILD_DIR=$(mktemp -d)
cd "$BUILD_DIR"
git clone --depth 1 --branch v1.8.4 https://github.com/ggml-org/whisper.cpp.git .

CMAKE_ARGS=(
    -B build
    -DWHISPER_BUILD_SERVER=ON
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX"
    -DBUILD_SHARED_LIBS=ON
)

if [[ "$USE_CUDA" == "true" ]]; then
    CMAKE_ARGS+=(-DGGML_CUDA=ON)
    echo "Building with CUDA support..."
else
    echo "Building CPU-only..."
fi

cmake "${CMAKE_ARGS[@]}"
cmake --build build -j"$(nproc)"
cmake --install build
ldconfig
cd /
rm -rf "$BUILD_DIR"
echo ""

# ── Step 4: Download model ──
echo "── Downloading $MODEL_NAME model ──"
mkdir -p "$MODEL_DIR"
if [[ ! -f "$MODEL_FILE" ]]; then
    curl -L --progress-bar -o "$MODEL_FILE" "$MODEL_URL"
    echo "Downloaded $(du -h "$MODEL_FILE" | cut -f1)"
else
    echo "Model already exists: $(du -h "$MODEL_FILE" | cut -f1)"
fi
echo ""

# ── Step 5: Create systemd service ──
echo "── Creating systemd service ──"
cat > /etc/systemd/system/whisper-server.service << EOF
[Unit]
Description=Whisper Speech-to-Text Server
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
    echo "whisper-server running on port $PORT"
    echo ""
    echo "Test with:"
    echo "  curl -F 'file=@audio.wav' http://localhost:$PORT/inference"
else
    echo "Failed to start. Check: journalctl -u whisper-server -n 20"
    exit 1
fi

echo ""
echo "=== Setup complete ==="
