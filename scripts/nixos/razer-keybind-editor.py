import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import threading

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk
from evdev import ecodes


CSS = b"""
* { font-family: Antonio; font-size: 17px; }
window, .black { background: #000; color: #70b5ff; }
label { color: #70b5ff; }
.title { color: #ffbb33; font-size: 44px; font-weight: bold; }
.section { color: #ffbb33; font-size: 23px; font-weight: bold; }
.muted { color: #bec2cf; font-size: 15px; }
.masthead { background: #000; border-radius: 0 0 0 44px; padding: 8px 20px 16px 28px; }
.registry { background: #ffbb33; border-bottom: 5px solid #000; padding: 12px 12px 8px; }
.registry label { color: #000; }
.registry-number { font-size: 48px; font-weight: bold; }
.upper-elbow { background: #828cad; border-radius: 0 0 0 100px; min-height: 50px; }
.lower-elbow { border-radius: 100px 0 0 0; padding-top: 55px; }
.content-frame { background: #828cad; padding-top: 22px; }
.content-cutout { background: #000; border-radius: 44px 0 0 0; padding: 24px 0 0 24px; }
.silver { background: #828cad; }
.gold { background: #ffbb33; }
.blue { background: #2288ff; }
.pumpkin { background: #ffe1ca; }
.silver label, .gold label, .pumpkin label { color: #000; }
.masthead .title { color: #ffbb33; }
.masthead .muted { color: #bec2cf; }
.railblock { padding: 14px 12px; }
.railblock label { color: #000; }
button { background: #99ccff; border: none; border-radius: 24px; padding: 10px 20px;
  box-shadow: none; text-shadow: none; font-weight: bold; }
button label { color: #000; }
button:hover { background: #c6e2ff; }
button:focus { outline: 2px solid #ffbb33; outline-offset: 2px; }
.primary { background: #ffbb33; }
.primary:hover { background: #ffcf75; }
button:disabled { background: #282b36; }
button:disabled label { color: #9298aa; }
.nav { background: #828cad; border-radius: 0; padding: 12px; min-height: 50px; }
.nav label { font-size: 20px; }
.nav:hover { background: #969fbc; }
.nav.lower-elbow { border-radius: 100px 0 0 0; padding-top: 52px; }
.nav.primary { background: #ffbb33; }
.nav:focus { outline: none; box-shadow: inset 0 0 0 2px #99ccff; }
combobox button { background: #99ccff; border: 2px solid #828cad; border-radius: 0; padding: 8px 12px; }
combobox cellview { color: #000; }
entry { background: #000; color: #e6f2ff; border: 2px solid #828cad; padding: 8px; }
menu, menuitem, popover { background: #99ccff; color: #000; }
menuitem label, menuitem cellview { color: #000; }
menuitem:hover { background: #ffbb33; }
checkbutton { color: #99ccff; padding: 3px; }
checkbutton check { border: 2px solid #828cad; background: #000; }
checkbutton check:checked { background: #ffbb33; color: #000; }
.panel { background: #000; border-top: 8px solid #ffbb33; padding: 12px 0 0; }
separator { background: #828cad; min-height: 4px; }
"""

NAMES = {"mouse": "BASILISK V3 PRO 35K", "keypad": "TARTARUS PRO", "keyboard": "HUNTSMAN V2 ANALOG"}


def short(key):
    return key.removeprefix("KEY_").replace("LEFT", "L ").replace("RIGHT", "R ").replace("_", " ")


