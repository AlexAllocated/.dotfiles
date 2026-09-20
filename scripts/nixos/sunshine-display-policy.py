import json
import os
from pathlib import Path
import subprocess
import sys
import time


VIRTUAL = "Moonlight"


def nvidia_render_node(sysfs=Path("/sys/class/drm"), devices=Path("/dev/dri")):
    nodes = [
        devices / node.name
        for node in sorted(sysfs.glob("renderD*"))
        if (node / "device/driver").resolve().name == "nvidia"
        and (devices / node.name).exists()
    ]
    if len(nodes) != 1:
        raise RuntimeError(f"Expected one NVIDIA render node, found {nodes}")
    return str(nodes[0])


def dimensions(arguments):
    values = tuple(map(int, arguments or (1920, 1080, 60)))
    if len(values) != 3 or not (
        320 <= values[0] <= 7680
        and 240 <= values[1] <= 4320
        and 10 <= values[2] <= 240
    ):
        raise ValueError("Unsupported client dimensions or refresh rate")
    return values


def physical_output(outputs, connectors):
    for name in connectors:
        output = outputs.get(name)
        if output and output.get("current_mode") is not None and output.get("logical"):
            return name
    return None


class Policy:
    def __init__(self, run=subprocess.run, state=None):
        self.run = run
        self.state = Path(state or os.environ["SUNSHINE_SELECTED_OUTPUT_FILE"])
        self.connectors = os.environ.get("SUNSHINE_PHYSICAL_OUTPUTS", "DP-4").split()

    def niri(self, *arguments):
        try:
            result = self.run(
                ["niri", "msg", "--json", *arguments],
                check=True, capture_output=True, text=True, timeout=10,
            )
        except subprocess.CalledProcessError as error:
            raise RuntimeError(f"Niri rejected {arguments}: {error.stderr.strip()}") from error
        return json.loads(result.stdout) if result.stdout.strip() else None

    def outputs(self):
        return self.niri("outputs")

    def save(self, selected):
        temporary = self.state.with_suffix(".tmp")
        temporary.write_text(selected + "\n")
        temporary.replace(self.state)

    def prepare(self, size):
        outputs = self.outputs()
        physical = physical_output(outputs, self.connectors)
        logical = outputs[physical]["logical"] if physical else {}
        x = logical.get("x", 0) + logical.get("width", 0)
        y = logical.get("y", 0)
        width, height, fps = size
        previous = outputs.get(VIRTUAL, {})
        previous_index = previous.get("current_mode")
        previous_mode = (
            previous["modes"][previous_index] if previous_index is not None else {}
        )
        previous_logical = previous.get("logical") or {}
        refresh_geometry = (
            previous_mode.get("width") != width
            or previous_mode.get("height") != height
            or previous_logical.get("scale") != 1.5
            or previous_logical.get("x") != x
            or previous_logical.get("y") != y
        )
        if VIRTUAL not in outputs:
            self.niri(
                "create-virtual-output", "--name", VIRTUAL,
                "--width", str(width), "--height", str(height),
                "--refresh-rate", str(fps),
            )
        self.niri("output", VIRTUAL, "mode", f"{width}x{height}@{fps}")
        self.niri("output", VIRTUAL, "scale", "1.5")
        self.niri("output", VIRTUAL, "position", "set", str(x), str(y))
        self.niri("output", VIRTUAL, "on")
        selected = VIRTUAL
        for _ in range(30):
            current = self.outputs().get(selected, {})
            mode = current.get("current_mode")
            if mode is not None and current.get("logical"):
                actual = current["modes"][mode]
                if (
                    actual["width"] == size[0]
                    and actual["height"] == size[1]
                    and abs(actual["refresh_rate"] - size[2] * 1000) <= 100
                ):
                    if refresh_geometry:
                        try:
                            self.niri("output", VIRTUAL, "position", "set", str(x + 1), str(y))
                        finally:
                            self.niri("output", VIRTUAL, "position", "set", str(x), str(y))
                    self.save(selected)
                    print(f"Sunshine will capture {selected}: {actual}", file=sys.stderr)
                    return selected
            time.sleep(0.1)
        raise RuntimeError(f"Display {selected} did not become ready")

    def idle(self):
        selected = physical_output(self.outputs(), self.connectors)
        if selected:
            self.stop()
            self.save(selected)
        else:
            self.prepare((1920, 1080, 60))

    def stop(self):
        outputs = self.outputs()
        if VIRTUAL in outputs and physical_output(outputs, self.connectors):
            self.niri("remove-virtual-output", VIRTUAL)


def main():
    if sys.argv[1:] == ["render-node"]:
        print(nvidia_render_node())
        return
    policy = Policy()
    if sys.argv[1:2] == ["stop"]:
        policy.stop()
    elif sys.argv[1:] == ["idle"]:
        policy.idle()
    else:
        policy.prepare(dimensions(sys.argv[1:]))


if __name__ == "__main__":
    main()
