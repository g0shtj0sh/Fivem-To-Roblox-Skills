#!/usr/bin/env python3
"""Test de bout en bout sur le véhicule synthétique (python tests/test_pipeline.py ou pytest)."""
from __future__ import annotations

import json
import os
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
                            "-o", str(tmp / "out"), "--no-build", "--no-ogg"], capture_output=True, text=True,
                           env={**os.environ, "F2R_TEXTURE_BASELINES": str(tmp / "baselines")})
        assert r.returncode == 0, r.stderr
        out = tmp / "out" / "testcar"
        gltf = read_glb(out / "testcar.glb")
        names = {n["name"] for n in gltf["nodes"]}
        cfg = json.loads((out / "vehicle_config.json").read_text(encoding="utf-8"))["roblox_config"]

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
        # textures <= 2048 px (plafond de Roblox) ; la source 2048 du pneu est gardée telle quelle
        from PIL import Image
        for png in (out / "textures").glob("*.png"):
            assert max(Image.open(png).size) <= 2048, png
        # pièce opaque : la texture est écrite « <nom>_opaque.png » depuis 3bcd146 (icônes de l'habitacle)
        tyre = next((p for p in (out / "textures" / "testcar_tyre.png", out / "textures" / "testcar_tyre_opaque.png")
                     if p.exists()), None)
        assert tyre is not None, sorted(p.name for p in (out / "textures").glob("*.png"))
        assert Image.open(tyre).size == (2048, 2048)
        # sons
        assert len(cfg["Audio"]["EngineLoops"]) >= 4 and cfg["Audio"]["Source"].startswith("awc:")
        for f in cfg["Audio"]["Files"].values():
            assert (out / "sounds" / f).exists(), f
        assert cfg["HasSiren"] is True
        setup = (out / "testcar_Setup.lua").read_text(encoding="utf-8")
        assert "__CONFIG_TABLE__" not in setup and "local SOURCES" in setup
        assert "__RUNTIME_VERSION__" not in setup and "F2RExpectedParts" in setup
        # variante studio/ pour l'automatisation par execute_luau
        sdir = out / "studio"
        man = json.loads((sdir / "manifest.json").read_text(encoding="utf-8"))
        assert man["vehicle"] == "testcar" and len(man["runtime_version"]) == 12
        compact = (sdir / "testcar_Setup.studio.lua").read_text(encoding="utf-8")
        assert "local SOURCES = nil" in compact and "local CONFIG_SOURCE = nil" in compact
        assert man["runtime_version"] in compact
        assert (sdir / "Verify.lua").exists() and (sdir / "ApplySoundIds.lua").exists()
        runtime = (sdir / "FiveMRuntime.lua").read_text(encoding="utf-8")
        assert "__RUNTIME_SOURCES__" not in runtime and "VehicleCustomization" in runtime
        assert "VehicleAccess" in runtime and 'SOURCES.VehicleAccess' in runtime
        # moteur de conduite : modules installés, lest et actionneurs créés par le Setup
        for mod in ("VehicleDynamics", "VehicleDrive"):
            assert f"SOURCES.{mod}" in runtime, mod
        assert '"Ballast"' in compact and '"DriveForce"' in compact and '"DriveTorque"' in compact
        assert (sdir / "DriveBench.lua").exists() and (sdir / "TestTrack.lua").exists()
        access = (ROOT / "roblox" / "runtime" / "VehicleAccess.lua").read_text(encoding="utf-8")
        assert "function Access.RecoverFromVoid" in access and "function Access.PlaceOnGround" in access
        # monter / descendre : une invite F par siège, invite de remise sur les roues, attributs
        assert "EnterPrompt" in compact and "Enum.KeyCode.F" in compact and "RecoverPrompt" in compact
        assert "ParkAnchorDelay = 5" in compact and "Locked = false" in compact
        # chaque étape découpée doit se recomposer exactement en sa source
        import re
        for step, src in (("FiveMRuntime", runtime), ("testcar_Setup", compact)):
            calls = next(s["calls"] for s in man["steps"] if s["key"] == step)
            parts = []
            for c in calls:
                code = (sdir / c).read_text(encoding="utf-8")
                assert len(code.encode()) < 21000, c
                m = re.search(r"table\.insert\(_G\.F2R_BUF\[\"[^\"]+\"\], \[(=+)\[\n(.*)\]\1\]\)\n", code, re.S)
                assert m, c
                parts.append(m.group(2))
            assert "".join(parts) == src, step
            assert "loadstring" in (sdir / calls[-1]).read_text(encoding="utf-8")
        # le Setup prend sa cible en argument : compilé par son dernier morceau, appelé par « then »
        setup_step = next(s for s in man["steps"] if s["key"] == "testcar_Setup")
        assert "_G.F2R_FN" in (sdir / setup_step["calls"][-1]).read_text(encoding="utf-8")
        assert "target = " in setup_step["then"]
        # étape 3 : physique complète du véhicule
        hd = cfg["Handling"]
        assert hd["TractionCurveLateralDeg"] == 22.5 and abs(hd["TractionCurveLateralRad"] - 0.392699) < 1e-5
        assert hd["DriveFront"] == 0.0 and hd["DriveRear"] == 2.0          # 0.05 -> propulsion pure
        assert abs(hd["ShiftTimeUpS"] - 0.3) < 1e-6 and abs(hd["SuspensionCompDampScaled"] - 0.14) < 1e-9
        assert hd["CentreOfMassLocal"] == [0.0, -0.1, -0.0] or hd["CentreOfMassLocal"] == [0.0, -0.1, 0.0]
        assert hd["Flags"]["Model"]["Names"] == ["ABS_STD", "AXLE_F_MCPHERSON", "AXLE_R_MCPHERSON"]
        assert hd["Flags"]["Handling"]["Names"] == ["TYRES_CAN_CLIP"]
        assert hd["CarHandling"]["AdvancedFlags"]["Names"] == ["HARD_REV_LIMIT"]
        assert abs(hd["CarHandling"]["CastorDeg"] - 4.0) < 1e-6 and hd["GravityMs2"] == 9.8
        assert "fMass" in hd["Raw"] and hd["Gearbox"] == "auto"
        ph = cfg["Physics"]
        assert ph["FragMassKg"] == 1400 and ph["FragInertia"] == [1200, 1500, 450]
        assert ph["ChildMassKg"]["wheel_lf"] == 20
        hz = cfg["Hinges"]
        assert hz["door_dside_f"]["Source"] == "yft" and abs(hz["door_dside_f"]["OpenAngle"] - 63.03) < 0.01
        assert hz["door_dside_f"]["Axis"] == [0.0, -1.0, 0.0]               # s'ouvre vers l'extérieur
        assert hz["bonnet"]["Source"] == "yft" and hz["bonnet"]["Axis"] == [1.0, 0.0, 0.0]
        assert hz["door_pside_f"]["Source"] == "defaut"
        # plaques : une zone par plaque (avant / arrière), au bon endroit, zone de texte du shader GTA
        pl = cfg["Plates"]
        assert pl["Type"] == "VPT_FRONT_AND_BACK_PLATES" and len(pl["Zones"]) == 2
        rear = next(z for z in pl["Zones"] if not z["Front"])
        front = next(z for z in pl["Zones"] if z["Front"])
        assert rear["Center"][2] > 2.0 and rear["Normal"] == [0.0, 0.0, 1.0] and rear["Right"] == [1.0, 0.0, 0.0]
        assert front["Center"][2] < -2.0 and front["Normal"] == [0.0, 0.0, -1.0] and front["Right"] == [-1.0, 0.0, 0.0]
        assert abs(rear["Width"] - 0.52) < 1e-3 and abs(rear["Height"] - 0.12) < 1e-3 and rear["Letters"] == 8
        x, y, w, h = rear["TextRect"]                                     # LicensePlateFontExtents
        assert abs(x - 0.043) < 1e-3 and abs(y - 0.38) < 1e-3 and abs(w - 0.902) < 1e-3 and abs(h - 0.461) < 1e-3
        assert cfg["PlateText"] == ""                                     # plaque unique générée en jeu
        assert "VehiclePlates" in (out / "studio" / "FiveMRuntime.lua").read_text()
        # garde-fou textures : première conversion -> référence enregistrée, manifeste écrit
        assert (tmp / "baselines" / "testcar.json").exists() and (out / "texture_manifest.json").exists()
        print(f"OK : {len(names)} nœuds, {len(gltf['images'])} images")


