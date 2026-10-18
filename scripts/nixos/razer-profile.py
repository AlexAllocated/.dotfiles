#!/usr/bin/env python3

import argparse
from contextlib import closing
import errno
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


class MouseInterfaceUnavailable(RuntimeError):
    pass


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(*command):
    result = subprocess.run(command, text=True, capture_output=True, timeout=45)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or repr(command))
    return result.stdout.strip()


def bus(method, signature=None, *args):
    command = ["busctl", "--system", "call", "inputremapper.Control",
               "/inputremapper/Control", "inputremapper.Control", method]
    if signature:
        command.extend([signature, *args])
    return run(*command)


def selected(state, manifest):
    try:
        value = (state / "current").read_text().strip()
    except FileNotFoundError:
        value = "DEFAULT"
    return value if value in manifest["profiles"] else "DEFAULT"


def connected(manifest, available):
    result = {}
    for kind, name in manifest["devices"].items():
        aliases = [name]
        if kind == "mouse":
            aliases.append("Razer Razer Basilisk V3 Pro 35K")
        for alias in aliases:
            if alias in available:
                result[kind] = alias
                break
    return result


def mouse_interfaces(group):
    from evdev import InputDevice, list_devices

    result = []
    for path in list_devices():
        try:
            with closing(InputDevice(path)) as device:
                if device.name == group:
                    capabilities = device.capabilities(absinfo=False)
                    identity = hashlib.md5((str(capabilities) + device.name).encode()).hexdigest()
                    result.append((capabilities, identity))
        except OSError as error:
            # Rebinding HID recreates event nodes before udev has assigned
            # their permissions. Another device can also disappear mid-scan.
            if error.errno not in (errno.ENOENT, errno.ENODEV, errno.EACCES):
                raise
    return result


def bind_mouse_inputs(mappings, interfaces):
    for mapping in mappings:
        for event in mapping["input_combination"]:
            candidates = [(caps, identity) for caps, identity in interfaces
                          if event["code"] in caps.get(event["type"], [])]
            if not candidates:
                raise MouseInterfaceUnavailable(f"Mouse interface unavailable for {event}")
            keyboard = event["type"] == 1 and event["code"] < 256
            candidates.sort(key=lambda pair: (
                (17 in pair[0]) != keyboard,
                not {0, 1}.issubset(pair[0].get(2, [])) if not keyboard else False,
            ))
            event["origin_hash"] = candidates[0][1]
    return mappings


def bind_mouse_presets(folder, group, timeout=10):
    # libusb releases and reattaches the input driver when the hardware
    # command exits. Wait for accessible event nodes and their capabilities,
    # without reprogramming the mouse or starting a rollback while udev settles.
    deadline = time.monotonic() + timeout
    while True:
        interfaces = mouse_interfaces(group)
        try:
            presets = {
                preset: bind_mouse_inputs(json.loads(preset.read_text()), interfaces)
                for preset in folder.glob("*.json")
            }
            break
        except MouseInterfaceUnavailable as error:
            if time.monotonic() >= deadline:
                raise MouseInterfaceUnavailable(
                    f"Mouse interfaces did not become ready within {timeout}s: {error}"
                ) from error
            time.sleep(.1)
    for preset, mappings in presets.items():
        preset.write_text(json.dumps(mappings, indent=2))


def prepare(source, state, manifest, name, devices):
    transaction = state / "transactions" / uuid.uuid4().hex
    transaction.mkdir(parents=True, mode=0o700)
    shutil.copytree(source, transaction / "source")
    for kind, group in devices.items():
        folder = source / "presets" / manifest["devices"][kind]
        target = transaction / "presets" / group
        target.mkdir(parents=True)
        for preset in folder.glob("*.json"):
            value = preset.read_text().replace("razer_hypershift", f"razer_hypershift_{transaction.name}")
            (target / preset.name).write_text(value)
    (transaction / "config.json").write_text(json.dumps({
        "version": "2.2.0", "autoload": dict.fromkeys(devices.values(), name)
    }))
    return transaction