def controls(device):
    if device == "mouse":
        return [
            ("ScrollButton", "Wheel click", 320, 82, 80, 76),
            ("RepeatScrollLeft", "Tilt left", 224, 94, 90, 54),
            ("RepeatScrollRight", "Tilt right", 406, 94, 90, 54),
            ("DKM_M_106", "Scroll mode", 306, 174, 106, 52),
            ("DKM_SB_03", "DPI button", 306, 239, 106, 52),
            ("Button5", "Forward", 131, 223, 127, 56),
            ("Button4", "Back", 118, 291, 127, 56),
            ("DKM_SB_02", "Clutch", 153, 155, 127, 56),
            ("DKM_SB_01", "Underside", 523, 401, 140, 58),
        ]
    if device == "keypad":
        rows = ["1 2 3 4 5", "TAB Q W E R", "CAPS_LOCK A S D F", "LEFT_SHIFT Z X C"]
        result = []
        number = 1
        for y, row in enumerate(rows):
            for x, key in enumerate(row.split()):
                result.append(("KEY_" + key, f"{number:02d} · {short('KEY_' + key)}", 42+x*93, 55+y*81, 84, 70))
                number += 1
        result.extend([
            ("ScrollUp", "Wheel up", 414, 298, 84, 40),
            ("ScrollDown", "Wheel down", 414, 343, 84, 40),
            ("KEY_LEFT_ALT", "Thumb", 544, 151, 105, 52),
            ("KEY_UP_ARROW", "Up", 553, 230, 60, 50),
            ("KEY_LEFT_ARROW", "Left", 500, 284, 60, 50),
            ("KEY_RIGHT_ARROW", "Right", 614, 284, 60, 50),
            ("KEY_DOWN_ARROW", "Down", 553, 338, 60, 50),
            ("KEY_SPACEBAR", "20 · Space", 521, 416, 156, 64),
        ])
        return result
    rows = [
        "ESC F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12 SYSRQ SCROLLLOCK PAUSE",
        "GRAVE 1 2 3 4 5 6 7 8 9 0 MINUS EQUAL BACKSPACE INSERT HOME PAGEUP NUMLOCK KPSLASH KPASTERISK KPMINUS",
        "TAB Q W E R T Y U I O P LEFTBRACE RIGHTBRACE BACKSLASH DELETE END PAGEDOWN KP7 KP8 KP9 KPPLUS",
        "CAPS_LOCK A S D F G H J K L SEMICOLON APOSTROPHE ENTER _ _ _ _ KP4 KP5 KP6 _",
        "LEFT_SHIFT Z X C V B N M COMMA DOT SLASH RIGHT_SHIFT _ _ _ UP _ KP1 KP2 KP3 KPENTER",
        "LEFT_CTRL LEFT_META LEFT_ALT _ _ SPACEBAR _ _ _ RIGHT_ALT RIGHT_META COMPOSE RIGHT_CTRL _ LEFT DOWN RIGHT KP0 _ KPDOT _",
    ]
    labels = {"BACKSPACE": "Bksp", "LEFTBRACE": "[", "RIGHTBRACE": "]", "BACKSLASH": "\\",
              "SEMICOLON": ";", "APOSTROPHE": "'", "GRAVE": "`", "COMMA": ",", "DOT": ".",
              "SLASH": "/", "MINUS": "-", "EQUAL": "=", "CAPS_LOCK": "Caps", "SPACEBAR": "Space",
              "LEFT_SHIFT": "Shift", "RIGHT_SHIFT": "Shift", "LEFT_CTRL": "Ctrl", "RIGHT_CTRL": "Ctrl",
              "LEFT_ALT": "Alt", "RIGHT_ALT": "Alt", "LEFT_META": "Meta", "RIGHT_META": "Meta",
              "PAGEUP": "PgUp", "PAGEDOWN": "PgDn", "SCROLLLOCK": "ScrLk", "NUMLOCK": "Num",
              "SYSRQ": "PrtSc", "COMPOSE": "Menu", "UP": "Up", "DOWN": "Dn", "LEFT": "Lt", "RIGHT": "Rt"}
    result = []
    for y, row in enumerate(rows):
        for x, key in enumerate(row.split()):
            if key != "_":
                result.append(("KEY_"+key, labels.get(key, key.removeprefix("KP")), 16+x*33, 104+y*49, 30, 44))
    return result


