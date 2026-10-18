import copy
import hashlib
import json


MODIFIERS = [f"KEY_{side}{key}" for side in ("LEFT", "RIGHT") for key in ("CTRL", "SHIFT", "ALT", "META")]
MOUSE = ["ScrollButton", "RepeatScrollLeft", "RepeatScrollRight", "Button4", "Button5",
         "DKM_SB_01", "DKM_SB_02", "DKM_SB_03", "DKM_M_106"]


def revision(overrides):
    return hashlib.sha256(json.dumps(overrides, sort_keys=True).encode()).hexdigest()


def merge(baseline, overrides):
    result = copy.deepcopy(baseline)
    entries = {(e["device"], e["profile"]["name"]): e for e in result["profiles"]}
    for entry in overrides:
        entries[entry["device"], entry["profile"]["name"]] = copy.deepcopy(entry)
    result["profiles"] = list(entries.values())
    return result


def profile(source, device, name):
    entries = {e["profile"]["name"]: e["profile"] for e in source["profiles"] if e["device"] == device}
    return entries.get(name, entries["Keyboard Default" if device == "keyboard" else "DEFAULT"])


def mappings(value):
    if value.get("keymaps"):
        return next(k["mappings"] for k in value["keymaps"] if k["slot"] == "1")
    return value["mappings"]


def update(baseline, overrides, request, importer):
    if request.get("revision") != revision(overrides):
        raise ValueError("Profiles changed in another window. Reload before saving.")
    source = merge(baseline, overrides)
    name = request["profile"]
    names = {e["profile"]["name"] for e in source["profiles"]}
    if name not in names:
        raise ValueError("Unknown source profile")
    result = copy.deepcopy(overrides)
    if request.get("operation") == "duplicate":
        target = request["name"].strip()
        if not target or len(target) > 64 or target in (".", "..") or any(c in target for c in '/\\\x00\n\r'):
            raise ValueError("Use a profile name of 1–64 characters without path separators")
        if target in names:
            raise ValueError("That profile already exists")
        for device in importer.DEVICES:
            value = copy.deepcopy(profile(source, device, name))
            value["name"] = target
            result.append({"device": device, "profile": value})
        return result
    device, control = request["device"], request["input"]
    if device not in importer.DEVICES:
        raise ValueError("Unknown device")
    if device == "mouse" and control not in MOUSE:
        raise ValueError("This mouse control is not supported by the hardware backend")
    importer.event(control)
    value = copy.deepcopy(profile(source, device, name))
    value["name"] = name
    entries = mappings(value)
    layer = bool(request.get("shift"))
    entries[:] = [m for m in entries if not (importer.event(m["inputID"]) == importer.event(control)
                                            and bool(m.get("isHyperShift")) == layer)]
    kind = request["kind"]
    if kind == "key":
        key = importer.symbol(request["key"])
        modifiers = request.get("modifiers", [])
        if not key.startswith("KEY_") or any(m not in MODIFIERS for m in modifiers):
            raise ValueError("Choose a keyboard key and valid modifiers")
        mapping = {"outputType": "keyboardGroup", "keyboardGroup": {"key": key, "modifiers": modifiers}}
    elif kind == "hypershift":
        mapping = {"outputType": "hyperShiftGroup"}
    elif kind == "default":
        mapping = None
    else:
        raise ValueError("Unknown assignment type")
    if mapping:
        entries.append({"inputID": control, "isHyperShift": layer, **mapping})
    result = [e for e in result if (e["device"], e["profile"]["name"]) != (device, name)]
    result.append({"device": device, "profile": value})
    return result
