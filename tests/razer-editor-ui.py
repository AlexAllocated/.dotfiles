import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import cairo


ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts/nixos" / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


MODEL = load("model", "razer-editor-model.py")
UI = load("ui", "razer-keybind-editor.py")
IMPORTER = load("importer", "razer-import-profiles.py")
source = json.loads((ROOT / "razer/synapse-profiles.json").read_text())
data = {"source": source, "profiles": sorted({e["profile"]["name"] for e in source["profiles"]}),
        "current": "Heroes", "revision": MODEL.revision([])}


class FixtureEditor(UI.Editor):
    def work(self, operation, success):
        success(operation())

    def command(self, *args, payload=None):
        if args == ("editor-state",):
            return json.dumps(data)
        if args == ("edit",):
            self.last_edit = payload
            MODEL.update(source, [], payload, IMPORTER)
            return "Saved fixture"
        raise AssertionError(f"Unexpected live command: {args}")


def drain():
    loop = UI.GLib.MainLoop()
    UI.GLib.timeout_add(60, lambda: (loop.quit(), False)[1])
    loop.run()
    while UI.Gtk.events_pending():
        UI.Gtk.main_iteration_do(False)


with patch.object(UI.Gtk, "ApplicationWindow", side_effect=lambda **kwargs: UI.Gtk.OffscreenWindow()):
    UI.Gtk.Settings.get_default().set_property("gtk-enable-animations", False)
    editor = FixtureEditor("fixture-only", MODEL)
    editor.activate(None)
    drain()
    def descendants(widget):
        yield widget
        if isinstance(widget, UI.Gtk.Container):
            for child in widget.get_children():
                yield from descendants(child)
    title = next(w for w in descendants(editor.window) if isinstance(w, UI.Gtk.Label)
                 and w.get_text() == "PERIPHERAL CONTROL ARRAY")
    color = title.get_style_context().get_color(UI.Gtk.StateFlags.NORMAL)
    assert abs(color.red - 1) < .01 and abs(color.green - 187/255) < .01
    for kind in UI.NAMES:
        editor.change_device(kind)
        drain()
        for name, button in editor.tabs.items():
            style = button.get_style_context()
            assert style.has_class("primary") == (name == kind)
            color = style.get_property("background-color", UI.Gtk.StateFlags.NORMAL)
            rgb = tuple(round(channel * 255) for channel in (color.red, color.green, color.blue))
            assert rgb == ((255, 187, 51) if name == kind else (130, 140, 173)), (kind, name, rgb)
            button.set_state_flags(UI.Gtk.StateFlags.FOCUSED, False)
            assert style.get_property("outline-width", UI.Gtk.StateFlags.FOCUSED) == 0
            surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 160, 120)
            context = cairo.Context(surface)
            UI.Gtk.render_background(style, context, 0, 0, 160, 120)
            UI.Gtk.render_frame(style, context, 0, 0, 160, 120)
            UI.Gtk.render_focus(style, context, 0, 0, 160, 120)
            surface.flush()
            if name == "mouse":
                assert surface.get_data()[3] == 0
            surface.write_to_png(f"/tmp/razer-tab-{name}-focus.png")
            button.unset_state_flags(UI.Gtk.StateFlags.FOCUSED)
        keys = []
        for key, label, x, y, w, h in UI.controls(kind):
            IMPORTER.event(key)
            keys.append(key)
            scale, ox, oy = editor.canvas.geometry()
            editor.canvas.click(None, SimpleNamespace(x=ox+(x+w/2)*scale, y=oy+(y+h/2)*scale))
            assert editor.control.get_active_id() == key, (kind, key)
        assert len(keys) == len(set(keys))
        editor.window.resize(1100, 760)
        drain()
        image = cairo.ImageSurface(cairo.FORMAT_ARGB32, editor.window.get_allocated_width(), editor.window.get_allocated_height())
        editor.window.draw(cairo.Context(image))
        image.write_to_png(f"/tmp/razer-editor-{kind}-fixture.png")
    editor.change_device("mouse")
    mouse = {key: (x, y, w, h) for key, _, x, y, w, h in UI.controls("mouse")}
    clutch = mouse["DKM_SB_02"]
    assert clutch[2:] == mouse["Button5"][2:] == mouse["Button4"][2:]
    assert clutch[0] > mouse["Button5"][0] > mouse["Button4"][0]
    assert clutch[1] + clutch[3] < min(mouse[key][1] for key in ("Button4", "Button5"))
    for key, (x, y, w, h) in mouse.items():
        if key != "DKM_SB_02":
            assert not (clutch[0] < x+w and x < clutch[0]+clutch[2]
                        and clutch[1] < y+h and y < clutch[1]+clutch[3]), key
    editor.control.set_active_id("RepeatScrollLeft")
    assert editor.key.get_text() == "KEY_Z"
    editor.start_capture()
    for code in [UI.ecodes.KEY_LEFTCTRL, UI.ecodes.KEY_J]:
        editor.keypress(None, SimpleNamespace(hardware_keycode=code+8))
    for code in [UI.ecodes.KEY_J, UI.ecodes.KEY_LEFTCTRL]:
        editor.keyrelease(None, SimpleNamespace(hardware_keycode=code+8))
    assert editor.key.get_text() == "KEY_J"
    assert editor.modifiers["KEY_LEFTCTRL"].get_active()
    editor.save_binding()
    assert editor.last_edit["key"] == "KEY_J"
    assert editor.last_edit["modifiers"] == ["KEY_LEFTCTRL"]
    editor.start_capture()
    editor.keypress(None, SimpleNamespace(hardware_keycode=UI.ecodes.KEY_LEFTALT+8))
    editor.keyrelease(None, SimpleNamespace(hardware_keycode=UI.ecodes.KEY_LEFTALT+8))
    assert editor.key.get_text() == "KEY_LEFTALT"
    assert not any(c.get_active() for c in editor.modifiers.values())
    editor.shift.set_active(True)
    editor.kind.set_active_id("hypershift")
    editor.save_binding()
    assert editor.last_edit["shift"] is True
    assert editor.last_edit["kind"] == "hypershift"
    editor.window.destroy()
print("All device hotspots, key/chord capture, standalone modifiers, save and HyperShift UI checks passed")