class DeviceCanvas(Gtk.DrawingArea):
    def __init__(self, editor):
        super().__init__()
        self.editor = editor
        self.set_size_request(620, 440)
        self.set_hexpand(True)
        self.set_vexpand(True)
        self.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        self.connect("draw", self.draw)
        self.connect("button-press-event", self.click)

    def geometry(self):
        scale = min(self.get_allocated_width()/720, self.get_allocated_height()/540)
        return scale, (self.get_allocated_width()-720*scale)/2, (self.get_allocated_height()-540*scale)/2

    def click(self, widget, event):
        scale, ox, oy = self.geometry()
        x, y = (event.x-ox)/scale, (event.y-oy)/scale
        for key, label, bx, by, w, h in controls(self.editor.device):
            if bx <= x <= bx+w and by <= y <= by+h:
                self.editor.control.set_active_id(key)
                self.editor.sound()
                break

    def draw(self, widget, cr):
        scale, ox, oy = self.geometry()
        cr.translate(ox, oy)
        cr.scale(scale, scale)
        cr.set_source_rgb(.04, .07, .10)
        cr.set_line_width(.5)
        for x in range(0, 721, 24):
            cr.move_to(x, 0); cr.line_to(x, 540)
        for y in range(0, 541, 24):
            cr.move_to(0, y); cr.line_to(720, y)
        cr.stroke()
        cr.set_source_rgb(.025, .04, .06)
        if self.editor.device == "mouse":
            cr.move_to(294, 45)
            cr.curve_to(165, 42, 237, 200, 183, 315)
            cr.curve_to(130, 393, 188, 508, 351, 507)
            cr.curve_to(579, 510, 496, 246, 498, 145)
            cr.curve_to(505, 62, 421, 38, 294, 45)
        elif self.editor.device == "keypad":
            cr.move_to(34, 38); cr.line_to(505, 38); cr.line_to(505, 216)
            cr.line_to(690, 216); cr.line_to(690, 495); cr.line_to(245, 523)
            cr.curve_to(95, 504, 16, 382, 34, 38)
        else:
            cr.rectangle(7, 90, 704, 355)
        cr.close_path(); cr.fill_preserve()
        cr.set_source_rgb(.60, .80, 1); cr.set_line_width(2); cr.stroke()
        if self.editor.device == "mouse":
            cr.move_to(350, 47); cr.line_to(350, 78)
            cr.move_to(254, 174); cr.curve_to(275, 175, 280, 340, 350, 342)
            cr.curve_to(426, 340, 442, 185, 485, 179)
            cr.move_to(227, 390); cr.curve_to(257, 455, 397, 491, 468, 421)
            cr.set_source_rgb(.25, .38, .48); cr.stroke()
        for key, label, x, y, w, h in controls(self.editor.device):
            active = key == self.editor.control.get_active_id()
            mapped = self.editor.mapping(key) is not None
            cr.set_source_rgb(*((1, .73, .20) if active else (.025, .04, .06)))
            cr.rectangle(x, y, w, h); cr.fill_preserve()
            cr.set_source_rgb(*((1, .73, .20) if active else (.60, .80, 1) if mapped else (.40, .44, .54)))
            cr.set_line_width(2 if active else 1); cr.stroke()
            cr.set_source_rgb(*((.05, .08, .13) if active else (.87, .93, .98)))
            self.text(cr, label, x+w/2, y+h*.42, min(13, w/len(label)*1.5))
            assignment = self.editor.describe(self.editor.mapping(key))
            if self.editor.device == "keyboard":
                if mapped:
                    cr.rectangle(x+w/2-2, y+h*.78, 4, 4); cr.fill()
            else:
                self.text(cr, assignment[:21], x+w/2, y+h*.79, min(11, w/max(1,len(assignment[:21]))*1.6))
        cr.set_source_rgb(.57, .67, .77)
        self.text(cr, "DEVICE SCHEMATIC  /  SELECT A CONTROL", 360, 535, 11)

    @staticmethod
    def text(cr, text, x, y, size):
        cr.select_font_face("Antonio")
        cr.set_font_size(size)
        width = cr.text_extents(text)[2]
        cr.move_to(x-width/2, y)
        cr.show_text(text)