def test_texture_guard():
    """Une pièce qui perd sa texture ou sa transparence par rapport à la dernière conversion acceptée : code 3,
    rapport en tête, référence inchangée ; --accept-texture-changes l'accepte (régression du 2026-11-16)."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        zpath = make_fixture.main(tmp / "fx")
        env = {**os.environ, "F2R_TEXTURE_BASELINES": str(tmp / "baselines")}

        def run(*extra):
            return subprocess.run([sys.executable, str(ROOT / "scripts" / "convert_vehicle.py"), str(zpath),
                                   "-o", str(tmp / "out"), "--no-build", "--no-ogg", *extra],
                                  capture_output=True, text=True, env=env)
        assert run().returncode == 0
        assert run().returncode == 0                                       # même résultat : aucune perte
        bpath = tmp / "baselines" / "testcar.json"
        base = json.loads(bpath.read_text(encoding="utf-8"))
        parts = base["parts"]
        plain = next(n for n, e in parts.items() if not e["tex"])
        glass = next((n for n, e in parts.items() if e["blend"]), None)
        parts[plain]["tex"] = True                                         # la référence avait une texture ici
        if glass is None:
            glass = next(n for n, e in parts.items() if n != plain)
        parts[glass]["blend"] = True
        parts["piece_disparue"] = {"kind": "generic", "tex": True, "normal": False, "blend": False, "emask": False}
        bpath.write_text(json.dumps(base), encoding="utf-8")
        r = run()
        assert r.returncode == 3, r.stderr
        report = (tmp / "out" / "testcar" / "report.md").read_text(encoding="utf-8")
        assert "RÉGRESSION DES TEXTURES" in report.split("## Résultat")[0]
        lost = json.loads((tmp / "out" / "testcar" / "texture_regression.json").read_text(encoding="utf-8"))
        assert plain in lost["tex"] and lost["parts"] == ["piece_disparue"]
        assert json.loads(bpath.read_text(encoding="utf-8"))["parts"][plain]["tex"] is True   # référence gardée
        assert run("--accept-texture-changes").returncode == 0
        assert run().returncode == 0                                       # nouvelle référence acceptée
        print("OK : garde-fou textures")


if __name__ == "__main__":
    test_pipeline()
    test_texture_guard()