def bind_keypad_thumb_presets(folder, group):
    # Tartarus Pro's main keys use the multifunction interface, but its
    # thumb controls emit on the boot keyboard interface. Both advertise
    # these keycodes, so Input Remapper's fallback can pick the wrong one.
    interfaces = [(caps, identity) for caps, identity in mouse_interfaces(group) if 17 in caps]
    presets = {}
    for preset in folder.glob("*.json"):
        mappings = json.loads(preset.read_text())
        for mapping in mappings:
            for event in mapping["input_combination"]:
                if event["type"] == 1 and event["code"] in (56, 103, 105, 106, 108):
                    candidates = [identity for caps, identity in interfaces
                                  if event["code"] in caps.get(1, [])]
                    if len(candidates) != 1:
                        raise RuntimeError(f"Tartarus thumb keyboard interface unavailable or ambiguous for {event}")
                    event["origin_hash"] = candidates[0]
        presets[preset] = mappings
    for preset, mappings in presets.items():
        preset.write_text(json.dumps(mappings, indent=2))


def apply(source, state, manifest, name, hardware, attempts):
    devices = connected(manifest, run("input-remapper-control", "--list-devices").splitlines())
    if not devices:
        raise RuntimeError("No supported Razer devices are connected")
    transaction = prepare(source, state, manifest, name, devices)
    for group in devices.values():
        bus("stop_injecting", "s", group)
    if "mouse" in devices:
        run(hardware, "--profiles-dir", str(source / "hardware"),
            "--state-file", str(transaction / "hardware-current"),
            "--attempts", str(attempts), "apply-profile", name)
        folder = transaction / "presets" / devices["mouse"]
        bind_mouse_presets(folder, devices["mouse"])
    if "keypad" in devices:
        bind_keypad_thumb_presets(transaction / "presets" / devices["keypad"], devices["keypad"])
    bus("set_config_dir", "s", str(transaction))
    started = []
    try:
        for group in devices.values():
            if not json.loads((transaction / "presets" / group / f"{name}.json").read_text()):
                continue
            if bus("start_injecting", "ss", group, name) != "b true":
                raise RuntimeError(f"Input Remapper rejected {name} for {group}")
            started.append(group)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            states = {group: bus("get_state", "s", group) for group in started}
            if all(value == 's "RUNNING"' for value in states.values()):
                break
            if any(value not in ('s "RUNNING"', 's "STARTING"') for value in states.values()):
                raise RuntimeError(f"Razer profile did not activate: {states}")
            time.sleep(.1)
        else:
            raise RuntimeError(f"Timed out activating Razer profile: {states}")
    except Exception:
        for group in started:
            bus("stop_injecting", "s", group)
        raise
    pending = sorted(set(manifest["devices"]) - devices.keys())
    (state / "applied.json").write_text(json.dumps({
        "profile": name, "devices": devices, "pending": pending,
        "config": str(transaction), "fallbacks": manifest["defaults"][name],
    }, indent=2) + "\n")
    return transaction


