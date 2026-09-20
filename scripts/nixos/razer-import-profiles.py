#!/usr/bin/env python3

import argparse
import json
from pathlib import Path

from evdev import ecodes


DEVICES = {
    "mouse": "Razer Basilisk V3 Pro 35K",
    "keypad": "Razer Razer Tartarus Pro",
    "keyboard": "Razer Razer Huntsman V2 Analog",
}
ALIASES = {
    "KEY_LEFT_CTRL": "KEY_LEFTCTRL", "KEY_RIGHT_CTRL": "KEY_RIGHTCTRL",
    "KEY_LEFT_SHIFT": "KEY_LEFTSHIFT", "KEY_RIGHT_SHIFT": "KEY_RIGHTSHIFT",
    "KEY_LEFT_ALT": "KEY_LEFTALT", "KEY_RIGHT_ALT": "KEY_RIGHTALT",
    "KEY_LEFT_META": "KEY_LEFTMETA", "KEY_RIGHT_META": "KEY_RIGHTMETA",
    "KEY_SPACEBAR": "KEY_SPACE", "KEY_CAPS_LOCK": "KEY_CAPSLOCK",
    "KEY_UP_ARROW": "KEY_UP", "KEY_DOWN_ARROW": "KEY_DOWN",
    "KEY_LEFT_ARROW": "KEY_LEFT", "KEY_RIGHT_ARROW": "KEY_RIGHT",
    "KEY_PAGE_UP": "KEY_PAGEUP", "KEY_PAGE_DOWN": "KEY_PAGEDOWN",
    "KEY_NUMPAD_0": "KEY_KP0",
    "KEY_NUMPAD_DASH": "KEY_KPMINUS", "KEY_TILDE": "KEY_GRAVE", "KEY_PERIOD": "KEY_DOT",
}
BUTTONS = {
    "Button4": "BTN_SIDE", "Button5": "BTN_EXTRA", "ScrollButton": "BTN_MIDDLE",
    "DKM_SB_01": "KEY_F13", "DKM_SB_02": "KEY_F14",
    "DKM_SB_03": "KEY_F15", "DKM_M_106": "KEY_F16",
}
WHEELS = {
    "ScrollUp": ("REL_WHEEL", 1), "ScrollDown": ("REL_WHEEL", -1),
    "RepeatScrollLeft": ("REL_HWHEEL", -1), "RepeatScrollRight": ("REL_HWHEEL", 1),
}


def symbol(name):
    result = BUTTONS.get(name, ALIASES.get(name, name))
    if result not in ecodes.ecodes:
        raise ValueError(f"Unknown Synapse key: {name}")
    return result


def event(name):
    if name in WHEELS:
        axis, threshold = WHEELS[name]
        return {"type": 2, "code": ecodes.ecodes[axis], "analog_threshold": threshold}
    return {"type": 1, "code": ecodes.ecodes[symbol(name)]}


def primary(mapping):
    return mapping.get("mapping", [mapping])[0]


def action(mapping, macros, as_macro=False):
    source = mapping["inputID"]
    value = primary(mapping)
    kind = value.get("outputType")
    if kind == "hyperShiftGroup":
        return "set(razer_hypershift, 1).hold().set(razer_hypershift, 0)"
    if kind == "macroGroup":
        macro = value["macroGroup"]
        if macro.get("macroPlaybackOption") != "Once":
            raise ValueError(f"Unsupported macro playback: {macro}")
        return ".".join(
            f'wait({step["delay"]})' if "delay" in step else
            f'key_{"down" if step["value"] else "up"}({symbol(step["key"])})'
            for step in macros[macro["name"]]
        )
    keys = value.get("keyboardGroup", {})
    if kind in (None, "defaultGroup") or (kind == "keyboardGroup" and not keys.get("key")):
        if source in WHEELS:
            axis, direction = WHEELS[source]
            return f"event(EV_REL, {axis}, {direction})"
        output = [symbol(source)]
    elif kind == "keyboardGroup":
        output = [symbol(key) for key in [*keys.get("modifiers", []), keys["key"]]]
    else:
        raise ValueError(f"Unsupported mapping: {mapping}")
    if as_macro:
        return f'hold_keys({", ".join(output)})'
    return " + ".join(output)


def compile_mappings(mappings, macros, device):
    layers = [{}, {}]
    for mapping in mappings:
        value = primary(mapping)
        if value.get("outputType") == "keyboardGroup" and not value.get("keyboardGroup", {}).get("key"):
            continue
        layers[bool(mapping.get("isHyperShift"))][mapping["inputID"]] = mapping
    result = []
    bridge = []
    for source in sorted(layers[0].keys() | layers[1].keys()):
        base = layers[0].get(source, {"inputID": source, "outputType": "defaultGroup"})
        if source in layers[1] and primary(base).get("outputType") != "hyperShiftGroup":
            shifted = action(layers[1][source], macros, True)
            normal = action(base, macros, True)
            output = f"if_eq($razer_hypershift, 1, {shifted}, {normal})"
        else:
            output = action(base, macros)
        if (device == "mouse" and source not in layers[1]
                and primary(base).get("outputType") == "keyboardGroup"):
            bridge.append({"input_combination": [event(source)], "target_uinput": "keyboard",
                           "output_symbol": output, "name": f"Synapse direct: {source}"})
            continue
        result.append({
            "input_combination": [event(source)],
            "target_uinput": "keyboard + mouse" if device == "mouse" else "keyboard",
            "output_symbol": output,
            "name": f"Synapse: {source}",
            "macro_key_sleep_ms": 1,
        })
        if device == "mouse" and source.startswith("DKM_"):
            bridge.append({"input_combination": [event(source)], "target_uinput": "keyboard",
                           "output_symbol": symbol(source), "name": f"Synapse bridge: {source}"})
    return result, bridge


def generate(source, destination):
    profiles = {device: {} for device in DEVICES}
    for entry in source["profiles"]:
        profiles[entry["device"]][entry["profile"]["name"]] = entry["profile"]
    names = sorted(set().union(*(entries.keys() for entries in profiles.values())))
    manifest = {"profiles": names, "devices": DEVICES, "defaults": {}, "inactive_keymaps": []}
    for name in names:
        for device, entries in profiles.items():
            default = "Keyboard Default" if device == "keyboard" else "DEFAULT"
            selected = entries.get(name, entries[default])
            manifest["defaults"].setdefault(name, {})[device] = selected["name"]
            mappings = selected.get("mappings", [])
            if selected.get("keymaps"):
                mappings = next(k["mappings"] for k in selected["keymaps"] if k["slot"] == "1")
            compiled, bridge = compile_mappings(mappings, source["macros"], device)
            folder = destination / "presets" / DEVICES[device]
            folder.mkdir(parents=True, exist_ok=True)
            (folder / f"{name}.json").write_text(json.dumps(compiled, indent=2) + "\n")
            if device == "mouse":
                hardware = destination / "hardware"
                hardware.mkdir(exist_ok=True)
                (hardware / f"{name}.json").write_text(json.dumps(bridge, indent=2) + "\n")
    for profile in profiles["keypad"].values():
        manifest["inactive_keymaps"].extend(
            {"profile": profile["name"], "keymap": keymap["name"]}
            for keymap in profile.get("keymaps", []) if keymap["slot"] != "1"
        )
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    generate(json.loads(args.source.read_text()), args.destination)
