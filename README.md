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

```bash
git clone https://github.com/HonorCodes/pillbox.git
cd pillbox
./install.sh
```

The interactive installer walks you through everything:
- Checks dependencies and tells you what to install
- Copies pillbox to `~/.local/bin/`
- Optionally sets up whisper-server locally (with model selection)
- Optionally adds a Hyprland keybinding

### Models

The installer lets you choose a whisper model based on your needs:

| Model | Size | Speed | Accuracy | Best for |
|-------|------|-------|----------|----------|
| `tiny.en` | ~75MB | Fastest | Basic | Quick notes, low-power machines |
| `base.en` | ~148MB | Fast | Good | Daily use without GPU |
| `small.en` | ~488MB | Moderate | Great | Balanced quality/speed |
| `large-v3-turbo` | ~1.5GB | Fast (GPU) | Best | Recommended with NVIDIA GPU |

GPU is auto-detected. Without one, the installer defaults to `base.en`.

## Usage

Press your keybinding (default: `SUPER+Space`). Speak. The pill shows a waveform while you talk. When you stop speaking (3 seconds of silence), the pill dismisses and your transcribed text appears in the focused window.

Press the keybinding again to dismiss early. Click the stop button on the pill for the same effect.

## Server Setup

Pillbox sends recorded audio to a whisper-server for transcription. The installer can set this up for you, or you can do it manually:

```bash
# NVIDIA GPU (fast):
sudo ./setup-server.sh

# Specific model:
sudo ./setup-server.sh --model=small.en

# CPU-only (no GPU):
sudo ./setup-server.sh --cpu

# Custom port/threads:
sudo ./setup-server.sh --port=9090 --threads=8
```

**Remote server:** Run `setup-server.sh` on the remote machine, then set the URL in your config:
```conf
# ~/.config/pillbox/pillbox.conf
server_url = http://your-server-ip:8080
```

## Configuration

Edit `~/.config/pillbox/pillbox.conf` (Hyprland-style `key = value`):

```conf
# Server
server_url = http://localhost:8080

# Behavior
silence_threshold = -20    # dB — raise for noisy environments
silence_duration = 3.0     # seconds of silence before auto-stop

# Appearance
margin_bottom = 30         # auto-detected from Hyprland gaps_out
width = 90
height = 32
num_bars = 5

# Theme (auto-detected from Hyprland if not set)
# theme_source = ~/.config/theme/colors.conf
# background = 0a0a0f
# foreground = cdd6f4
# accent = f38ba8
# border = cba6f7
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
| `$mauve` or `$lavender` | Pill border + stop button |

Colors auto-contrast: light waveform on dark backgrounds, dark on light. Stop button icon switches between white and black based on the border color luminance.

Override any color in `pillbox.conf`. If no theme is found, Pillbox uses a dark glassmorphic default that looks good on most setups.

## Requirements

- [Hyprland](https://hyprland.org/) (or any Wayland compositor with layer-shell)
- Python 3.10+ with PyGObject
- GTK4 + gtk4-layer-shell
- GStreamer with good plugins
- PipeWire (`pw-record`)
- [wtype](https://github.com/atx/wtype)
- [wl-clipboard](https://github.com/bugaevc/wl-clipboard)
- curl
- A running [whisper-server](https://github.com/ggerganov/whisper.cpp) instance

## License

MIT
