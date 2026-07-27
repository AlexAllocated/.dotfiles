#!/usr/bin/env python3
"""Apply recovered Synapse layouts directly to a Basilisk V3 Pro 35K."""

import argparse
import contextlib
import datetime
import io
import json
import os
import pathlib
import pickle
import sys
import time

import hid

import qdrazer.protocol as protocol
from basilisk_v3.device import BasiliskV3Pro35KPhantomGreenDevice


VENDOR_ID = 0x1532
PRODUCT_IDS = {
    "wired": 0x00D6,
    "wireless": 0x00D7,
}

# Linux input events emitted by the physical controls in the recovered
# Input Remapper profiles.  The four F13-F16 entries were only an old bridge;
# they identify the corresponding Razer controls and are never emitted by the
# direct layouts produced here.
INPUT_BUTTONS = {
    (1, 183, None): protocol.Button.BOTTOM,
    (1, 184, None): protocol.Button.AIM,
    (1, 185, None): protocol.Button.MIDDLE_BACKWARD,
    (1, 186, None): protocol.Button.MIDDLE_FORWARD,
    (1, 275, None): protocol.Button.BACKWARD,
    (1, 276, None): protocol.Button.FORWARD,
    (2, 6, -1): protocol.Button.WHEEL_LEFT,
    (2, 6, 1): protocol.Button.WHEEL_RIGHT,
}

# USB HID keyboard-page usages.  Keep this deliberately small: every symbol
# present in the recovered Synapse profiles must be understood before any
# hardware write begins.
KEYBOARD_USAGES = {
    "KEY_B": 0x05,
    "KEY_C": 0x06,
    "KEY_E": 0x08,
    "KEY_G": 0x0A,
    "KEY_H": 0x0B,
    "KEY_K": 0x0E,
    "KEY_M": 0x10,
    "KEY_Q": 0x14,
    "KEY_S": 0x16,
    "KEY_T": 0x17,
    "KEY_V": 0x19,
    "KEY_X": 0x1B,
    "KEY_ESC": 0x29,
    "KEY_TAB": 0x2B,
    "KEY_SPACE": 0x2C,
    "KEY_EQUAL": 0x2E,
    "KEY_GRAVE": 0x35,
    "KEY_COMMA": 0x36,
    "KEY_DOT": 0x37,
    "KEY_F1": 0x3A,
    "KEY_F5": 0x3E,
}
KEYBOARD_MODIFIERS = {
    "KEY_LEFTCTRL": protocol.FnKeyboardModifier.LEFT_CONTROL,
    "KEY_LEFTSHIFT": protocol.FnKeyboardModifier.LEFT_SHIFT,
    "KEY_LEFTALT": protocol.FnKeyboardModifier.LEFT_ALT,
    "KEY_LEFTMETA": protocol.FnKeyboardModifier.LEFT_GUI,
    "KEY_RIGHTCTRL": protocol.FnKeyboardModifier.RIGHT_CONTROL,
    "KEY_RIGHTSHIFT": protocol.FnKeyboardModifier.RIGHT_SHIFT,
    "KEY_RIGHTALT": protocol.FnKeyboardModifier.RIGHT_ALT,
    "KEY_RIGHTMETA": protocol.FnKeyboardModifier.RIGHT_GUI,
}


def candidate_paths(transport):
    product_ids = PRODUCT_IDS.values()
    if transport != "auto":
        product_ids = (PRODUCT_IDS[transport],)

    candidates = []
    for item in hid.enumerate(VENDOR_ID, 0):
        if item.get("product_id") not in product_ids:
            continue
        if item.get("interface_number") != 0:
            continue
        candidates.append(item)

    candidates.sort(
        key=lambda item: (
            item["product_id"] != PRODUCT_IDS["wired"],
            item["path"],
        )
    )
    return candidates


