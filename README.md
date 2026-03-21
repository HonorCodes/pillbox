<p align="center">
  <img src="assets/pillbox-logo.png" alt="Pillbox" width="128">
</p>

<h1 align="center">Pillbox</h1>

<p align="center">
  Voice dictation for Hyprland. Speak, and text appears in the focused window.
</p>

---

A small glassmorphic pill overlay pops up when you activate it, shows a waveform while you speak, and auto-dismisses after silence. Transcription is handled by [whisper.cpp](https://github.com/ggerganov/whisper.cpp) running as a local server.

Pillbox auto-themes from your Hyprland color config, so it matches your rice out of the box.

<p align="center">
  <img src="assets/pillbox-example.png" alt="Pillbox in action" width="400">
</p>

<details>
<summary>Full screen example</summary>
<p align="center">
  <img src="assets/pillbox-fullscreen-example.png" alt="Pillbox full screen" width="800">
</p>
</details>

## Quick Start

### 1. Install dependencies

**Arch Linux:**
```bash
sudo pacman -S python-gobject gtk4 gtk4-layer-shell \
  gst-plugins-good wtype wl-clipboard curl
```

**Ubuntu/Debian:**
```bash
sudo apt install python3-gi gir1.2-gtk-4.0 \
  gir1.2-gtk4layershell-1.0 gstreamer1.0-plugins-good \
  wtype wl-clipboard curl pipewire
```

### 2. Set up the whisper server

Pillbox sends recorded audio to a whisper-server instance for transcription. Run the setup script on whichever machine has a GPU (can be the same machine):

```bash
# With NVIDIA GPU (fast):
sudo ./setup-server.sh

# CPU-only (slower but works on any machine):
sudo ./setup-server.sh --cpu
```

This builds whisper.cpp, downloads the `large-v3-turbo` model (~1.5GB), and creates a systemd service on port 8080.

**Custom port or thread count:**
```bash
sudo ./setup-server.sh --port=9090 --threads=8
```

**Remote server:** Run `setup-server.sh` on the remote machine, then set the URL in your config:
```conf
# ~/.config/pillbox/pillbox.conf
server_url = http://your-server-ip:8080
```

### 3. Install Pillbox

```bash
git clone https://github.com/HonorCodes/pillbox.git
cd pillbox
./install.sh
```

This copies `pillbox.py` and `pillbox-toggle.sh` to `~/.local/bin/` and creates a default config at `~/.config/pillbox/pillbox.conf`.

### 4. Add a keybinding

Add these lines to `~/.config/hypr/hyprland.conf`:

```conf
# Voice dictation (choose any key combo you like)
bind = $mainMod, space, exec, ~/.local/bin/pillbox-toggle.sh

# Glassmorphic blur for the pill overlay (optional)
layerrule = blur on, match:namespace pillbox
layerrule = ignore_alpha 0.3, match:namespace pillbox
```

Reload: `hyprctl reload`

### 5. Use it

Press your keybinding. Speak. The pill shows a waveform while you talk. When you stop speaking (3 seconds of silence), the pill dismisses and your transcribed text appears in the focused window.

Press the keybinding again to dismiss early. Click the stop button on the pill for the same effect.

## Configuration

Edit `~/.config/pillbox/pillbox.conf`:

```conf
# Server URL (default: local whisper-server)
server_url = http://localhost:8080

# Silence threshold in dB — raise if background noise triggers it
silence_threshold = -20

# Seconds of silence before auto-stopping
silence_duration = 3.0

# Pill appearance
position = bottom
margin_bottom = 30
width = 100
height = 40
num_bars = 5

# Theme source (auto-detected from common Hyprland paths if not set)
# theme_source = ~/.config/theme/colors.conf

# Color overrides (6-digit hex, no #)
# background = 0a0a0f
# foreground = cdd6f4
# accent = f38ba8
# border = 45475a
```

## Theming

Pillbox auto-detects your Hyprland color theme from:
- `~/.config/theme/colors.conf`
- `~/.config/hypr/colors.conf`

It reads `$variable = hexvalue` definitions and maps them:

| Hyprland variable | Pillbox element |
|---|---|
| `$base` or `$surface` | Pill background |
| `$text` | Waveform bars |
| `$red` | Stop button |
| `$overlay` | Pill border |

Override any color in `pillbox.conf`. If no theme is found, Pillbox uses a dark glassmorphic default.

## Requirements

- [Hyprland](https://hyprland.org/) (or any Wayland compositor with layer-shell)
- Python 3.10+ with PyGObject
- GTK4 + gtk4-layer-shell
- GStreamer with good plugins
- PipeWire (`pw-record`)
- [wtype](https://github.com/atx/wtype) (Wayland text input)
- [wl-clipboard](https://github.com/bugaevc/wl-clipboard)
- curl
- A running [whisper-server](https://github.com/ggerganov/whisper.cpp) instance (local or remote)

## License

MIT
