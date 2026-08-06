#!/usr/bin/env python3
"""StatusNotifier toggle for the configured Lan Mouse right-edge peer."""

import argparse
import re
import subprocess
import threading

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3 as AppIndicator3  # noqa: E402
from gi.repository import GLib, Gtk  # noqa: E402


RIGHT_CLIENT = re.compile(
    r"^id\s+(?P<id>\d+):.*\s+\(right\)\s+active:\s+(?P<active>true|false),",
    re.MULTILINE,
)


class LanMouseTray:
    def __init__(self, controller):
        self.controller = controller
        self.client_id = None
        self.enabled = None
        self.busy = False

        self.indicator = AppIndicator3.Indicator.new(
            "lan-mouse-edge-toggle",
            "preferences-desktop-remote-desktop-symbolic",
            AppIndicator3.IndicatorCategory.APPLICATION_STATUS,
        )
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)

        menu = Gtk.Menu()
        heading = Gtk.MenuItem(label="LAN Mouse · Right edge")
        heading.set_sensitive(False)
        menu.append(heading)
        menu.append(Gtk.SeparatorMenuItem())

        self.status_item = Gtk.MenuItem(label="Checking status…")
        self.status_item.set_sensitive(False)
        menu.append(self.status_item)

        self.toggle_item = Gtk.MenuItem(label="Lock mouse to Tracer")
        self.toggle_item.connect("activate", self.toggle)
        menu.append(self.toggle_item)

        refresh_item = Gtk.MenuItem(label="Refresh status")
        refresh_item.connect("activate", self.refresh)
        menu.append(refresh_item)

        menu.show_all()
        self.indicator.set_menu(menu)
        self.refresh()

    def run(self, *arguments):
        return subprocess.run(
            [self.controller, "cli", *arguments],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()

    def notify(self, summary, body, error=False):
        command = ["notify-send"]
        if error:
            command.extend(["--urgency", "critical"])
        command.extend([summary, body])
        subprocess.Popen(command)

    def read_status(self):
        match = RIGHT_CLIENT.search(self.run("list"))
        if match is None:
            raise RuntimeError("No active Lan Mouse peer is configured on the right edge.")
        return match.group("id"), match.group("active") == "true"

    def render(self):
        if self.busy:
            self.status_item.set_label("Changing state…")
            self.toggle_item.set_sensitive(False)
            self.indicator.set_icon_full("network-transmit-receive-symbolic", "Changing LAN Mouse state")
            self.indicator.set_title("LAN Mouse: changing state")
        elif self.enabled is True:
            self.status_item.set_label("Mac edge: Enabled")
            self.toggle_item.set_label("Lock mouse to Tracer")
            self.toggle_item.set_sensitive(True)
            self.indicator.set_icon_full("preferences-desktop-remote-desktop-symbolic", "LAN Mouse enabled")
            self.indicator.set_title("LAN Mouse: Mac edge enabled")
        elif self.enabled is False:
            self.status_item.set_label("Mac edge: Locked")
            self.toggle_item.set_label("Enable Mac edge")
            self.toggle_item.set_sensitive(True)
            self.indicator.set_icon_full("computer-symbolic", "LAN Mouse locked")
            self.indicator.set_title("LAN Mouse: locked to Tracer")
        else:
            self.status_item.set_label("Mac edge: Unavailable")
            self.toggle_item.set_label("Retry")
            self.toggle_item.set_sensitive(True)
            self.indicator.set_icon_full("network-error-symbolic", "LAN Mouse unavailable")
            self.indicator.set_title("LAN Mouse: unavailable")

    def refresh(self, _item=None):
        if self.busy:
            return
        try:
            self.client_id, self.enabled = self.read_status()
        except (RuntimeError, subprocess.SubprocessError):
            self.client_id = None
            self.enabled = None
        self.render()

    def toggle(self, _item):
        if self.busy:
            return
        if self.client_id is None or self.enabled is None:
            self.refresh()
            if self.client_id is None or self.enabled is None:
                self.notify("LAN Mouse unavailable", "The right-edge peer could not be found.", error=True)
                return

        self.busy = True
        self.render()
        action = "deactivate" if self.enabled else "activate"

        def worker():
            try:
                self.run(action, self.client_id)
                self.run("save-config")
                client_id, enabled = self.read_status()
                GLib.idle_add(self.toggle_finished, client_id, enabled, None)
            except (RuntimeError, subprocess.SubprocessError) as exc:
                GLib.idle_add(self.toggle_finished, self.client_id, self.enabled, str(exc))

        threading.Thread(target=worker, daemon=True).start()

    def toggle_finished(self, client_id, enabled, error):
        self.busy = False
        self.client_id = client_id
        self.enabled = enabled
        self.render()
        if error is None:
            message = "Mac edge enabled" if enabled else "Mouse locked to Tracer"
            self.notify("LAN Mouse", message)
        else:
            self.notify("LAN Mouse toggle failed", error, error=True)
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--controller", required=True)
    args = parser.parse_args()
    LanMouseTray(args.controller)
    Gtk.main()


if __name__ == "__main__":
    main()