def connect(transport, attempts):
    errors = []
    for attempt in range(1, attempts + 1):
        candidates = candidate_paths(transport)
        if not candidates:
            errors = ["no matching interface-0 HID device"]
        for item in candidates:
            device = BasiliskV3Pro35KPhantomGreenDevice()
            try:
                # The upstream library logs its selected HID candidate to
                # stdout. Keep this command's stdout machine-readable JSON.
                with contextlib.redirect_stdout(io.StringIO()):
                    device.connect(path=item["path"])
                device.get_button_function(
                    protocol.Button.AIM,
                    profile=protocol.Profile.DIRECT,
                )
                selected = next(
                    name
                    for name, product_id in PRODUCT_IDS.items()
                    if product_id == item["product_id"]
                )
                return device, selected, item["path"]
            except Exception as exc:  # Device transport errors are runtime-only.
                errors.append(f"{item['path']!r}: {exc}")
                try:
                    device.close()
                except Exception:
                    pass
        if attempt < attempts:
            time.sleep(0.5)

    detail = "; ".join(errors[-4:])
    raise RuntimeError(
        f"could not connect to the Basilisk Phantom Green after {attempts} attempts: {detail}"
    )


def available_profiles(profiles_dir):
    if not profiles_dir.is_dir():
        raise RuntimeError(f"profile directory does not exist: {profiles_dir}")
    return sorted(path.stem for path in profiles_dir.glob("*.json"))


def profile_path(profiles_dir, name):
    profiles = available_profiles(profiles_dir)
    if name not in profiles:
        raise ValueError(
            f"unknown profile {name!r}; choose one of: {', '.join(profiles)}"
        )
    return profiles_dir / f"{name}.json"


def input_button(mapping):
    combination = mapping.get("input_combination")
    if not isinstance(combination, list) or len(combination) != 1:
        raise ValueError(f"unsupported input combination: {combination!r}")
    event = combination[0]
    identity = (
        event.get("type"),
        event.get("code"),
        event.get("analog_threshold"),
    )
    try:
        return INPUT_BUTTONS[identity]
    except KeyError as exc:
        raise ValueError(f"unsupported recovered mouse input: {identity!r}") from exc


def keyboard_function(output_symbol):
    symbols = output_symbol.split(" + ")
    modifier = protocol.FnKeyboardModifier(0)
    keys = []
    for symbol in symbols:
        if symbol in KEYBOARD_MODIFIERS:
            modifier |= KEYBOARD_MODIFIERS[symbol]
        elif symbol in KEYBOARD_USAGES:
            keys.append(symbol)
        else:
            raise ValueError(f"unsupported recovered output symbol: {symbol!r}")
    if len(keys) > 1:
        raise ValueError(f"the mouse protocol supports only one non-modifier key: {output_symbol!r}")
    usage = KEYBOARD_USAGES[keys[0]] if keys else 0
    return protocol.ButtonFunction().set_keyboard(usage, modifier=modifier)


def baseline_bindings():
    """Return the normal hardware behavior for every profile-aware control."""
    return {
        protocol.Button.BACKWARD: protocol.ButtonFunction().set_mouse(
            protocol.FnMouse.BACKWARD
        ),
        protocol.Button.FORWARD: protocol.ButtonFunction().set_mouse(
            protocol.FnMouse.FORWARD
        ),
        protocol.Button.WHEEL_LEFT: protocol.ButtonFunction().set_mouse(
            protocol.FnMouse.WHEEL_LEFT
        ),
        protocol.Button.WHEEL_RIGHT: protocol.ButtonFunction().set_mouse(
            protocol.FnMouse.WHEEL_RIGHT
        ),
        protocol.Button.BOTTOM: protocol.ButtonFunction().set_profile_switch(
            protocol.FnProfileSwitch.NEXT_LOOP
        ),
        protocol.Button.AIM: protocol.ButtonFunction().set_dpi_switch(
            protocol.FnDpiSwitch.AIM,
            dpi=(400, 400),
        ),
        protocol.Button.MIDDLE_BACKWARD: protocol.ButtonFunction().set_dpi_switch(
            protocol.FnDpiSwitch.NEXT_LOOP
        ),
        protocol.Button.MIDDLE_FORWARD: protocol.ButtonFunction().set_scroll_mode_toggle(),
    }


