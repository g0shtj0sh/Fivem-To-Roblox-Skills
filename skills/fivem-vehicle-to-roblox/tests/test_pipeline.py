#!/usr/bin/env python3
"""Test de bout en bout sur le véhicule synthétique (python tests/test_pipeline.py ou pytest)."""
from __future__ import annotations

import json
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import make_fixture  # noqa: E402


def read_glb(path: Path) -> dict:
    b = path.read_bytes()
    magic, version, total = struct.unpack("<III", b[:12])
    assert magic == 0x46546C67 and version == 2 and total == len(b), "en-tête GLB invalide"
    jlen, jtype = struct.unpack("<II", b[12:20])
    assert jtype == 0x4E4F534A
    gltf = json.loads(b[20:20 + jlen])
    blen, btype = struct.unpack("<II", b[20 + jlen:28 + jlen])
    assert btype == 0x004E4942 and blen == gltf["buffers"][0]["byteLength"]
    for v in gltf["bufferViews"]:
        assert v["byteOffset"] + v["byteLength"] <= blen
    return gltf


def test_pipeline():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        zpath = make_fixture.main(tmp / "fx")
        r = subprocess.run([sys.executable, str(ROOT / "scripts" / "convert_vehicle.py"), str(zpath),
                            "-o", str(tmp / "out"), "--no-build", "--no-ogg"], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        out = tmp / "out" / "testcar"
        gltf = read_glb(out / "testcar.glb")
        names = {n["name"] for n in gltf["nodes"]}
        cfg = json.loads((out / "vehicle_config.json").read_text())["roblox_config"]

        # roues : 1 seule modélisée, 4 en sortie, aux positions des os
        for w in ("wheel_lf", "wheel_rf", "wheel_lr", "wheel_rr"):
            assert any(n.startswith(w + "__") for n in names), w
        assert cfg["Wheels"]["wheel_rf"]["Position"] == [0.8, -0.2, -1.3]
        assert abs(cfg["Wheels"]["wheel_lf"]["Radius"] - 0.33) < 0.01
        # lumières séparées par ID (alpha de Colour0)
        for role in ("headlight_l", "headlight_r", "taillight_l", "brakelight_r", "indicator_lf"):
            assert f"chassis__{role}" in names, role
        # charnières : portières vers l'extérieur, capot/coffre vers le haut
        assert cfg["Hinges"]["door_dside_f"]["Axis"][1] < 0 < cfg["Hinges"]["door_pside_f"]["Axis"][1]
        assert set(cfg["Hinges"]) == {"door_dside_f", "door_pside_f", "bonnet", "boot"}
        # custom
        assert cfg["Mods"]["Spoiler"]["Options"][0]["TurnOffBones"] == ["misc_a"]
        assert any(n.startswith("mod_Spoiler_1__") for n in names)
        assert cfg["LiveryCarriers"] == ["LIVERY_TEX_1", "LIVERY_TEX_2"]
        assert cfg["Extras"] == [1]
        assert cfg["StatMods"]["Engine"][0]["Modifier"] == 25
        assert abs(cfg["Colors"]["Default"]["Primary"][0] - 192 / 255) < 0.01  # index 27 = Metallic Red
        # repère : avant = -Z
        assert cfg["Lights"]["headlight_l"][2] < 0 < cfg["Lights"]["taillight_l"][2]
        # textures <= 1024 px
        from PIL import Image
        for png in (out / "textures").glob("*.png"):
            assert max(Image.open(png).size) <= 1024, png
        # sons
        assert len(cfg["Audio"]["EngineLoops"]) >= 4 and cfg["Audio"]["Source"].startswith("awc:")
        for f in cfg["Audio"]["Files"].values():
            assert (out / "sounds" / f).exists(), f
        assert cfg["HasSiren"] is True
        setup = (out / "testcar_Setup.lua").read_text()
        assert "__CONFIG_TABLE__" not in setup and "local SOURCES" in setup
        print(f"OK : {len(names)} nœuds, {len(gltf['images'])} images")


if __name__ == "__main__":
    test_pipeline()
