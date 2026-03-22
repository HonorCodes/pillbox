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
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Gst", "1.0")
gi.require_version("Gtk4LayerShell", "1.0")

from gi.repository import Gdk, GLib, Gst, Gtk, Gtk4LayerShell

# --- Defaults ---
DEFAULTS = {
    "server_url": "http://localhost:9876",
    "silence_threshold": "-20",
    "silence_duration": "3.0",
    "position": "bottom-center",
    "margin": "",
    "width": "90",
    "height": "32",
    "num_bars": "5",
    "opacity_background": "0.75",
    "opacity_border": "0.9",
    "opacity_button": "0.9",
    "opacity_waveform": "0.85",
    "theme_source": "",
    "background": "",
    "foreground": "",
    "border": "",
}

# Position → layer-shell anchor mapping
# Each position sets which edges to anchor to. Unanchored axes center.
POSITIONS = {
    "top-left":      {"top": True,  "bottom": False, "left": True,  "right": False},
    "top-center":    {"top": True,  "bottom": False, "left": False, "right": False},
    "top-right":     {"top": True,  "bottom": False, "left": False, "right": True},
    "center-left":   {"top": False, "bottom": False, "left": True,  "right": False},
    "center":        {"top": False, "bottom": False, "left": False, "right": False},
    "center-right":  {"top": False, "bottom": False, "left": False, "right": True},
    "bottom-left":   {"top": False, "bottom": True,  "left": True,  "right": False},
    "bottom-center": {"top": False, "bottom": True,  "left": False, "right": False},
    "bottom-right":  {"top": False, "bottom": True,  "left": False, "right": True},
}

PIDFILE = "/tmp/pillbox.pid"

REQUIRED_COMMANDS = ["pw-record", "wtype", "wl-copy", "curl"]

# --- Theme defaults (no Hyprland theme found) ---
FALLBACK_COLORS = {
    "background": "0a0a0f",
    "foreground": "cdd6f4",
    "border": "cba6f7",
}


def parse_color(val):
    """Parse a Hyprland color value to (r, g, b) ints (0-255).

    Supports all official Hyprland formats:
      rgba(RRGGBBAA) or rgba(R,G,B,A)  — hex or decimal
      rgb(RRGGBB)    or rgb(R,G,B)     — hex or decimal
      0xAARRGGBB                        — legacy ARGB
      RRGGBB or #RRGGBB                — bare hex
      RGB or #RGB                       — 3-char shorthand

    Returns None on failure.
    """
    val = val.strip().lstrip("#")

    try:
        if val.startswith("rgba(") and val.endswith(")"):
            inner = val[5:-1]
            if "," in inner:
                parts = [p.strip() for p in inner.split(",")]
                return int(parts[0]), int(parts[1]), int(parts[2])
            return int(inner[0:2], 16), int(inner[2:4], 16), int(inner[4:6], 16)

        if val.startswith("rgb(") and val.endswith(")"):
            inner = val[4:-1]
            if "," in inner:
                parts = [p.strip() for p in inner.split(",")]
                return int(parts[0]), int(parts[1]), int(parts[2])
            return int(inner[0:2], 16), int(inner[2:4], 16), int(inner[4:6], 16)

        if val.startswith("0x") and len(val) == 10:
            return int(val[4:6], 16), int(val[6:8], 16), int(val[8:10], 16)

        if len(val) == 3:
            val = val[0] * 2 + val[1] * 2 + val[2] * 2

        if len(val) >= 6:
            return int(val[0:2], 16), int(val[2:4], 16), int(val[4:6], 16)
    except (ValueError, IndexError):
        pass

    return None


def hex_rgb(val, fallback="888888"):
    """Parse a color value, returning (r, g, b) with fallback on failure."""
    result = parse_color(val)
    if result is None:
        print(f"pillbox: invalid color '{val}', using fallback", file=sys.stderr)
        return parse_color(fallback)
    return result


def luminance(val):
    """Relative luminance of a color (0.0 = black, 1.0 = white)."""
    r, g, b = hex_rgb(val)
    return 0.2126 * (r / 255) + 0.7152 * (g / 255) + 0.0722 * (b / 255)


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


