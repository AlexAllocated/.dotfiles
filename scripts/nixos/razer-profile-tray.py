#!/usr/bin/env python3
"""StatusNotifier profile selector for the Razer Basilisk."""

import argparse
import subprocess
import threading

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3 as AppIndicator3  # noqa: E402
from gi.repository import GLib, Gtk  # noqa: E402


class ProfileTray:
    def __init__(self, controller):
        self.controller = controller
        self.selected = self.run("status")
        self.busy = False
        self.items = {}

        self.indicator = AppIndicator3.Indicator.new(
            "razer-profile-selector",
            "input-mouse-symbolic",
            AppIndicator3.IndicatorCategory.HARDWARE,
        )
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        self.indicator.set_title(f"Razer profile: {self.selected}")

        menu = Gtk.Menu()
        heading = Gtk.MenuItem(label="Basilisk profile")
        heading.set_sensitive(False)
        menu.append(heading)
        menu.append(Gtk.SeparatorMenuItem())

        group = None
        for name in self.run("list-profiles").splitlines():
            item = Gtk.RadioMenuItem.new_with_label(group, name)
            group = item.get_group()
            item.set_active(name == self.selected)
            item.connect("toggled", self.profile_toggled, name)
            self.items[name] = item
            menu.append(item)

        menu.append(Gtk.SeparatorMenuItem())
        reapply = Gtk.MenuItem(label="Reapply current profile")
        reapply.connect("activate", self.reapply)
        menu.append(reapply)
        menu.show_all()
        self.indicator.set_menu(menu)
        GLib.timeout_add_seconds(2, self.refresh)

    def run(self, *arguments):
        return subprocess.run(
            [self.controller, *arguments],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def notify(self, summary, body):
        subprocess.Popen(["notify-send", summary, body])

    def set_sensitive(self, sensitive):
        for item in self.items.values():
            item.set_sensitive(sensitive)

    def profile_toggled(self, item, name):
        if not item.get_active() or self.busy or name == self.selected:
            return
        self.start_apply(name, remember=True)

    def reapply(self, _item):
        if not self.busy:
            self.start_apply(self.selected, remember=False)

    def start_apply(self, name, remember):
        self.busy = True
        self.set_sensitive(False)
        command = "apply-profile" if remember else "reapply-profile"

        def worker():
            try:
                self.run(command, *([name] if remember else []))
                GLib.idle_add(self.apply_finished, name, None)
            except subprocess.CalledProcessError as exc:
                message = exc.stderr.strip() or str(exc)
                GLib.idle_add(self.apply_finished, self.selected, message)

        threading.Thread(target=worker, daemon=True).start()

    def apply_finished(self, name, error):
        self.busy = False
        self.set_sensitive(True)
        if error is None:
            self.selected = name
            self.indicator.set_title(f"Razer profile: {name}")
            self.notify("Razer profile", f"Switched to {name}")
        else:
            self.notify("Razer profile failed", error)
        self.sync_checks()
        return False

    def sync_checks(self):
        self.busy = True
        for name, item in self.items.items():
            item.set_active(name == self.selected)
        self.busy = False

    def refresh(self):
        if self.busy:
            return True
        try:
            selected = self.run("status")
        except subprocess.CalledProcessError:
            return True
        if selected != self.selected:
            self.selected = selected
            self.indicator.set_title(f"Razer profile: {selected}")
            self.sync_checks()
        return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--controller", required=True)
    args = parser.parse_args()
    ProfileTray(args.controller)
    Gtk.main()


if __name__ == "__main__":
    main()
