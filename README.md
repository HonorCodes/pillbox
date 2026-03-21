<p align="center">
  <img src="assets/pillbox-logo.png" alt="Pillbox" width="128">
</p>

<h1 align="center">Pillbox</h1>

<p align="center">
  A Hyprland-native voice dictation frontend powered by
  <a href="https://github.com/ggerganov/whisper.cpp">whisper.cpp</a>
</p>

---

<p align="center">
  <img src="assets/pillbox-example.png" alt="Pillbox in action" width="400">
</p>

<details>
<summary>Full screen example</summary>
<p align="center">
  <img src="assets/pillbox-fullscreen-example.png" alt="Pillbox full screen" width="800">
</p>
</details>

## What is this?

Pillbox is a dictation frontend for Hyprland that integrates [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with a themed pill overlay. It handles the glue between audio capture, the whisper transcription server, and typing the result into your focused window — so you get a dictation experience similar to macOS or Android, but running entirely on your own hardware.

**Pillbox provides:**
- A pill-shaped Wayland overlay (via GTK4 + layer-shell) with live waveform
- Auto-theming from your Hyprland color config
- Silence detection and hotkey toggle
- An interactive installer that sets up whisper.cpp for you

**Pillbox relies on:**
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for speech recognition (OpenAI's Whisper model)
- [PipeWire](https://pipewire.org/) for audio capture
- [wtype](https://github.com/atx/wtype) for typing into Wayland windows
- [GTK4](https://gtk.org/) + [gtk4-layer-shell](https://github.com/wmww/gtk4-layer-shell) for the overlay

**How it works:**
1. Press a hotkey — a small pill overlay appears at the bottom of your screen
2. Speak — the pill shows a live waveform
3. Stop speaking — after 3 seconds of silence, your audio is sent to a local whisper.cpp server for transcription, and the result is typed into whatever window is focused
4. Press the hotkey again to dismiss early

No cloud services, no subscriptions, no data leaves your network. The pill auto-themes from your Hyprland colors so it matches your rice out of the box.

## Install

```bash
git clone https://github.com/HonorCodes/pillbox.git
cd pillbox
./install.sh
```

The interactive installer handles everything:
- Checks dependencies (and tells you exactly what to install for your distro)
- Installs Pillbox to `~/.local/bin/`
- Sets up the whisper transcription server with your choice of model
- Adds a Hyprland keybinding

**That's it.** The installer walks you through each step.

## Models & Hardware

Pillbox uses OpenAI's Whisper speech recognition model via [whisper.cpp](https://github.com/ggerganov/whisper.cpp). You choose a model size during install — bigger models are more accurate but need more resources.

| Model | Download | VRAM / RAM | Inference | Accuracy | Recommended for |
|-------|----------|-----------|-----------|----------|-----------------|
| `tiny.en` | 75 MB | ~400 MB | ~0.1s | Basic | Raspberry Pi, old laptops, quick notes |
| `base.en` | 148 MB | ~500 MB | ~0.3s | Good | Any modern CPU, daily use without GPU |
| `small.en` | 488 MB | ~1 GB | ~0.8s | Great | Mid-range CPU, or iGPU with Vulkan |
| `large-v3-turbo` | 1.5 GB | ~3 GB | ~0.5s (GPU) | Best | **NVIDIA GPU recommended** (GTX 1060+) |

**Inference times** are approximate for a 5-second audio clip. GPU times assume NVIDIA with CUDA.

**Recommendations:**
- **No GPU?** Use `base.en` — fast enough on any modern CPU (i5/Ryzen 5 or better)
- **NVIDIA GPU?** Use `large-v3-turbo` — best accuracy, runs fast with CUDA
- **AMD GPU?** Use `small.en` — Vulkan support works but is slower than CUDA
- **Laptop / battery life matters?** Use `tiny.en` or `base.en` to minimize power draw

The installer auto-detects your GPU and suggests the right model.

## Usage

| Action | What happens |
|--------|-------------|
| Press hotkey | Pill appears, recording starts |
| Speak | Waveform animates |
| Stop speaking (3s) | Auto-stops, transcribes, types text |
| Press hotkey again | Instant dismiss, transcribes what you said |
| Click stop button | Same as pressing hotkey again |

Text is also copied to your clipboard automatically.

## Configuration

Edit `~/.config/pillbox/pillbox.conf`:

```conf
# Whisper server URL (default: localhost)
server_url = http://localhost:9876

# Silence detection
silence_threshold = -20    # dB — raise for noisy rooms, lower for quiet
silence_duration = 3.0     # seconds before auto-stop

# Pill size (pixels)
width = 90
height = 32
num_bars = 5

# Bottom margin — auto-detected from Hyprland's gaps_out if not set
# margin_bottom = 30
```

## Theming

Pillbox auto-reads your Hyprland color theme from `~/.config/theme/colors.conf` or `~/.config/hypr/colors.conf` and maps:

| Theme variable | Pillbox element |
|---|---|
| `$base` / `$surface` | Pill background |
| `$text` | Waveform bars |
| `$mauve` / `$lavender` | Border + stop button |

Colors auto-contrast (light bars on dark backgrounds, dark on light). Override anything in `pillbox.conf`:

```conf
background = 1a1b26
border = 7aa2f7
```

If no theme is found, Pillbox uses a dark default that works on most setups.

## Remote Server

By default, `install.sh` sets up whisper-server on the same machine. If you have a more powerful machine (e.g., a server with a dedicated GPU), you can run the server there instead:

```bash
# On the server:
sudo ./setup-server.sh --model=large-v3-turbo

# On your laptop, edit config:
# ~/.config/pillbox/pillbox.conf
server_url = http://your-server-ip:9876
```

This gives you the accuracy of the large model without using your laptop's GPU.

## Uninstall

```bash
rm ~/.local/bin/pillbox.py ~/.local/bin/pillbox-toggle.sh
rm -r ~/.config/pillbox/
# Remove the keybinding lines from ~/.config/hypr/hyprland.conf
# If you set up the server:
sudo systemctl disable --now whisper-server
```

## License

MIT