def check_dependencies():
    """Verify all required external commands are available."""
    missing = [cmd for cmd in REQUIRED_COMMANDS
               if shutil.which(cmd) is None]
    if missing:
        print(
            f"pillbox: missing required commands: "
            f"{', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)


def detect_hyprland_gaps():
    """Read gaps_out from Hyprland config for default margin."""
    path = os.path.expanduser("~/.config/hypr/hyprland.conf")
    try:
        with open(path) as f:
            for line in f:
                stripped = line.strip()
                if stripped.startswith("gaps_out"):
                    parts = stripped.split("=", 1)
                    if len(parts) == 2:
                        return parts[1].strip()
    except (FileNotFoundError, PermissionError):
        pass
    return "30"


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

    # Auto-detect margin from Hyprland gaps if not explicitly set
    if not config.get("margin"):
        config["margin"] = detect_hyprland_gaps()

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
        if "mauve" in hypr:
            colors["border"] = hypr.get("mauve", colors["border"])
        elif "lavender" in hypr:
            colors["border"] = hypr.get("lavender", colors["border"])

    # Config overrides take priority
    for key in ("background", "foreground", "border"):
        if config.get(key):
            colors[key] = config[key]

    return colors


def build_css(colors, config):
    """Generate GTK CSS from resolved colors and opacity config."""
    bg_r, bg_g, bg_b = hex_rgb(colors["background"])
    br_r, br_g, br_b = hex_rgb(colors["border"])

    bg_alpha = float(config.get("opacity_background", "0.75"))
    br_alpha = float(config.get("opacity_border", "0.9"))
    btn_alpha = float(config.get("opacity_button", "0.9"))

    btn_icon = "white" if luminance(colors["border"]) < 0.75 else "black"

    return f"""
.pillbox-window {{ background: none; }}
.pill-box {{
    background-color: rgba({bg_r}, {bg_g}, {bg_b}, {bg_alpha});
    border-radius: 999px;
    border: 2px solid rgba({br_r}, {br_g}, {br_b}, {br_alpha});
    padding: 4px 10px 4px 12px;
}}
.stop-button {{
    background-color: rgba({br_r}, {br_g}, {br_b}, {btn_alpha});
    border-radius: 999px;
    min-width: 20px; min-height: 20px;
    padding: 0; border: none;
    color: {btn_icon}; font-size: 12px; font-weight: bold;
}}
.stop-button:hover {{
    background-color: rgba({br_r}, {br_g}, {br_b}, {min(btn_alpha + 0.1, 1.0)});
}}
"""


class Pillbox:
    def __init__(self, config, colors):
        self.config = config
        self.colors = colors
        # Waveform color: use foreground from theme, but ensure it
        # contrasts against the background (light bars on dark bg, dark on light)
        bg_lum = luminance(colors["background"])
        if bg_lum < 0.3:
            r, g, b = hex_rgb(colors["foreground"])
            self.fg_rgba = (r / 255, g / 255, b / 255)
        else:
            self.fg_rgba = (0.1, 0.1, 0.1)
        self.waveform_opacity = float(config.get("opacity_waveform", "0.85"))
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
        self.audio_file = None
        self.drawing_area = None
        self.win = None
        self.loop = None

    def run(self):
        with open(PIDFILE, "w") as f:
            f.write(str(os.getpid()))

        css_provider = Gtk.CssProvider()
        css_provider.load_from_string(build_css(self.colors, self.config))
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        width = int(self.config["width"])
        height = int(self.config["height"])
        margin = int(self.config["margin"])
        position = self.config.get("position", "bottom-center")
        anchors = POSITIONS.get(position, POSITIONS["bottom-center"])

        win = Gtk.Window()
        win.set_default_size(width, height)
        win.add_css_class("pillbox-window")

        Gtk4LayerShell.init_for_window(win)
        Gtk4LayerShell.set_layer(win, Gtk4LayerShell.Layer.OVERLAY)
        Gtk4LayerShell.set_namespace(win, "pillbox")
        Gtk4LayerShell.set_keyboard_mode(
            win, Gtk4LayerShell.KeyboardMode.NONE
        )

        # Set anchors based on configured position
        Gtk4LayerShell.set_anchor(win, Gtk4LayerShell.Edge.TOP, anchors["top"])
        Gtk4LayerShell.set_anchor(win, Gtk4LayerShell.Edge.BOTTOM, anchors["bottom"])
        Gtk4LayerShell.set_anchor(win, Gtk4LayerShell.Edge.LEFT, anchors["left"])
        Gtk4LayerShell.set_anchor(win, Gtk4LayerShell.Edge.RIGHT, anchors["right"])

        # Apply margin to the anchored edges
        if anchors["top"]:
            Gtk4LayerShell.set_margin(win, Gtk4LayerShell.Edge.TOP, margin)
        if anchors["bottom"]:
            Gtk4LayerShell.set_margin(win, Gtk4LayerShell.Edge.BOTTOM, margin)
        if anchors["left"]:
            Gtk4LayerShell.set_margin(win, Gtk4LayerShell.Edge.LEFT, margin)
        if anchors["right"]:
            Gtk4LayerShell.set_margin(win, Gtk4LayerShell.Edge.RIGHT, margin)

        pill_box = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL, spacing=6
        )
        pill_box.add_css_class("pill-box")
        pill_box.set_valign(Gtk.Align.CENTER)

        self.drawing_area = Gtk.DrawingArea()
        self.drawing_area.set_size_request(width - 46, height - 12)
        self.drawing_area.set_draw_func(self._draw_waveform)
        pill_box.append(self.drawing_area)

        stop_btn = Gtk.Button(label="\u25A0")
        stop_btn.add_css_class("stop-button")
        stop_btn.set_valign(Gtk.Align.CENTER)
        stop_btn.connect("clicked", lambda _: self._shutdown())
        pill_box.append(stop_btn)

        win.set_child(pill_box)
        win.present()
        self.win = win

        GLib.unix_signal_add(
            GLib.PRIORITY_DEFAULT, signal.SIGTERM,
            self._on_sigterm,
        )
        GLib.unix_signal_add(
            GLib.PRIORITY_DEFAULT, signal.SIGINT,
            self._on_sigterm,
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

        fd, self.audio_file = tempfile.mkstemp(
            suffix=".wav", prefix="pillbox-",
        )
        os.close(fd)

        self.recorder = subprocess.Popen(
            [
                "pw-record", "--rate", "16000",
                "--channels", "1", "--format", "s16",
                self.audio_file,
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
                    self._shutdown()

    def _draw_waveform(self, area, cr, width, height):
        bar_width = max(3, (width - (self.num_bars - 1) * 3) / self.num_bars)
        gap = 3
        r, g, b = self.fg_rgba
        base_alpha = self.waveform_opacity
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
            # Scale opacity with audio level for animation effect
            alpha = (0.3 + level * 0.7) * base_alpha
            cr.set_source_rgba(r, g, b, alpha)
            cr.fill()

    def _on_sigterm(self):
        """Signal handler for SIGTERM/SIGINT."""
        self._shutdown()
        return False

    def _shutdown(self):
        """Stop recording, send to server, type result."""
        if self.stopping:
            return
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

        # Only transcribe if speech was actually detected
        if self.heard_speech:
            threading.Thread(target=self._transcribe, daemon=True).start()
        else:
            self._cleanup_audio()
            GLib.idle_add(self._quit_now)

    def _cleanup_audio(self):
        """Remove the temporary audio file if it exists."""
        if self.audio_file:
            try:
                os.unlink(self.audio_file)
            except OSError:
                pass
            self.audio_file = None

    def _transcribe(self):
        """Send WAV to whisper-server and type the result."""
        text = ""
        try:
            if (
                self.audio_file
                and os.path.exists(self.audio_file)
                and os.path.getsize(self.audio_file) > 100
            ):
                result = subprocess.run(
                    [
                        "curl", "-s", "--max-time", "30",
                        "-F", f"file=@{self.audio_file}",
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
            self._cleanup_audio()

        if text:
            subprocess.Popen(
                ["wl-copy", "--", text],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            # Allow compositor to refocus the previous window
            # after hiding the overlay
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
    check_dependencies()
    Gst.init(None)
    config = load_config()
    colors = resolve_colors(config)
    pill = Pillbox(config, colors)
    pill.run()


if __name__ == "__main__":
    main()