def compile_profile(profiles_dir, name):
    with profile_path(profiles_dir, name).open(encoding="utf-8") as stream:
        mappings = json.load(stream)
    if not isinstance(mappings, list):
        raise ValueError(f"profile {name!r} does not contain a mapping list")

    bindings = baseline_bindings()
    labels = {button: "hardware default" for button in bindings}
    for mapping in mappings:
        if mapping.get("target_uinput") != "keyboard":
            raise ValueError(
                f"unsupported target in {name!r}: {mapping.get('target_uinput')!r}"
            )
        button = input_button(mapping)
        output = mapping.get("output_symbol")
        if not isinstance(output, str):
            raise ValueError(f"profile {name!r} contains a mapping without an output")
        bindings[button] = keyboard_function(output)
        labels[button] = output
    return bindings, labels


def describe(function):
    return {
        "raw": bytes(function).hex(),
        "class": function.fn_class.name.lower(),
        "value": function.get_fn_value().hex(),
    }


def set_and_verify(device, button, function, profile=protocol.Profile.DIRECT):
    device.set_button_function(function, button, profile=profile)
    current = device.get_button_function(button, profile=profile)
    if bytes(current) != bytes(function):
        raise RuntimeError(
            f"binding verification failed for {button.name}: "
            f"expected {bytes(function).hex()}, got {bytes(current).hex()}"
        )
    return current


def apply_profile(device, profiles_dir, name, target=protocol.Profile.DIRECT):
    # Compile and validate the entire profile before making the first write.
    bindings, labels = compile_profile(profiles_dir, name)
    result = {}
    for button, function in bindings.items():
        current = set_and_verify(device, button, function, target)
        result[button.name.lower()] = {
            "mapping": labels[button],
            **describe(current),
        }
    return result


def read_selected(state_file, profiles_dir):
    profiles = available_profiles(profiles_dir)
    try:
        selected = state_file.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        selected = "DEFAULT"
    return selected if selected in profiles else "DEFAULT"


def write_selected(state_file, name):
    state_file.parent.mkdir(parents=True, exist_ok=True)
    temporary = state_file.with_name(f".{state_file.name}.{os.getpid()}.tmp")
    temporary.write_text(f"{name}\n", encoding="utf-8")
    temporary.replace(state_file)


def dump_bindings(device, profile):
    result = {}
    for shift in protocol.Hypershift:
        layer = {}
        for button in protocol.Button:
            function = device.get_button_function(button, shift, profile=profile)
            layer[button.name.lower()] = describe(function)
        result[shift.name.lower()] = layer
    return result