def publish_config(config, transaction, state):
    config.parent.mkdir(parents=True, exist_ok=True)
    temporary = config.with_name(f".{config.name}-{uuid.uuid4().hex}")
    temporary.symlink_to(transaction, target_is_directory=True)
    try:
        if config.is_dir() and not config.is_symlink():
            backup = state / f"legacy-input-remapper-{uuid.uuid4().hex}"
            shutil.move(str(config), backup)
            print(f"Previous Input Remapper configuration saved to {backup}", file=sys.stderr)
        os.replace(temporary, config)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--hardware", required=True)
    parser.add_argument("--definitions", type=Path)
    parser.add_argument("--importer", type=Path)
    parser.add_argument("--editor-model", type=Path)
    parser.add_argument("--attempts", type=int, default=3)
    parser.add_argument("command", choices=["list-profiles", "status", "apply-profile", "reapply-profile", "validate", "editor-state", "edit"])
    parser.add_argument("profile", nargs="?")
    args = parser.parse_args()
    args.state.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (args.state / "apply.lock").open("a") as lock:
        if args.command not in ("list-profiles", "status", "editor-state"):
            fcntl.flock(lock, fcntl.LOCK_EX)
        with tempfile.TemporaryDirectory(prefix="razer-profiles-") as temporary:
            if args.definitions:
                model = load_module("editor_model", args.editor_model)
                importer = load_module("profile_importer", args.importer)
                baseline = json.loads(args.definitions.read_text())
                overlay = args.state / "editor-overrides.json"
                overrides = json.loads(overlay.read_text()) if overlay.exists() else []
                source = model.merge(baseline, overrides)
                names = sorted({e["profile"]["name"] for e in source["profiles"]})
                if args.command == "list-profiles":
                    print("\n".join(names))
                    return
                if args.command == "status":
                    print(selected(args.state, {"profiles": names}))
                    return
                if args.command == "editor-state":
                    print(json.dumps({"source": source, "profiles": names,
                                      "current": selected(args.state, {"profiles": names}),
                                      "revision": model.revision(overrides)}))
                    return
                if args.command == "edit":
                    overrides = model.update(baseline, overrides, json.load(sys.stdin), importer)
                    source = model.merge(baseline, overrides)
                args.source = Path(temporary)
                importer.generate(source, args.source)
                if args.command == "edit":
                    run(args.hardware, "--profiles-dir", str(args.source / "hardware"), "validate")
                    if overlay.exists():
                        backups = args.state / "editor-backups"
                        backups.mkdir(exist_ok=True)
                        shutil.copy2(overlay, backups / f"{time.time_ns()}.json")
                    staged = overlay.with_suffix(".new")
                    staged.write_text(json.dumps(overrides, indent=2) + "\n")
                    os.replace(staged, overlay)
                    print("Saved. Apply the profile to activate these changes.")
                    return
            execute(args)


def execute(args):
    manifest = json.loads((args.source / "manifest.json").read_text())
    if args.command == "list-profiles":
        print("\n".join(manifest["profiles"]))
        return
    previous = selected(args.state, manifest)
    if args.command == "status":
        print(previous)
        return
    if args.command == "validate":
        run(args.hardware, "--profiles-dir", str(args.source / "hardware"), "validate")
        print(f'{len(manifest["profiles"])} unified profiles validated')
        return
    name = args.profile if args.command == "apply-profile" else previous
    if name not in manifest["profiles"]:
        raise ValueError(f"Unknown profile: {name!r}")
    args.state.mkdir(parents=True, exist_ok=True, mode=0o700)
    previous = selected(args.state, manifest)
    if args.command == "reapply-profile":
        name = previous
    rollback_source = args.config.resolve() / "source"
    if not (rollback_source / "manifest.json").exists():
        rollback_source = args.source
    rollback_manifest = json.loads((rollback_source / "manifest.json").read_text())
    run(args.hardware, "--profiles-dir", str(args.source / "hardware"), "validate")
    try:
        transaction = apply(args.source, args.state, manifest, name, args.hardware, args.attempts)
        publish_config(args.config, transaction, args.state)
    except Exception as error:
        try:
            restored = apply(rollback_source, args.state, rollback_manifest, previous, args.hardware, args.attempts)
            publish_config(args.config, restored, args.state)
        except Exception as rollback:
            raise RuntimeError(f"Profile failed: {error}; restore failed: {rollback}") from error
        raise RuntimeError(f"Profile failed; restored {previous}: {error}") from error
    temporary = args.state / "current.new"
    temporary.write_text(name + "\n")
    os.replace(temporary, args.state / "current")
    print(name)


if __name__ == "__main__":
    main()
