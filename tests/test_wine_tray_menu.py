"""Exercise the actual DBusMenu wire protocol and asynchronous recovery action."""
import importlib.util
import multiprocessing
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib


module_root = Path(os.environ.get("WINE_TRAY_MODULE_DIR", Path(__file__).parents[1] / "scripts/gaming"))
for name, filename in (("battlenet_processes", "battlenet-force-close.py"),
                       ("wine_tray_menu", "wine-tray-menu.py")):
    path = module_root / filename
    if not path.exists():
        path = module_root / (name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
menu_module = sys.modules["wine_tray_menu"]


def serve(command, clicks, ready):
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    name = dbus.service.BusName("org.dotfiles.WineTrayMenuTest", bus)

    class Bridge:
        def send_click(self, xid, button):
            with open(clicks, "a") as stream:
                stream.write(f"{xid}:{button}\n")

    menu = menu_module.BattleNetMenu(name, Bridge(), 123, command)
    ready.put(True)
    GLib.MainLoop().run()


class WineTrayMenuTests(unittest.TestCase):
    def test_wine_explorer_tray_proxy_and_unrelated_icons(self):
        window = SimpleNamespace(
            get_full_property=lambda *args: SimpleNamespace(value=[123]),
            get_wm_class=lambda: ("steam_app_battlenet", "steam_app_battlenet"))
        display = SimpleNamespace(intern_atom=lambda name: 1)
        with patch.object(menu_module, "inspect_process", return_value=SimpleNamespace(name="explorer.exe")):
            self.assertTrue(menu_module.is_battlenet_icon(window, display))
            unrelated = SimpleNamespace(get_full_property=window.get_full_property,
                                        get_wm_class=lambda: ("steam_app_other", "steam_app_other"))
            self.assertFalse(menu_module.is_battlenet_icon(unrelated, display))
        with patch.object(menu_module, "inspect_process", return_value=SimpleNamespace(name="Agent.exe")):
            self.assertFalse(menu_module.is_battlenet_icon(window, display))
        with patch.object(menu_module, "inspect_process", return_value=None):
            self.assertTrue(menu_module.is_battlenet_icon(window, display))

    def test_real_menu_layout_events_and_recovery_reentrancy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker, clicks = root / "kills", root / "clicks"
            command = root / "recovery"
            command.write_text(f"#!{sys.executable}\nimport time\n"
                               f"with open({str(marker)!r}, 'a') as out: out.write('kill\\n')\n"
                               "time.sleep(.3)\n")
            command.chmod(0o700)
            context = multiprocessing.get_context("fork")
            ready = context.Queue()
            server = context.Process(target=serve, args=(str(command), str(clicks), ready))
            server.start()
            try:
                ready.get(timeout=5)
                bus = dbus.SessionBus()
                proxy = bus.get_object("org.dotfiles.WineTrayMenuTest", "/Menu")
                interface = dbus.Interface(proxy, menu_module.INTERFACE)
                revision, layout = interface.GetLayout(0, -1, [])
                self.assertEqual(revision, 1)
                children = layout[2]
                self.assertEqual([item[0] for item in children], [1, 2, 3, 4])
                self.assertEqual(children[2][1]["type"], "separator")
                self.assertEqual(children[3][1]["label"], menu_module.LABEL)
                self.assertEqual(len(interface.GetLayout(0, 0, [])[1][2]), 0)
                self.assertEqual(set(interface.GetGroupProperties([4], ["label"])[0][1]), {"label"})
                self.assertFalse(interface.AboutToShow(0))
                self.assertEqual(list(interface.AboutToShowGroup([0, 99])[1]), [99])
                props = dbus.Interface(proxy, dbus.PROPERTIES_IFACE).GetAll(menu_module.INTERFACE)
                self.assertEqual(props["Version"], 3)
                for identifier in (1, 2):
                    interface.Event(identifier, "clicked", dbus.String(""), 0)
                self.assertEqual(clicks.read_text(), "123:1\n123:3\n")
                interface.Event(4, "clicked", dbus.String(""), 0)
                interface.Event(4, "clicked", dbus.String(""), 0)
                self.assertFalse(interface.GetProperty(4, "enabled"))
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline and not interface.GetProperty(4, "enabled"):
                    time.sleep(.02)
                self.assertTrue(interface.GetProperty(4, "enabled"))
                self.assertEqual(marker.read_text(), "kill\n")
            finally:
                server.terminate()
                server.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
