"""Exercise the tray host's pixels and real XComposite icon capture on Xvfb."""
import importlib.util
from pathlib import Path
import sys
import unittest

from Xlib import X, Xatom, display
from Xlib.ext import composite, shape


bridge_path = Path(sys.argv.pop(1))
sys.path.insert(0, str(bridge_path.parent))
spec = importlib.util.spec_from_file_location("wine_sni_bridge", bridge_path)
bridge_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge_module)


class TrayHostTest(unittest.TestCase):
    def setUp(self):
        self.bridge = bridge_module.WineSNIBridge(byte_order="network")
        self.assertTrue(self.bridge._claim_tray())
        self.host = self.bridge._tray_window
        # Reproduce Xwayland bringing the supposedly offscreen host onscreen.
        self.host.configure(x=10, y=10, width=64, height=32)
        self.bridge._display.sync()

    def tearDown(self):
        self.bridge._display.close()

    def test_onscreen_host_has_transparent_pixels_and_no_input_region(self):
        geometry = self.host.get_geometry()
        self.assertEqual(geometry.depth, 32)
        image = self.host.get_image(0, 0, 64, 32, X.ZPixmap, 0xFFFFFFFF)
        self.assertEqual(image.data, bytes(64 * 32 * 4))
        self.assertEqual(len(self.host.shape_get_rectangles(shape.SK.Input).rectangles), 0)

    def test_transparent_host_preserves_fresh_icon_capture(self):
        # Use a second X11 client, like an actual Wine notification window.
        client = display.Display()
        self.addCleanup(client.close)
        visual = int(self.host.get_full_property(
            self.bridge._display.intern_atom("_NET_SYSTEM_TRAY_VISUAL"), Xatom.VISUALID
        ).value[0])
        colormap = client.screen().root.create_colormap(visual, X.AllocNone)
        icon = client.screen().root.create_window(
            0, 0, 20, 20, 0, 32, X.InputOutput, visual,
            colormap=colormap, background_pixel=0xFF2070B0, border_pixel=0,
        )
        client.sync()
        window = self.bridge._display.create_resource_object("window", icon.id)
        window.reparent(self.host, 0, 0)
        window.composite_redirect_window(composite.RedirectManual)
        window.map()
        self.bridge._display.sync()
        gc = icon.create_gc(foreground=0xFF2070B0)
        icon.fill_rectangle(gc, 0, 0, 20, 20)
        client.sync()

        class IconRecorder:
            def update_icon(self, pixels):
                self.pixels = pixels

        recorder = IconRecorder()
        slot = {"window": window, "sni": recorder, "icon_ready": False, "icon_key": "probe"}
        self.bridge._slots = [slot]
        self.bridge._active_icons[icon.id] = 0
        self.assertFalse(self.bridge._extract_icon(icon.id))
        self.assertTrue(slot["icon_ready"])
        width, height, data = recorder.pixels[0]
        # Production exports a 48x48 SNI pixmap after capturing the 20x20 icon.
        self.assertEqual((width, height), (48, 48))
        self.assertEqual(bytes(data), bytes.fromhex("ff2070b0") * (48 * 48))
        gc.free()
        icon.destroy()
        colormap.free()
        client.sync()


if __name__ == "__main__":
    unittest.main()