def backup_onboard(device, destination):
    profiles = device.get_profile_list()
    profile_dumps = {}
    for profile in profiles:
        profile_dump = {
            "scroll_mode": device.get_scroll_mode(profile=profile),
            "scroll_acceleration": device.get_scroll_acceleration(profile=profile),
            "scroll_smart_reel": device.get_scroll_smart_reel(profile=profile),
            "polling_rate": device.get_polling_rate(profile=profile),
            "dpi_xy": device.get_dpi_xy(profile=profile),
            "dpi_stages": device.get_dpi_stages(profile=profile),
            "button_function": {
                (button, hypershift): device.get_button_function(
                    button,
                    hypershift,
                    profile=profile,
                )
                for hypershift in protocol.Hypershift
                for button in protocol.Button
            },
            "led_effect": {
                region: device.get_led_effect(region, profile=profile)
                for region in protocol.LedRegion
                if region != protocol.LedRegion.ALL
            },
            "led_brightness": {
                region: device.get_led_brightness(region, profile=profile)
                for region in protocol.LedRegion
                if region != protocol.LedRegion.ALL
            },
        }
        try:
            profile_dump["profile_info"] = device.get_profile_info(profile)
        except protocol.RazerException:
            pass
        profile_dumps[profile] = profile_dump

    macros = {
        macro_id: device.dump_macro(macro_id) for macro_id in device.get_macro_list()
    }
    backup = {
        "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "profiles": profile_dumps,
        "macros": macros,
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("xb") as stream:
        pickle.dump(backup, stream, protocol=pickle.HIGHEST_PROTOCOL)
    return profiles


def reset_onboard(device, destination, profiles_dir, name):
    previous_profiles = backup_onboard(device, destination)
    device.reset_flash()
    device.wait_device_ready()

    profiles = device.get_profile_list()
    if protocol.Profile.DEFAULT not in profiles:
        device.new_profile(protocol.Profile.DEFAULT)
    for profile in device.get_profile_list():
        if profile != protocol.Profile.DEFAULT:
            device.delete_profile(profile)

    return {
        "backup": str(destination),
        "deleted_profiles": [profile.name.lower() for profile in previous_profiles],
        "remaining_profiles": [
            profile.name.lower() for profile in device.get_profile_list()
        ],
        "onboard_profile": apply_profile(
            device,
            profiles_dir,
            name,
            protocol.Profile.DEFAULT,
        ),
        "direct_profile": apply_profile(device, profiles_dir, name),
    }


def parse_args():
    parser = argparse.ArgumentParser(
        description="Apply recovered Synapse layouts directly to a Basilisk V3 Pro 35K",
    )
    parser.add_argument(
        "--profiles-dir",
        type=pathlib.Path,
        default=pathlib.Path(os.environ.get("RAZER_PROFILE_DIR", ".")),
    )
    parser.add_argument(
        "--state-file",
        type=pathlib.Path,
        default=pathlib.Path(
            os.environ.get(
                "RAZER_PROFILE_STATE",
                "~/.local/state/razer-profile/current",
            )
        ).expanduser(),
    )
    parser.add_argument(
        "--transport",
        choices=("auto", "wired", "wireless"),
        default="auto",
    )
    parser.add_argument("--attempts", type=int, default=10)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("list-profiles", help="list recovered profile names")
    subparsers.add_parser("status", help="show the selected profile")
    validate_parser = subparsers.add_parser(
        "validate",
        help="compile every recovered profile without accessing hardware",
    )
    validate_parser.add_argument("profile", nargs="?")
    apply_parser = subparsers.add_parser(
        "apply-profile",
        help="apply and remember a profile in the volatile direct layer",
    )
    apply_parser.add_argument("profile")
    subparsers.add_parser(
        "reapply-profile",
        help="reapply the remembered profile without changing its state file",
    )
    reset_parser = subparsers.add_parser(
        "reset-onboard",
        help="back up and clear flash, retaining one directly programmed profile",
    )
    reset_parser.add_argument("--backup", type=pathlib.Path, required=True)
    reset_parser.add_argument("--profile", default="DEFAULT")
    dump_parser = subparsers.add_parser("dump", help="read every button binding")
    dump_parser.add_argument(
        "--profile",
        choices=("direct", "onboard"),
        default="direct",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    if args.attempts < 1:
        raise ValueError("--attempts must be at least 1")

    if args.command == "list-profiles":
        print("\n".join(available_profiles(args.profiles_dir)))
        return
    if args.command == "status":
        print(read_selected(args.state_file, args.profiles_dir))
        return
    if args.command == "validate":
        names = [args.profile] if args.profile else available_profiles(args.profiles_dir)
        for name in names:
            bindings, _ = compile_profile(args.profiles_dir, name)
            print(f"{name}\t{len(bindings)}")
        return

    selected = (
        args.profile
        if args.command in ("apply-profile", "reset-onboard")
        else read_selected(args.state_file, args.profiles_dir)
    )
    # Validate before connecting as well as before the first hardware write.
    compile_profile(args.profiles_dir, selected)

    device = None
    try:
        device, transport, path = connect(args.transport, args.attempts)
        if args.command == "apply-profile":
            bindings = apply_profile(device, args.profiles_dir, selected)
            write_selected(args.state_file, selected)
        elif args.command == "reapply-profile":
            bindings = apply_profile(device, args.profiles_dir, selected)
        elif args.command == "reset-onboard":
            bindings = reset_onboard(device, args.backup, args.profiles_dir, selected)
            write_selected(args.state_file, selected)
        else:
            profile = (
                protocol.Profile.DIRECT
                if args.profile == "direct"
                else protocol.Profile.DEFAULT
            )
            bindings = dump_bindings(device, profile)
        print(
            json.dumps(
                {
                    "transport": transport,
                    "path": path.decode(errors="replace"),
                    "command": args.command,
                    "profile": selected,
                    "bindings": bindings,
                },
                indent=2,
                sort_keys=True,
            )
        )
    finally:
        if device is not None:
            device.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"razer-onboard: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
