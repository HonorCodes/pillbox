#!/usr/bin/env python3
"""
Pillbox — Voice dictation for Hyprland.

A glassmorphic pill overlay that records your voice, sends it to a
whisper-server for transcription, and types the result into the
focused window. Auto-themes from your Hyprland color config.

Requirements: GTK4, gtk4-layer-shell, GStreamer (gst-plugins-good),
              PipeWire (pw-record), wtype, wl-copy, curl
"""

import gi
import json
import math
import os
import signal
import subprocess
import sys
import threading
import time

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Gst", "1.0")
gi.require_version("Gtk4LayerShell", "1.0")

from gi.repository import Gdk, GLib, Gst, Gtk, Gtk4LayerShell

# --- Defaults ---
DEFAULTS = {
    "server_url": "http://localhost:8080",
    "silence_threshold": "-20",
    "silence_duration": "3.0",
    "position": "bottom",
    "margin_bottom": "30",
    "width": "100",
    "height": "40",
    "num_bars": "5",
    "theme_source": "",
    "background": "",
    "foreground": "",
    "accent": "",
    "border": "",
}

PIDFILE = "/tmp/pillbox.pid"
AUDIO_FILE = "/tmp/pillbox.wav"

# --- Theme defaults (no Hyprland theme found) ---
FALLBACK_COLORS = {
    "background": "0a0a0f",
    "foreground": "cdd6f4",
    "accent": "f38ba8",
    "border": "45475a",
}


def hex_to_rgba(hexval, alpha=1.0):
    """Convert a hex color (without #) to rgba() CSS string."""
    hexval = hexval.lstrip("#")
    r = int(hexval[0:2], 16) / 255
    g = int(hexval[2:4], 16) / 255
    b = int(hexval[4:6], 16) / 255
    return r, g, b, alpha


def load_hyprland_colors(path):
    """Parse Hyprland-style $variable = hexvalue color config."""
    colors = {}
    try:
        with open(os.path.expanduser(path)) as f:
            for line in f:
                line = line.strip()
                if line.startswith("$") and "=" in line:
                    key, val = line.split("=", 1)
                    colors[key.strip().lstrip("$")] = val.strip()
    except (FileNotFoundError, PermissionError):
        pass
    return colors


def find_theme_source():
    """Auto-detect Hyprland theme/colors config."""
    candidates = [
        "~/.config/theme/colors.conf",
        "~/.config/hypr/colors.conf",
        "~/.config/hypr/themes/colors.conf",
    ]
    for c in candidates:
        path = os.path.expanduser(c)
        if os.path.isfile(path):
            return path
    return ""