class Editor(Gtk.Application):
    def __init__(self, controller, model, sounds=None):
        super().__init__(application_id="local.dotfiles.RazerKeybinds", flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.controller, self.model = controller, model
        self.device = "mouse"
        self.data = None
        self.window = None
        self.recording = False
        self.sounds = Path(sounds) if sounds else None
        self.playing = None
        self.preferences = Path(GLib.get_user_config_dir()) / "razer-keybind-editor/preferences.json"
        try:
            self.muted = bool(json.loads(self.preferences.read_text()).get("muted", False))
        except (OSError, ValueError):
            self.muted = False
        self.connect("activate", self.activate)
        self.connect("shutdown", lambda *args: self.stop_sound())

    def stop_sound(self):
        if self.playing and self.playing.poll() is None:
            self.playing.terminate()
        self.playing = None

    def sound(self, cue="intrepid-key"):
        if not self.sounds or self.muted:
            return
        if self.playing and self.playing.poll() is None:
            return
        try:
            self.playing = subprocess.Popen(["pw-play", "--volume", "0.15", "--media-role", "Notification",
                                             str(self.sounds / f"{cue}.mp3")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass

    def toggle_sound(self, button):
        self.muted = not self.muted
        self.stop_sound()
        button.set_label("SOUND OFF" if self.muted else "SOUND ON")
        self.preferences.parent.mkdir(parents=True, exist_ok=True)
        self.preferences.write_text(json.dumps({"muted": self.muted}))
        self.sound()

    def command(self, *args, payload=None):
        result = subprocess.run([self.controller, *args], input=json.dumps(payload) if payload else None,
                                capture_output=True, text=True, timeout=180)
        if result.returncode:
            raise RuntimeError(result.stderr.strip().splitlines()[-1] if result.stderr.strip() else "Command failed")
        return result.stdout.strip()

    def button(self, label, callback, primary=False):
        button = Gtk.Button(label=label)
        if primary:
            button.get_style_context().add_class("primary")
        button.connect("clicked", callback)
        button.connect("clicked", lambda _: self.sound())
        return button

    def label(self, text, style=None):
        label = Gtk.Label(label=text, xalign=0)
        label.set_line_wrap(True)
        label.set_max_width_chars(40)
        if style:
            label.get_style_context().add_class(style)
        return label

    def activate(self, app):
        if self.window:
            self.window.present()
            return
        css = Gtk.CssProvider(); css.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        GLib.set_prgname("razer-keybind-editor")
        self.window = Gtk.ApplicationWindow(application=self, title="Razer • Input Control")
        self.window.set_default_size(1240, 780)
        self.window.connect("key-press-event", self.keypress)
        self.window.connect("key-release-event", self.keyrelease)
        self.window.connect("focus-out-event", lambda *args: self.cancel_capture())
        self.window.connect("destroy", lambda *args: setattr(self, "window", None))
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        root.set_border_width(12); self.window.add(root)
        header = Gtk.Box(spacing=0)
        cap = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        cap.set_size_request(150, -1)
        registry = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        registry.get_style_context().add_class("registry")
        registry.pack_start(self.label("47 / RC", "registry-number"), False, False, 0)
        registry.pack_start(self.label("PERIPHERAL SUBSYSTEM"), False, False, 0)
        cap.pack_start(registry, True, True, 0)
        elbow = Gtk.Box(); elbow.get_style_context().add_class("upper-elbow")
        cap.pack_end(elbow, False, False, 0); header.pack_start(cap, False, False, 0)
        headright = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        headright.get_style_context().add_class("silver")
        title = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        title.get_style_context().add_class("masthead")
        title.pack_start(self.label("INTREPID-CLASS INTERFACE  /  RAZER DEVICE CONTROL", "muted"), False, False, 0)
        title.pack_start(self.label("PERIPHERAL CONTROL ARRAY", "title"), False, False, 0)
        title.pack_start(self.label("UNIFIED KEY ASSIGNMENTS  •  THREE DEVICES / ONE PROFILE", "muted"), False, False, 0)
        headright.pack_start(title, True, True, 0)
        headright.pack_end(self.stripe(), False, False, 0)
        header.pack_start(headright, True, True, 0); root.pack_start(header, False, False, 0)
        divider = Gtk.Box(); divider.set_size_request(-1, 10); root.pack_start(divider, False, False, 0)
        frame = Gtk.Box(spacing=0)
        tabs = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        tabs.set_size_request(150, -1)
        self.tabs = {}
        for i, (kind, name) in enumerate(NAMES.items()):
            b = self.button(["01 / BASILISK", "02 / TARTARUS", "03 / HUNTSMAN"][i], lambda _, d=kind: self.change_device(d))
            b.get_style_context().add_class("nav")
            if i == 0:
                b.get_style_context().add_class("lower-elbow")
            self.tabs[kind] = b; tabs.pack_start(b, False, False, 0)
        for style, text, expand in [("silver", "INPUT MATRIX", True), ("gold", "PROFILE STORAGE\nLOCAL / PERSISTENT", False), ("silver", "LCARS\n47-RAZER", True)]:
            segment = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            segment.get_style_context().add_class(style); segment.get_style_context().add_class("railblock")
            label = self.label(text); label.set_valign(Gtk.Align.END)
            segment.pack_end(label, False, False, 0); tabs.pack_start(segment, expand, expand, 0)
        frame.pack_start(tabs, False, False, 0)
        contentframe = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        contentframe.get_style_context().add_class("content-frame")
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        content.get_style_context().add_class("content-cutout")
        contentframe.pack_start(content, True, True, 0); frame.pack_start(contentframe, True, True, 0)
        root.pack_start(frame, True, True, 0)
        toolbar = Gtk.Box(spacing=12)
        self.profiles = Gtk.ComboBoxText(); self.profiles.set_hexpand(True)
        self.profiles.connect("changed", self.profile_changed)
        toolbar.pack_start(self.profiles, True, True, 0)
        toolbar.pack_start(self.button("DUPLICATE", self.duplicate), False, False, 0)
        toolbar.pack_start(self.button("RELOAD", lambda *args: self.load()), False, False, 0)
        toolbar.pack_start(self.button("SOUND OFF" if self.muted else "SOUND ON", self.toggle_sound), False, False, 0)
        toolbar.pack_start(self.button("APPLY PROFILE", self.apply_profile, True), False, False, 0)
        content.pack_start(toolbar, False, False, 0)
        self.toolbar = toolbar
        self.device_heading = self.label(NAMES[self.device], "section")
        content.pack_start(self.device_heading, False, False, 0)
        body = Gtk.Box(spacing=20)
        self.canvas = DeviceCanvas(self); body.pack_start(self.canvas, True, True, 0)
        panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        panel.get_style_context().add_class("panel"); panel.set_size_request(310, -1)
        panel.pack_start(self.label("CONTROL ASSIGNMENT", "section"), False, False, 0)
        self.control = Gtk.ComboBoxText(); self.control.connect("changed", self.selection_changed)
        panel.pack_start(self.control, False, False, 0)
        self.shift = Gtk.CheckButton(label="HyperShift layer")
        self.shift.connect("toggled", self.selection_changed); panel.pack_start(self.shift, False, False, 0)
        self.current = self.label(""); self.current.set_max_width_chars(32)
        panel.pack_start(self.current, False, False, 0)
        panel.pack_start(Gtk.Separator(), False, False, 0)
        self.kind = Gtk.ComboBoxText()
        for key, name in [("key", "Keyboard key / chord"), ("hypershift", "Hold HyperShift"), ("default", "Default / inherit base layer")]:
            self.kind.append(key, name)
        self.kind.set_active(0); self.kind.connect("changed", self.kind_changed)
        panel.pack_start(self.kind, False, False, 0)
        self.key = Gtk.Entry(placeholder_text="KEY_A, KEY_F5, KEY_LEFTALT…")
        completions = Gtk.ListStore(str)
        for key in sorted(k for k in ecodes.ecodes if k.startswith("KEY_")):
            completions.append([key])
        completion = Gtk.EntryCompletion(); completion.set_model(completions); completion.set_text_column(0)
        self.key.set_completion(completion); panel.pack_start(self.key, False, False, 0)
        self.capture = self.button("RECORD KEY / CHORD", self.start_capture)
        panel.pack_start(self.capture, False, False, 0)
        self.modifiers = {}
        grid = Gtk.Grid(column_spacing=8, row_spacing=2)
        for i, key in enumerate(self.model.MODIFIERS):
            check = Gtk.CheckButton(label=short(key)); self.modifiers[key] = check
            grid.attach(check, i//4, i%4, 1, 1)
        self.modgrid = grid; panel.pack_start(grid, False, False, 0)
        self.save = self.button("SAVE ASSIGNMENT", self.save_binding, True)
        panel.pack_start(self.save, False, False, 0)
        panel.pack_start(self.label("Saves locally. Apply profile activates all three devices. Existing macros are preserved; replacing an assignment replaces its macro.", "muted"), False, False, 0)
        self.panel = panel
        body.pack_start(panel, False, False, 0); content.pack_start(body, True, True, 0)
        self.status = self.label("Loading profiles…", "muted"); self.status.set_max_width_chars(100)
        content.pack_start(self.status, False, False, 0)
        content.pack_end(self.stripe(lower=True), False, False, 0)
        self.window.show_all(); self.load()

    def stripe(self, lower=False):
        stripe = Gtk.Box(spacing=5)
        stripe.get_style_context().add_class("black")
        stripe.set_size_request(-1, 22)
        for style, width in [("silver", 90), ("pumpkin" if lower else "gold", 150), ("blue", 42), ("silver", 0)]:
            segment = Gtk.Box(); segment.get_style_context().add_class(style)
            segment.set_size_request(width, 22); stripe.pack_start(segment, width == 0, width == 0, 0)
        return stripe

    def work(self, operation, success):
        self.toolbar.set_sensitive(False); self.panel.set_sensitive(False)
        def worker():
            try:
                result = operation()
                GLib.idle_add(done, result, None)
            except Exception as error:
                GLib.idle_add(done, None, str(error))
        def done(result, error):
            if not self.window:
                return False
            self.toolbar.set_sensitive(True); self.panel.set_sensitive(True)
            if error:
                self.status.set_text(error)
                self.sound("denied")
            else:
                success(result)
            return False
        threading.Thread(target=worker, daemon=True).start()

    def load(self, target=None, message=None):
        chosen = target or self.profiles.get_active_id()
        def loaded(data):
            self.data = data
            self.profiles.remove_all()
            for name in data["profiles"]:
                self.profiles.append(name, name)
            self.profiles.set_active_id(chosen if chosen in data["profiles"] else data["current"])
            self.change_device(self.device)
            self.status.set_text(message or f"Active profile: {data['current']}  •  Choose a control on the device to edit it.")
        self.work(lambda: json.loads(self.command("editor-state")), loaded)

    def profile_changed(self, *args):
        self.cancel_capture()
        if self.data and self.profiles.get_active_id():
            self.selection_changed()

    def change_device(self, device):
        self.device = device
        self.device_heading.set_text(NAMES[device])
        for kind, button in self.tabs.items():
            style = button.get_style_context()
            (style.add_class if kind == device else style.remove_class)("primary")
        previous = self.control.get_active_id()
        self.control.remove_all()
        for key, label, *_ in controls(device):
            self.control.append(key, label)
        if not self.control.set_active_id(previous or ""):
            self.control.set_active(0)

    def mapping(self, key):
        if not self.data or not self.profiles.get_active_id() or not key:
            return None
        value = self.model.profile(self.data["source"], self.device, self.profiles.get_active_id())
        for mapping in self.model.mappings(value):
            if mapping["inputID"] == key and bool(mapping.get("isHyperShift")) == self.shift.get_active():
                return mapping.get("mapping", [mapping])[0]
        return None

    @staticmethod
    def describe(mapping):
        if not mapping:
            return "Default"
        kind = mapping.get("outputType")
        if kind == "keyboardGroup":
            keys = mapping["keyboardGroup"]
            return " + ".join(short(k) for k in [*keys.get("modifiers", []), keys.get("key", "")]) or "Default"
        if kind == "macroGroup":
            return "Macro: " + mapping["macroGroup"]["name"]
        return "HyperShift" if kind == "hyperShiftGroup" else "Default"

    def selection_changed(self, *args):
        self.cancel_capture()
        mapping = self.mapping(self.control.get_active_id())
        self.current.set_text("Current: " + self.describe(mapping))
        keys = (mapping or {}).get("keyboardGroup", {})
        self.key.set_text(keys.get("key", ""))
        for key, check in self.modifiers.items():
            check.set_active(key in [k.replace("LEFT_", "LEFT").replace("RIGHT_", "RIGHT") for k in keys.get("modifiers", [])])
        self.kind.set_active_id("hypershift" if (mapping or {}).get("outputType") == "hyperShiftGroup" else "key")
        self.canvas.queue_draw()

    def kind_changed(self, *args):
        enabled = self.kind.get_active_id() == "key"
        for widget in (self.key, self.capture, self.modgrid):
            widget.set_sensitive(enabled)

    def start_capture(self, *args):
        self.recording = True
        self.held = set(); self.captured = set()
        self.capture.set_label("Press keys, then release…")
        self.capture.grab_focus()

    def cancel_capture(self):
        self.recording = False
        if hasattr(self, "capture"):
            self.capture.set_label("RECORD KEY / CHORD")
        return False

    def keypress(self, window, event):
        if not self.recording:
            return False
        value = ecodes.KEY.get(event.hardware_keycode - 8)
        if isinstance(value, (list, tuple)):
            value = value[0]
        if value:
            self.held.add(value); self.captured.add(value)
        return True

    def keyrelease(self, window, event):
        if not self.recording:
            return False
        value = ecodes.KEY.get(event.hardware_keycode - 8)
        if isinstance(value, (list, tuple)):
            value = value[0]
        self.held.discard(value)
        if not self.held and self.captured:
            keys = self.captured - set(self.model.MODIFIERS)
            if len(keys) > 1:
                self.status.set_text("Use one key plus modifiers. Record again for another chord.")
            else:
                key = next(iter(keys)) if keys else sorted(self.captured)[-1]
                self.key.set_text(key)
                for mod, check in self.modifiers.items():
                    check.set_active(mod in self.captured and mod != key)
            self.cancel_capture()
        return True

    def save_binding(self, *args):
        payload = {"revision": self.data["revision"], "profile": self.profiles.get_active_id(),
                   "device": self.device, "input": self.control.get_active_id(), "shift": self.shift.get_active(),
                   "kind": self.kind.get_active_id(), "key": self.key.get_text().strip().upper(),
                   "modifiers": [key for key, check in self.modifiers.items() if check.get_active()]}
        self.status.set_text("Validating assignment…")
        self.work(lambda: self.command("edit", payload=payload), lambda message: self.load(message=message))

    def apply_profile(self, *args):
        name = self.profiles.get_active_id()
        self.status.set_text(f"Applying {name} to connected devices…")
        self.work(lambda: self.command("apply-profile", name), lambda _: self.load(message=f"Active: {name}  •  Profile applied successfully."))

    def duplicate(self, *args):
        dialog = Gtk.Dialog(title="Duplicate unified profile", transient_for=self.window, modal=True)
        dialog.add_buttons("Cancel", Gtk.ResponseType.CANCEL, "Create", Gtk.ResponseType.OK)
        entry = Gtk.Entry(placeholder_text="New profile name"); entry.set_margin_start(20); entry.set_margin_end(20)
        dialog.get_content_area().pack_start(entry, True, True, 18); dialog.show_all()
        response = dialog.run(); name = entry.get_text(); dialog.destroy()
        if response == Gtk.ResponseType.OK:
            payload = {"revision": self.data["revision"], "profile": self.profiles.get_active_id(),
                       "operation": "duplicate", "name": name}
            self.work(lambda: self.command("edit", payload=payload), lambda message: self.load(target=name.strip(), message=message))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--controller", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--sounds")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("editor_model", args.model)
    model = importlib.util.module_from_spec(spec); spec.loader.exec_module(model)
    Editor(args.controller, model, args.sounds).run([])
