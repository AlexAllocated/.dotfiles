#!/usr/bin/env python3
"""Apply a volatile Linux button layer to the Basilisk Phantom Green."""

import argparse
import contextlib
import io
import json
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
LINUX_BINDINGS = {
    protocol.Button.BOTTOM: ("F13", 0x68),
    protocol.Button.AIM: ("F14", 0x69),
    protocol.Button.MIDDLE_BACKWARD: ("F15", 0x6A),
    protocol.Button.MIDDLE_FORWARD: ("F16", 0x6B),
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
            except Exception as exc:  # The device reports transport errors at runtime.
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


def describe(function):
    return {
        "raw": bytes(function).hex(),
        "class": function.fn_class.name.lower(),
        "value": function.get_fn_value().hex(),
    }


def set_and_verify(device, button, function):
    device.set_button_function(
        function,
        button,
        profile=protocol.Profile.DIRECT,
    )
    current = device.get_button_function(
        button,
        profile=protocol.Profile.DIRECT,
    )
    if bytes(current) != bytes(function):
        raise RuntimeError(
            f"binding verification failed for {button.name}: "
            f"expected {bytes(function).hex()}, got {bytes(current).hex()}"
        )
    return current


def apply_linux(device):
    result = {}
    for button, (key_name, hid_usage) in LINUX_BINDINGS.items():
        function = protocol.ButtonFunction().set_keyboard(hid_usage)
        current = set_and_verify(device, button, function)
        result[button.name.lower()] = {
            "key": key_name,
            **describe(current),
        }
    return result


def restore_onboard(device):
    result = {}
    for button in LINUX_BINDINGS:
        stored = device.get_button_function(
            button,
            profile=protocol.Profile.DEFAULT,
        )
        current = set_and_verify(device, button, stored)
        result[button.name.lower()] = describe(current)
    return result


def dump_bindings(device, profile):
    result = {}
    for shift in protocol.Hypershift:
        layer = {}
        for button in protocol.Button:
            function = device.get_button_function(
                button,
                shift,
                profile=profile,
            )
            layer[button.name.lower()] = describe(function)
        result[shift.name.lower()] = layer
    return result


def parse_args():
    parser = argparse.ArgumentParser(
        description="Manage the volatile Linux bindings on a Basilisk V3 Pro 35K Phantom Green",
    )
    parser.add_argument(
        "--transport",
        choices=("auto", "wired", "wireless"),
        default="auto",
    )
    parser.add_argument("--attempts", type=int, default=10)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser(
        "apply-linux",
        help="map the four private controls to F13-F16 in volatile profile 0",
    )
    subparsers.add_parser(
        "restore",
        help="restore those controls from onboard profile 1 into volatile profile 0",
    )
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

    device = None
    try:
        device, transport, path = connect(args.transport, args.attempts)
        if args.command == "apply-linux":
            bindings = apply_linux(device)
        elif args.command == "restore":
            bindings = restore_onboard(device)
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