def load_config():
    """Load pillbox.conf (Hyprland-style key = value)."""
    config = dict(DEFAULTS)
    config_path = os.path.expanduser("~/.config/pillbox/pillbox.conf")
    try:
        with open(config_path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    key, val = line.split("=", 1)
                    config[key.strip()] = val.strip()
    except FileNotFoundError:
        pass
    return config


def resolve_colors(config):
    """Resolve final colors from theme + config overrides."""
    colors = dict(FALLBACK_COLORS)

    # Try loading Hyprland theme
    theme_path = config.get("theme_source") or find_theme_source()
    if theme_path:
        hypr = load_hyprland_colors(theme_path)
        if "base" in hypr or "surface" in hypr:
            colors["background"] = hypr.get("base", hypr.get("surface", colors["background"]))
        if "text" in hypr:
            colors["foreground"] = hypr.get("text", colors["foreground"])
        if "red" in hypr:
            colors["accent"] = hypr.get("red", colors["accent"])
        if "overlay" in hypr:
            colors["border"] = hypr.get("overlay", colors["border"])

    # Config overrides take priority
    for key in ("background", "foreground", "accent", "border"):
        if config.get(key):
            colors[key] = config[key]

    return colors


def build_css(colors):
    """Generate GTK CSS from resolved colors."""
    bg = colors["background"]
    border = colors["border"]
    accent = colors["accent"]

    return f"""
.pillbox-window {{ background: none; }}
.pill-box {{
    background-color: rgba({int(bg[0:2],16)}, {int(bg[2:4],16)}, {int(bg[4:6],16)}, 0.75);
    border-radius: 20px;
    border: 1px solid rgba({int(border[0:2],16)}, {int(border[2:4],16)}, {int(border[4:6],16)}, 0.4);
    padding: 4px 10px 4px 12px;
}}
.stop-button {{
    background-color: rgba({int(accent[0:2],16)}, {int(accent[2:4],16)}, {int(accent[4:6],16)}, 0.9);
    border-radius: 12px;
    min-width: 24px; min-height: 24px;
    padding: 0; border: none;
    color: white; font-size: 12px; font-weight: bold;
}}
.stop-button:hover {{
    background-color: rgba({int(accent[0:2],16)}, {int(accent[2:4],16)}, {int(accent[4:6],16)}, 1.0);
}}
"""


class Pillbox:
    def __init__(self, config, colors):
        self.config = config
        self.colors = colors
        self.fg_rgba = hex_to_rgba(colors["foreground"])
        self.num_bars = int(config["num_bars"])
        self.levels = [0.0] * self.num_bars
        self.silence_threshold = float(config["silence_threshold"])
        self.silence_duration = float(config["silence_duration"])
        self.server_url = config["server_url"]
        self.silence_start = None
        self.heard_speech = False
        self.recording = False
        self.stopping = False
        self.pipeline = None
        self.recorder = None
        self.drawing_area = None
        self.win = None
        self.loop = None

    def run(self):
        with open(PIDFILE, "w") as f:
            f.write(str(os.getpid()))

        css_provider = Gtk.CssProvider()
        css_provider.load_from_string(build_css(self.colors))
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        width = int(self.config["width"])
        height = int(self.config["height"])
        margin = int(self.config["margin_bottom"])

        win = Gtk.Window()
        win.set_default_size(width, height)
        win.add_css_class("pillbox-window")

        Gtk4LayerShell.init_for_window(win)
        Gtk4LayerShell.set_layer(win, Gtk4LayerShell.Layer.OVERLAY)
        Gtk4LayerShell.set_namespace(win, "pillbox")
        Gtk4LayerShell.set_anchor(win, Gtk4LayerShell.Edge.BOTTOM, True)
        Gtk4LayerShell.set_margin(win, Gtk4LayerShell.Edge.BOTTOM, margin)
        Gtk4LayerShell.set_keyboard_mode(
            win, Gtk4LayerShell.KeyboardMode.NONE
        )
        Gtk4LayerShell.set_anchor(win, Gtk4LayerShell.Edge.LEFT, False)
        Gtk4LayerShell.set_anchor(win, Gtk4LayerShell.Edge.RIGHT, False)

        pill_box = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL, spacing=6
        )
        pill_box.add_css_class("pill-box")
        pill_box.set_valign(Gtk.Align.CENTER)

        self.drawing_area = Gtk.DrawingArea()
        self.drawing_area.set_size_request(width - 56, height - 14)
        self.drawing_area.set_draw_func(self._draw_waveform)
        pill_box.append(self.drawing_area)

        stop_btn = Gtk.Button(label="\u25A0")
        stop_btn.add_css_class("stop-button")
        stop_btn.set_valign(Gtk.Align.CENTER)
        stop_btn.connect("clicked", lambda _: self._stop())
        pill_box.append(stop_btn)

        win.set_child(pill_box)
        win.present()
        self.win = win

        GLib.unix_signal_add(
            GLib.PRIORITY_DEFAULT, signal.SIGTERM, self._stop
        )
        GLib.unix_signal_add(
            GLib.PRIORITY_DEFAULT, signal.SIGINT, self._stop
        )

        self._start()

        self.loop = GLib.MainLoop()
        self.loop.run()

    def _start(self):
        """Start GStreamer visualizer and pw-record."""
        self.pipeline = Gst.parse_launch(
            "pulsesrc ! audioconvert ! audioresample ! "
            "audio/x-raw,rate=16000,channels=1,format=S16LE ! "
            "level interval=50000000 ! fakesink"
        )
        self.bus = self.pipeline.get_bus()
        self.pipeline.set_state(Gst.State.PLAYING)
        self.recording = True
        self.silence_start = None
        self.heard_speech = False

        self.recorder = subprocess.Popen(
            [
                "pw-record", "--rate", "16000",
                "--channels", "1", "--format", "s16",
                AUDIO_FILE,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        GLib.timeout_add(50, self._poll_and_draw)

    def _poll_and_draw(self):
        """Poll GStreamer bus for level data and redraw."""
        if not self.recording:
            return False
        while True:
            msg = self.bus.pop_filtered(
                Gst.MessageType.ELEMENT | Gst.MessageType.ERROR
            )
            if msg is None:
                break
            if msg.type == Gst.MessageType.ERROR:
                err, _ = msg.parse_error()
                print(f"pillbox: GStreamer error: {err.message}", file=sys.stderr)
                self._quit_now()
                return False
            struct = msg.get_structure()
            if struct and struct.get_name() == "level":
                self._handle_level(struct)
        if self.drawing_area:
            self.drawing_area.queue_draw()
        return self.recording

    def _handle_level(self, struct):
        """Update waveform bars and check for silence."""
        rms_values = struct.get_value("rms")
        if not rms_values:
            return
        rms_db = rms_values[0] if rms_values else -100.0
        normalized = max(0.0, min(1.0, (rms_db + 60.0) / 60.0))
        self.levels.pop(0)
        self.levels.append(normalized)

        if rms_db >= self.silence_threshold:
            self.heard_speech = True
            self.silence_start = None
        elif self.heard_speech:
            if self.silence_start is None:
                self.silence_start = time.monotonic()
            elif time.monotonic() - self.silence_start >= self.silence_duration:
                if self.recording and not self.stopping:
                    self._stop()

    def _draw_waveform(self, area, cr, width, height):
        bar_width = max(3, (width - (self.num_bars - 1) * 3) / self.num_bars)
        gap = 3
        r, g, b, _ = self.fg_rgba
        for i, level in enumerate(self.levels):
            x = i * (bar_width + gap)
            bar_h = 4 + level * (height - 8)
            y = (height - bar_h) / 2
            rad = min(bar_width / 2, bar_h / 2, 3)
            cr.new_sub_path()
            cr.arc(x + rad, y + rad, rad, math.pi, 1.5 * math.pi)
            cr.arc(x + bar_width - rad, y + rad, rad, 1.5 * math.pi, 0)
            cr.arc(x + bar_width - rad, y + bar_h - rad, rad, 0, 0.5 * math.pi)
            cr.arc(x + rad, y + bar_h - rad, rad, 0.5 * math.pi, math.pi)
            cr.close_path()
            cr.set_source_rgba(r, g, b, 0.5 + level * 0.5)
            cr.fill()

    def _stop(self):
        """Stop recording, send to server, type result."""
        if self.stopping:
            return False
        self.stopping = True
        self.recording = False

        if self.recorder:
            self.recorder.terminate()
            try:
                self.recorder.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.recorder.kill()
            self.recorder = None

        if self.pipeline:
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None

        try:
            os.unlink(PIDFILE)
        except OSError:
            pass

        if self.win:
            self.win.set_visible(False)

        threading.Thread(target=self._transcribe, daemon=True).start()
        return False

    def _transcribe(self):
        """Send WAV to whisper-server and type the result."""
        text = ""
        try:
            if (
                os.path.exists(AUDIO_FILE)
                and os.path.getsize(AUDIO_FILE) > 100
            ):
                result = subprocess.run(
                    [
                        "curl", "-s", "--max-time", "30",
                        "-F", f"file=@{AUDIO_FILE}",
                        f"{self.server_url}/inference",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=35,
                )
                if result.returncode == 0 and result.stdout.strip():
                    data = json.loads(result.stdout)
                    raw = data.get("text", "")
                    text = " ".join(raw.split()).strip()
        except Exception as e:
            print(f"pillbox: transcription error: {e}", file=sys.stderr)
        finally:
            try:
                os.unlink(AUDIO_FILE)
            except OSError:
                pass

        if text:
            subprocess.Popen(
                ["wl-copy", "--", text],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            time.sleep(0.15)
            subprocess.run(
                ["wtype", "--", text],
                capture_output=True, timeout=5,
            )

        GLib.idle_add(self._quit_now)

    def _quit_now(self):
        try:
            os.unlink(PIDFILE)
        except OSError:
            pass
        if self.loop:
            self.loop.quit()
        return False


def main():
    Gst.init(None)
    config = load_config()
    colors = resolve_colors(config)
    pill = Pillbox(config, colors)
    pill.run()


if __name__ == "__main__":
    main()
