# Pillbox

Voice dictation for Hyprland. Press a hotkey, speak, text appears in the focused window. A small glassmorphic pill overlay shows a waveform while you speak, and auto-dismisses after silence.

Pillbox auto-themes from your Hyprland color config so it matches your rice out of the box.

## How it works

1. **SUPER+Space** — pill overlay appears at the bottom of your screen
2. **Speak** — waveform bars animate, audio is recorded
3. **Stop speaking** — after 3 seconds of silence, the pill dismisses and your transcribed text is typed into the focused window
4. **SUPER+Space again** — instant dismiss (transcribes what you've said so far)

Transcription is handled by [whisper.cpp](https://github.com/ggerganov/whisper.cpp)'s HTTP server running locally or on a remote machine. The `large-v3-turbo` model provides high accuracy with low latency.

## Quick Start

### 1. Install dependencies

**Arch Linux:**
```bash
sudo pacman -S wtype wl-clipboard gtk4 \
  gtk4-layer-shell gst-plugins-good curl
```

**Ubuntu/Debian:**
```bash
sudo apt install wtype wl-clipboard libgtk-4-1 \
  libgtk4-layer-shell0 gstreamer1.0-plugins-good \
  gir1.2-gtk4layershell-1.0 curl pipewire
```

### 2. Set up the whisper server

```bash
# On the machine with a GPU (can be the same machine):
sudo ./setup-server.sh

# Or CPU-only (slower, no GPU needed):
sudo ./setup-server.sh --cpu
```

This builds whisper.cpp, downloads the large-v3-turbo model (~1.5GB), and creates a systemd service on port 8080.

### 3. Install Pillbox

```bash
# Clone
git clone https://github.com/HonorCodes/pillbox.git
cd pillbox

# Make scripts executable
chmod +x pillbox.py pillbox-toggle.sh

# Optional: copy config
mkdir -p ~/.config/pillbox
cp pillbox.conf.example ~/.config/pillbox/pillbox.conf
```

### 4. Add Hyprland keybinding

Add to `~/.config/hypr/hyprland.conf`:

```conf
# Pillbox voice dictation
bind = $mainMod, space, exec, /path/to/pillbox-toggle.sh

# Glassmorphic blur for the pill overlay
layerrule = blur on, match:namespace pillbox
layerrule = ignore_alpha 0.3, match:namespace pillbox
```

Reload Hyprland: `hyprctl reload`

## Server Setup

Pillbox sends recorded audio to a whisper-server instance for transcription. The server can run locally or on a separate machine.

### Local (same machine)

```bash
sudo ./setup-server.sh
```

The server runs on `http://localhost:8080` by default — no config changes needed.

### Remote server

Run `setup-server.sh` on the remote machine, then set the URL in your config:

```conf
# ~/.config/pillbox/pillbox.conf
server_url = http://192.168.1.100:8080
```

### CPU-only (no GPU)

```bash
sudo ./setup-server.sh --cpu
```

Works but transcription is slower (~3-5 seconds vs ~0.5 seconds with a GPU).

### Custom port or threads

```bash
sudo ./setup-server.sh --port=9090 --threads=8
```

## Configuration

Create `~/.config/pillbox/pillbox.conf` (copy from `pillbox.conf.example`):

```conf
# Server
server_url = http://localhost:8080

# Behavior
silence_threshold = -20
silence_duration = 3.0

# Visual
position = bottom
margin_bottom = 30
width = 100
height = 40
num_bars = 5

# Theme source (auto-detected if not set)
# theme_source = ~/.config/theme/colors.conf

# Color overrides (6-digit hex, no #)
# background = 0a0a0f
# foreground = cdd6f4
# accent = f38ba8
# border = 45475a
```

### Silence threshold

The default `-20` dB works well for most environments. If you have loud background noise (music, fans), raise it (e.g., `-15`). If your mic is quiet, lower it (e.g., `-25`).

## Theming

Pillbox auto-detects your Hyprland color theme from common locations:

- `~/.config/theme/colors.conf`
- `~/.config/hypr/colors.conf`

It reads Hyprland-style `$variable = hexvalue` definitions and maps them:

| Hyprland variable | Pillbox element |
|---|---|
| `$base` or `$surface` | Pill background |
| `$text` | Waveform bars |
| `$red` | Stop button |
| `$overlay` | Pill border |

Override any color in `pillbox.conf`:

```conf
background = 1a1b26
accent = ff6b6b
```

If no theme is found, Pillbox uses a dark glassmorphic default that looks good on most setups.

## Requirements

- **Hyprland** (Wayland compositor with layer-shell support)
- **Python 3.10+** with PyGObject
- **GTK4** + **gtk4-layer-shell**
- **GStreamer** with good plugins (for audio level metering)
- **PipeWire** (`pw-record` for audio capture)
- **wtype** (Wayland text input)
- **wl-clipboard** (`wl-copy` for clipboard)
- **curl** (HTTP client)
- **whisper-server** (whisper.cpp HTTP API, local or remote)

## License

MIT
