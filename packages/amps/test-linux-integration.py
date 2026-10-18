import argparse
import array
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def run(engine, pipewire_config):
    with tempfile.TemporaryDirectory(prefix="amps-pipewire-test-") as temporary:
        root = Path(temporary)
        env = dict(os.environ, XDG_RUNTIME_DIR=temporary, PIPEWIRE_CONFIG_DIR=pipewire_config)
        config = root / "config.toml"
        config.write_text(subprocess.check_output([engine, "example-config"], text=True))
        log = (root / "log").open("w+")
        children = []
        try:
            children.append(subprocess.Popen(["pipewire"], env=env, stdout=log, stderr=log))
            for _ in range(100):
                if (root / "pipewire-0").exists():
                    break
                time.sleep(0.05)
            fixture = ["pw-loopback", "--capture-props", json.dumps({
                "node.name": "fixture.output", "media.class": "Audio/Sink", "node.autoconnect": False,
                "node.virtual": False, "adapter.auto-port-config": {"mode": "dsp", "monitor": False, "position": "preserve"},
            }), "--playback-props", json.dumps({
                "node.name": "fixture.input", "media.class": "Audio/Source", "node.autoconnect": False,
                "node.virtual": False, "adapter.auto-port-config": {"mode": "dsp", "monitor": False, "position": "preserve"},
            })]
            children.append(subprocess.Popen(fixture, env=env, stdout=log, stderr=log))
            children.append(subprocess.Popen([engine, "--config", str(config), "run"], env=env, stdout=log, stderr=log))
            state_path = root / "control-v1/status.json"
            for _ in range(300):
                if children[-1].poll() is not None:
                    raise RuntimeError("Engine exited during startup")
                if state_path.exists() and json.loads(state_path.read_text()).get("appliedRevision") is not None:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError("Engine readiness timed out")

            def edit(value):
                state = json.loads(state_path.read_text())
                request = root / "request.json"
                request.write_text(json.dumps({"id": f"test-{time.time_ns()}", "session": state["session"],
                    "expectedRevision": state["revision"], "edit": value}))
                reply = json.loads(subprocess.check_output([engine, "--config", str(config), "control", "--request", str(request)], env=env, text=True))
                if not reply["applied"]:
                    raise RuntimeError(reply)
                print("Applied", value, flush=True)

            subprocess.run([engine, "--config", str(config), "doctor"], env=env, check=True)
            duplicate = subprocess.run([engine, "--config", str(config), "run"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            assert duplicate.returncode != 0 and b"Another AMPS engine" in duplicate.stderr
            for backend, enabled, intensity in [("nvidia_afx", True, 100), ("nvidia_afx", True, 0),
                    ("nvidia_afx", False, 50), ("nvidia_afx", True, 80), ("nvidia_afx", True, 50)]:
                edit({"kind": "suppression", "engine": backend, "enabled": enabled, "intensity": intensity})
                objects = json.loads(subprocess.check_output(["pw-dump"], env=env))
                selected = next(o for o in objects if o.get("info", {}).get("props", {}).get("node.name") == f"amps.filter.{backend}.input")
                parameters = {}
                for entry in selected["info"]["params"]["Props"]:
                    values = entry.get("params", {})
                    if isinstance(values, list):
                        values = dict(zip(values[::2], values[1::2]))
                    parameters.update(values)
                key = "denoise:Intensity"
                expected = intensity / 100
                assert key in parameters, parameters
                assert abs(parameters[key] - expected) < .001, (parameters, expected)
            edit({"kind": "connect", "source": "music", "destination": "comms_send"})
            edit({"kind": "undo"})
            edit({"kind": "redo"})
            tone = root / "tone.f32"
            tone.write_bytes(array.array("f", (.15 * math.sin(i * 2 * math.pi * 440 / 48000) for i in range(48000 * 5))).tobytes())
            captured = (root / "captured.f32").open("wb")
            streams = []
            for mode, name, file in [("--record", "fixture.record", "-"), ("--playback", "fixture.signal", str(tone))]:
                child = subprocess.Popen(["pw-cat", mode, "--raw", "--format", "f32", "--rate", "48000", "--channels", "1",
                    "--properties", json.dumps({"node.name": name, "node.autoconnect": False,
                        "adapter.auto-port-config": {"mode": "dsp", "monitor": False, "position": "preserve"}}), file],
                    env=env, stdout=captured if mode == "--record" else log, stderr=log)
                children.append(child)
                streams.append(child)
            def port(name, direction):
                objects = json.loads(subprocess.check_output(["pw-dump"], env=env))
                parent = next((o["id"] for o in objects if o.get("info", {}).get("props", {}).get("node.name") == name), None)
                return next((str(o["id"]) for o in objects if o.get("type") == "PipeWire:Interface:Port" and
                    o.get("info", {}).get("props", {}).get("node.id") == parent and o["info"]["props"].get("port.direction") == direction), None)
            for _ in range(100):
                if port("fixture.signal", "out") and port("fixture.record", "in"):
                    break
                time.sleep(.05)
            for source, destination in [("fixture.signal", "amps.music.sink"), ("amps.comms_send", "fixture.record")]:
                output, incoming = port(source, "out"), port(destination, "in")
                assert output and incoming, (source, destination)
                subprocess.run(["pw-link", output, incoming], env=env, check=True)
            time.sleep(1)
            for child in streams:
                child.terminate()
                child.wait(timeout=5)
            captured.close()
            pcm = array.array("f")
            pcm.frombytes((root / "captured.f32").read_bytes())
            assert len(pcm) > 12000 and all(math.isfinite(value) for value in pcm), len(pcm)
            rms = math.sqrt(sum(value * value for value in pcm) / len(pcm))
            assert .01 < rms < .3, rms
            print(f"Verified real Media → Comms Mic samples: {len(pcm)}, RMS={rms:.4f}", flush=True)
            children[2].send_signal(signal.SIGINT)
            assert children[2].wait(timeout=10) == 0
            assert not json.loads(state_path.read_text())["online"]
            objects = json.loads(subprocess.check_output(["pw-dump"], env=env))
            assert not any(o.get("info", {}).get("props", {}).get("node.name", "").startswith("amps.") for o in objects)
            print("PASS: isolated graph startup, routing, filter changes, single instance, undo/redo, shutdown")
        except Exception:
            objects = json.loads(subprocess.check_output(["pw-dump"], env=env))
            for item in objects:
                if item.get("type") in ("PipeWire:Interface:Node", "PipeWire:Interface:Port"):
                    print(item["id"], item.get("info", {}).get("props"), item.get("info", {}).get("error"))
            log.flush()
            log.seek(0)
            print(log.read())
            raise
        finally:
            for child in reversed(children):
                if child.poll() is None:
                    child.send_signal(signal.SIGINT if len(children) > 2 and child is children[2] else signal.SIGTERM)
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("engine")
    parser.add_argument("pipewire_config")
    args = parser.parse_args()
    run(args.engine, args.pipewire_config)
