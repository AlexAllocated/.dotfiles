"""Native recovery menu for Battle.net's bridged XEmbed tray icon."""

import os
from pathlib import Path
import dbus
import dbus.service
from gi.repository import GLib
from battlenet_processes import inspect_process

INTERFACE = "com.canonical.dbusmenu"
LABEL = "Force quit Battle.net and all WoW clients"


def is_battlenet_icon(window, display):
    prop = window.get_full_property(display.intern_atom("_NET_WM_PID"), 6)
    process = inspect_process(Path("/proc") / str(int(prop.value[0])), os.getuid()) if prop and len(prop.value) else None
    if process and process.name.casefold() in {"battle.net.exe", "battle.net launcher.exe"}:
        return True
    if process and process.name.casefold() != "explorer.exe":
        return False
    # Wine Explorer owns the actual embedded tray window, rather than the
    # Battle.net process owning its message window. Also retain orphan recovery.
    return "steam_app_battlenet" in (window.get_wm_class() or ())


class BattleNetMenu(dbus.service.Object):
    def __init__(self, bus_name, bridge, icon_xid, command):
        super().__init__(bus_name, "/Menu")
        self.bridge = bridge
        self.icon_xid = icon_xid
        self.command = command
        self.running = False

    def properties(self, identifier):
        entries = {
            0: {"children-display": "submenu"},
            1: {"label": "Show Battle.net", "enabled": True, "visible": True},
            2: {"label": "Battle.net menu", "enabled": True, "visible": True},
            3: {"type": "separator", "visible": True},
            4: {"label": LABEL, "enabled": not self.running, "visible": True},
        }
        return entries.get(identifier, {})

    def layout(self, identifier, depth, names, variant=0):
        props = self.properties(identifier)
        if names:
            props = {key: value for key, value in props.items() if key in names}
        children = []
        if identifier == 0 and depth != 0:
            children = [self.layout(child, depth - 1 if depth > 0 else -1, names, 1)
                        for child in range(1, 5)]
        return dbus.Struct((dbus.Int32(identifier), dbus.Dictionary(props, signature="sv"),
                            dbus.Array(children, signature="v")),
                           signature="ia{sv}av", variant_level=variant)

    @dbus.service.method(INTERFACE, in_signature="iias", out_signature="u(ia{sv}av)")
    def GetLayout(self, parent, depth, names):
        return dbus.UInt32(1), self.layout(parent, depth, names)

    @dbus.service.method(INTERFACE, in_signature="aias", out_signature="a(ia{sv})")
    def GetGroupProperties(self, identifiers, names):
        return [(identifier, self.layout(identifier, 0, names)[1]) for identifier in identifiers]

    @dbus.service.method(INTERFACE, in_signature="is", out_signature="v")
    def GetProperty(self, identifier, name):
        return self.properties(identifier).get(name, "")

    @dbus.service.method(INTERFACE, in_signature="isvu")
    def Event(self, identifier, event, data, timestamp):
        if event != "clicked":
            return
        if identifier in (1, 2):
            self.bridge.send_click(self.icon_xid, 1 if identifier == 1 else 3)
        elif identifier == 4 and not self.running:
            # The action is local; it never waits for the Wine GUI or its menu.
            self.running = True
            self.ItemsPropertiesUpdated([(4, {"enabled": False})], [])
            try:
                pid, _, _, _ = GLib.spawn_async([self.command], flags=GLib.SpawnFlags.DO_NOT_REAP_CHILD)
                GLib.child_watch_add(GLib.PRIORITY_DEFAULT, pid, self.finished)
            except Exception:
                self.running = False
                self.ItemsPropertiesUpdated([(4, {"enabled": True})], [])
                raise

    def finished(self, pid, status):
        GLib.spawn_close_pid(pid)
        self.running = False
        self.ItemsPropertiesUpdated([(4, {"enabled": True})], [])

    @dbus.service.method(INTERFACE, in_signature="a(isvu)", out_signature="ai")
    def EventGroup(self, events):
        errors = []
        for identifier, event, data, timestamp in events:
            if identifier not in range(5):
                errors.append(identifier)
            else:
                self.Event(identifier, event, data, timestamp)
        return errors

    @dbus.service.method(INTERFACE, in_signature="i", out_signature="b")
    def AboutToShow(self, identifier):
        return False

    @dbus.service.method(INTERFACE, in_signature="ai", out_signature="aiai")
    def AboutToShowGroup(self, identifiers):
        return [], [identifier for identifier in identifiers if identifier not in range(5)]

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, name):
        return self.GetAll(interface).get(name, "")

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        if interface != INTERFACE:
            return {}
        return {"Version": dbus.UInt32(3), "TextDirection": "ltr", "Status": "normal",
                "IconThemePath": dbus.Array([], signature="s")}

    @dbus.service.signal(INTERFACE, signature="a(ia{sv})a(ias)")
    def ItemsPropertiesUpdated(self, updated, removed):
        pass

    @dbus.service.signal(INTERFACE, signature="iu")
    def ItemActivationRequested(self, identifier, timestamp):
        pass
