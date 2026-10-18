#!/usr/bin/env python3
import argparse
import configparser
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone


PROFILE = "HiveTech_1440p"
AUDIO = (
    ("AMPS Clean Mic", "amps.clean_mic", 7),
    ("AMPS Comms Audio", "amps.comms", 11),
    ("AMPS Game", "amps.game", 19),
    ("AMPS Media", "amps.music", 33),
)


def migrate_scene(original, home, camera):
    scene = copy.deepcopy(original)
    unsupported = []
    for key in ("DesktopAudioDevice1", "DesktopAudioDevice2"):
        scene.pop(key, None)
    for index, (name, device, mixers) in enumerate(AUDIO, 1):
        source = scene[f"AuxAudioDevice{index}"]
        source.update(name=name, id="pulse_input_capture", versioned_id="pulse_input_capture",
                      mixers=mixers, monitoring_type=0, settings={"device_id": device})
    for source in scene["sources"]:
        kind = source["id"]
        if kind == "game_capture":
            source.update(id="vkcapture-source", versioned_id="vkcapture-source",
                          mixers=0, settings={"show_cursor": True, "allow_transparency": False})
        elif kind == "monitor_capture":
            source.update(id="pipewire-desktop-capture-source",
                          versioned_id="pipewire-desktop-capture-source",
                          settings={"ShowCursor": True})
        elif kind == "dshow_input":
            source.update(id="v4l2_input", versioned_id="v4l2_input", mixers=0,
                          settings={"device_id": str(camera), "input": 0,
                                    "pixelformat": 1448695129, "resolution": (1920 << 32) | 1080,
                                    "framerate": (1 << 32) | 30, "buffering": False})
        elif kind == "browser_source":
            source["mixers"] = 1
        elif kind == "image_source":
            source["settings"]["file"] = str(home / ".local/share/obs-assets/pixel-meadow-hive-2560x1440.png")
        retained = []
        for effect in source.get("filters", []):
            if effect["id"] == "nv_greenscreen_filter":
                unsupported.append({"source": source["name"], "filter": effect})
                continue
            if effect["id"] == "osi_branch_output":
                effect["settings"]["path"] = str(home / "Videos/OBS Clean")
            retained.append(effect)
        if "filters" in source:
            source["filters"] = retained
    camera_scenes = {source["name"] for source in scene["sources"]
                     if source["id"] == "scene" and any(
                         item["name"] in {entry["source"] for entry in unsupported}
                         for item in source["settings"].get("items", []))}
    for source in scene["sources"]:
        for item in source.get("settings", {}).get("items", []):
            if item["name"] in camera_scenes:
                item["visible"] = False
            if source["name"] == "Stream + Bumblebee":
                if item["name"] == "Bee Dev":
                    item["visible"] = False
                elif item["name"] == "Bumblebee Overlay":
                    item["visible"] = True
    scene.get("modules", {}).pop("scripts-tool", None)
    return scene, unsupported


def read_ini(path):
    ini = configparser.ConfigParser(interpolation=None, strict=False)
    ini.optionxform = str
    ini.read(path, encoding="utf-8-sig")
    return ini


def write_ini(path, ini):
    with path.open("w", encoding="utf-8") as output:
        ini.write(output, space_around_delimiters=False)


def set_values(ini, section, values):
    if not ini.has_section(section):
        ini.add_section(section)
    ini[section].update(values)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--camera", type=Path, required=True)
    parser.add_argument("--home", type=Path, default=Path.home())
    args = parser.parse_args()
    os.umask(0o077)
    if subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", ".obs-wrapped.*|obs"],
                      stdout=subprocess.DEVNULL).returncode == 0:
        parser.error("Close OBS before importing its configuration")
    root = args.home / ".config/obs-studio"
    profile = root / "basic/profiles" / PROFILE
    collection = root / "basic/scenes" / f"{PROFILE}.json"
    if profile.exists() or collection.exists():
        parser.error("Production profile already exists; refusing to overwrite OBS-owned settings")
    source_profile = args.source / "basic/profiles" / PROFILE
    source_scene = args.source / "basic/scenes" / f"{PROFILE}.json"
    scene, unsupported = migrate_scene(json.loads(source_scene.read_text(encoding="utf-8-sig")),
                                       args.home, args.camera)
    ini = read_ini(source_profile / "basic.ini")
    set_values(ini, "AdvOut", {"RecFilePath": str(args.home / "Videos/OBS"),
                              "FFFilePath": str(args.home / "Videos/OBS"),
                              "Encoder": "obs_x264", "RecEncoder": "obs_nvenc_hevc_tex",
                              "Rescale": "true", "RescaleRes": "1920x1080", "RecTracks": "62",
                              "Track2Name": "Publish Mix - No Media", "Track6Name": "Media"})
    set_values(ini, "SimpleOutput", {"FilePath": str(args.home / "Videos/OBS")})
    set_values(ini, "Audio", {"MonitoringDeviceId": "default", "MonitoringDeviceName": "Default"})
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup = args.home / ".local/state/obs-migration" / stamp
    backup.mkdir(parents=True, mode=0o700)
    if root.exists():
        shutil.copytree(root, backup / "linux-before")
    shutil.copytree(args.source, backup / "windows-original")
    (backup / "unsupported-filters.json").write_text(json.dumps(unsupported, indent=2))
    with tempfile.TemporaryDirectory(prefix="obs-migration-", dir=backup) as staging:
        staged_profile = Path(staging) / PROFILE
        shutil.copytree(source_profile, staged_profile)
        write_ini(staged_profile / "basic.ini", ini)
        dock = {"interlock": 1, "sortingColumn": "name", "sortingOrder": 0}
        (staged_profile / "outputStatusDock.json").write_text(json.dumps(dock))
        profile.parent.mkdir(parents=True, exist_ok=True)
        collection.parent.mkdir(parents=True, exist_ok=True)
        asset_target = args.home / ".local/share/obs-assets"
        asset_target.mkdir(parents=True, exist_ok=True)
        asset = "pixel-meadow-hive-2560x1440.png"
        if not (asset_target / asset).exists():
            shutil.copy2(args.assets / asset, asset_target / asset)
        for folder in ("OBS", "OBS Clean"):
            (args.home / "Videos" / folder).mkdir(parents=True, exist_ok=True)
        global_dock = root / "plugin_config/osi-branch-output"
        global_dock.mkdir(parents=True, exist_ok=True)
        (global_dock / "outputStatusDock.json").write_text(json.dumps(dock))
        shutil.move(str(staged_profile), profile)
        collection.write_text(json.dumps(scene, indent=2))
        user = read_ini(root / "user.ini")
        set_values(user, "Basic", {"Profile": "HiveTech 1440p", "ProfileDir": PROFILE,
                                   "SceneCollection": scene["name"], "SceneCollectionFile": PROFILE})
        write_ini(root / "user.ini", user)
    print(f"Imported production profile. Recovery backup: {backup}")
    print("Camera hidden pending NVIDIA filter support. Desktop captures need portal selection.")


if __name__ == "__main__":
    main()
